import CoreGraphics
import Foundation

/// Canon IJ driver options read from a PRO-series PPD.
struct CanonDriver: Sendable {
    struct PaperProfile: Hashable, Sendable {
        let profileID: String
        let fileName: String
        let url: URL
    }

    struct MediaType: Identifiable, Hashable, Sendable {
        let id: String
        let name: String
        let profile: PaperProfile?
    }

    enum Margin: String, CaseIterable, Codable, Sendable {
        case standard
        case borderless
        case artMargin

        var label: String {
            switch self {
            case .standard: "Standard"
            case .borderless: "Borderless"
            case .artMargin: "Fine Art margin (25 mm)"
            }
        }
    }

    struct Paper: Identifiable, Hashable, Sendable {
        let id: String
        let label: String
        /// Paper size in points.
        let size: CGSize
        let variants: [Margin: PPDFile.PageSize]
    }

    struct Choice: Identifiable, Hashable, Sendable {
        let id: String
        let name: String
    }

    static let noColorCorrection = "1001"
    static let profilePrefix = "CN_PRO-1000_500_"

    let ppd: PPDFile
    let mediaTypes: [MediaType]
    let papers: [Paper]
    let qualities: [Choice]
    let paperSources: [Choice]
    let dryingTimes: [Choice]
    let genericProfile: PaperProfile?

    init?(ppd: PPDFile) {
        guard let media = ppd.option("CNIJMediaType") else { return nil }
        self.ppd = ppd

        let profiles: [PaperProfile] = (ppd.option("CNIJProfileID")?.choices ?? []).compactMap { choice in
            guard let path = ppd.iccProfiles[choice.label] else { return nil }
            return PaperProfile(profileID: choice.key, fileName: choice.label, url: URL(fileURLWithPath: path))
        }
        genericProfile = profiles.first { !$0.fileName.hasPrefix(Self.profilePrefix) }
        mediaTypes = media.choices.map { choice in
            MediaType(id: choice.key, name: choice.label, profile: Self.profile(forMedia: choice.label, in: profiles))
        }
        papers = Self.groupPapers(ppd.pageSizes)
        qualities = (ppd.option("CNIJPrintQuality")?.choices ?? []).map { Choice(id: $0.key, name: $0.label) }
        paperSources = (ppd.option("CNIJMediaSupply")?.choices ?? []).map { Choice(id: $0.key, name: $0.label) }
        dryingTimes = (ppd.option("CNIJDryingTimePage")?.choices ?? []).map { Choice(id: $0.key, name: $0.label) }
    }

    func mediaType(_ id: String) -> MediaType? { mediaTypes.first { $0.id == id } }

    func paper(_ id: String) -> Paper? { papers.first { $0.id == id } }

    /// Canon's profile for a media type, else Canon's generic one.
    func profile(for mediaID: String) -> PaperProfile? {
        mediaType(mediaID)?.profile ?? genericProfile
    }

    /// Profile used for color conversion: a chosen third-party profile, else Canon's.
    func profile(for settings: PrintSettings) -> PaperProfile? {
        if let path = settings.customProfilePath, FileManager.default.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path)
            return PaperProfile(profileID: "", fileName: url.lastPathComponent, url: url)
        }
        return profile(for: settings.mediaTypeID)
    }

    func pageSize(for settings: PrintSettings) -> PPDFile.PageSize? {
        guard let paper = paper(settings.paperID) else { return nil }
        return paper.variants[settings.margin] ?? paper.variants[.standard] ?? paper.variants.values.first
    }

    /// CUPS options for a job. Color correction in the driver is off: the app converts colors itself.
    func cupsOptions(for settings: PrintSettings) -> [String: String] {
        var options: [String: String] = [
            "CNIJMediaType": settings.mediaTypeID,
            "CNIJPrintQuality": settings.qualityID,
            "CNIJIntent2": Self.noColorCorrection,
            "ColorModel": "RGB16",
        ]
        if let page = pageSize(for: settings) { options["PageSize"] = page.name }
        if let profile = profile(for: settings.mediaTypeID) { options["CNIJProfileID"] = profile.profileID }
        if ppd.option("CNIJPrintMode2")?.label(for: "5") != nil { options["CNIJPrintMode2"] = "5" }
        // The quality slider uses the same labels as the quality list.
        let qualityName = ppd.option("CNIJPrintQuality")?.label(for: settings.qualityID)
        if let slider = ppd.option("CNIJPQualitySlider")?.choices.first(where: { $0.label == qualityName }) {
            options["CNIJPQualitySlider"] = slider.key
        }
        if let source = settings.paperSourceID { options["CNIJMediaSupply"] = source }
        if let drying = settings.dryingTimeID { options["CNIJDryingTimePage"] = drying }
        return options
    }

    /// Driver rules that the settings break, as readable text.
    func conflicts(for settings: PrintSettings) -> [String] {
        ppd.conflicts(in: cupsOptions(for: settings)).map { c in
            let first = ppd.option(c.key1)?.label(for: c.choice1 ?? "") ?? c.choice1 ?? c.key1
            let second = ppd.option(c.key2)?.label(for: c.choice2 ?? "") ?? c.choice2 ?? c.key2
            return "\(first) is not available with \(second)."
        }
    }

    func defaultSettings() -> PrintSettings {
        let paperID = papers.first { $0.variants[.standard]?.name == ppd.defaultChoice("PageSize") }?.id
            ?? papers.first?.id ?? ""
        return PrintSettings(
            paperID: paperID,
            margin: .standard,
            mediaTypeID: ppd.defaultChoice("CNIJMediaType") ?? mediaTypes.first?.id ?? "",
            qualityID: ppd.defaultChoice("CNIJPrintQuality") ?? qualities.first?.id ?? "",
            paperSourceID: ppd.defaultChoice("CNIJMediaSupply"),
            dryingTimeID: ppd.defaultChoice("CNIJDryingTimePage")
        )
    }

    // MARK: - Mapping helpers

    /// Matches "Photo Paper Pro Luster" to "CN_PRO-1000_500_PhotoPaperProLuster.icc".
    static func profile(forMedia name: String, in profiles: [PaperProfile]) -> PaperProfile? {
        let wanted = normalized(name)
        return profiles.first { profile in
            guard profile.fileName.hasPrefix(profilePrefix) else { return false }
            var base = String(profile.fileName.dropFirst(profilePrefix.count))
            base = base.replacingOccurrences(of: ".icc", with: "")
            if base.hasSuffix("-P") { base.removeLast(2) }
            return normalized(base) == wanted
        }
    }

    private static func normalized(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Groups PPD page sizes with the same dimensions into one paper with margin variants.
    static func groupPapers(_ sizes: [PPDFile.PageSize]) -> [Paper] {
        var order: [String] = []
        var groups: [String: [PPDFile.PageSize]] = [:]
        for size in sizes {
            let key = "\(Int((size.size.width * 2).rounded()))x\(Int((size.size.height * 2).rounded()))"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(size)
        }
        return order.compactMap { key in
            guard let group = groups[key] else { return nil }
            var variants: [Margin: PPDFile.PageSize] = [:]
            for size in group {
                variants[margin(of: size.name)] = variants[margin(of: size.name)] ?? size
            }
            guard let base = variants[.standard] ?? group.first else { return nil }
            return Paper(id: base.name, label: base.label, size: base.size, variants: variants)
        }
    }

    static func margin(of pageSizeName: String) -> Margin {
        if pageSizeName.hasSuffix(".FullBleed") { return .borderless }
        if pageSizeName.contains("ArtPaper25") || pageSizeName.contains("MARGIN_25") { return .artMargin }
        return .standard
    }
}

/// Printer settings for one sheet.
struct PrintSettings: Codable, Hashable, Sendable {
    var paperID: String
    var margin: CanonDriver.Margin
    var mediaTypeID: String
    var qualityID: String
    var paperSourceID: String?
    var dryingTimeID: String?
    /// Third-party ICC profile, e.g. from the paper maker. Nil uses Canon's profile for the media type.
    var customProfilePath: String?
}
