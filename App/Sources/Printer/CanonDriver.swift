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
            case .artMargin: "Fine Art (25 mm)"
            }
        }
    }

    /// How the driver has to be set up for the margins a person wants.
    struct MarginPlan: Hashable, Sendable {
        let margin: Margin
        /// Lets fine art paper print closer to the edge than Canon's 25 mm.
        let cancelMarginRegulation: Bool
        /// Borderless bleed. Nil keeps the driver default; "0" keeps wanted margins exact.
        let borderlessExtension: String?
        let notes: [String]
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

    /// Canon regulates margins on art papers to 25 mm at top and bottom.
    func isFineArt(_ mediaID: String) -> Bool {
        guard let name = mediaType(mediaID)?.name else { return false }
        return ["Fine Art", "Canvas", "Washi"].contains { name.localizedCaseInsensitiveContains($0) }
    }

    /// Picks the page variant that allows the wanted margins: Fine Art, else Standard, else Borderless.
    func marginPlan(paperID: String, mediaID: String, orientation: Orientation, margins: EdgeInsetsMM) -> MarginPlan {
        guard let paper = paper(paperID) else {
            return MarginPlan(margin: .standard, cancelMarginRegulation: false, borderlessExtension: nil, notes: [])
        }
        func fits(_ margin: Margin) -> Bool {
            guard let page = paper.variants[margin] else { return false }
            let minimum = SheetGeometry(pageSize: page, orientation: orientation).minimumMargins
            let e = 0.05
            return margins.top >= minimum.top - e && margins.left >= minimum.left - e
                && margins.bottom >= minimum.bottom - e && margins.right >= minimum.right - e
        }
        let fineArt = isFineArt(mediaID)
        let belowArtMargin = "Below Canon's 25 mm fine art margin: the printer may leave marks near the paper edge."

        if fineArt, fits(.artMargin) {
            return MarginPlan(margin: .artMargin, cancelMarginRegulation: false, borderlessExtension: nil, notes: [])
        }
        if fits(.standard) {
            return MarginPlan(margin: .standard, cancelMarginRegulation: fineArt, borderlessExtension: nil,
                              notes: fineArt ? [belowArtMargin] : [])
        }
        if let page = paper.variants[.borderless],
           ppd.conflicts(in: ["PageSize": page.name, "CNIJMediaType": mediaID]).isEmpty {
            let bleed = min(margins.top, margins.left, margins.bottom, margins.right) < 0.05
            return MarginPlan(margin: .borderless, cancelMarginRegulation: fineArt,
                              borderlessExtension: bleed ? nil : "0", notes: fineArt ? [belowArtMargin] : [])
        }
        let name = mediaType(mediaID)?.name ?? "this media type"
        let minimum = paper.variants[.standard].map { SheetGeometry(pageSize: $0, orientation: orientation).minimumMargins }
        let smallest = minimum.map { String(format: " The smallest margins are %.0f–%.0f mm.",
                                            min($0.top, $0.left, $0.bottom, $0.right),
                                            max($0.top, $0.left, $0.bottom, $0.right)) } ?? ""
        return MarginPlan(margin: .standard, cancelMarginRegulation: fineArt, borderlessExtension: nil,
                          notes: ["Borderless is not available with \(name).\(smallest)"])
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
        if settings.cancelMarginRegulation == true, ppd.option("CNIJCancelMarginRegulation") != nil {
            options["CNIJCancelMarginRegulation"] = "2"
        }
        if settings.margin == .borderless, let amount = settings.borderlessExtensionID {
            options["CNIJAmountOfExtension"] = amount
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

    /// Short codes paper makers put into profile names for the Canon media type they profiled with,
    /// e.g. TECCO_pro1000_PD190_HWFAP.icc.
    static let mediaCodes: [String: String] = [
        "HWFAP": "Heavyweight Fine Art Paper",
        "EHWFAP": "Extra Heavyweight Fine Art Paper",
        "HDFAP": "Highest Density Fine Art Paper",
        "PFAS": "Premium Fine Art Smooth",
        "MPP": "Matte Photo Paper",
        "PPPS": "Photo Paper Plus Semi-gloss",
        "PPPG2": "Photo Paper Plus Glossy II",
        "PPPL": "Photo Paper Pro Luster",
        "PPPP": "Photo Paper Pro Platinum",
        "BPP": "Baryta Photo Paper",
        "HWPP": "Heavyweight Photo Paper",
        "LWPP": "Lightweight Photo Paper",
    ]

    /// Paper maker prefixes in profile file names.
    static let profileMakers: [String: String] = [
        "CN": "Canon",
        "HFA": "Hahnemühle",
        "HANEMUEHLE": "Hahnemühle",
        "HAHNEMUEHLE": "Hahnemühle",
        "TECCO": "Tecco",
        "ILFORD": "Ilford",
        "CANSON": "Canson",
        "MOAB": "Moab",
    ]

    /// Readable name from a profile file name: maker and paper, ink in brackets.
    /// "HFA_CanPro1000_MK_PhotoRag.icc" → "Hahnemühle Photo Rag (MK)",
    /// "CN_PRO-1000_500_PhotoPaperProLuster.icc" → "Canon Photo Paper Pro Luster".
    static func displayName(forProfileNamed fileName: String) -> String {
        var base = (fileName as NSString).deletingPathExtension
        if base.hasPrefix(profilePrefix) {
            base.removeFirst(profilePrefix.count)
            if base.hasSuffix("-P") { base.removeLast(2) }
            return "Canon " + spaced(base)
        }
        let printerTokens: Set<String> = ["CAN", "PRO", "CANPRO", "1000", "PRO1000", "CANPRO1000"]
        var maker: String?
        var ink: String?
        var words: [String] = []
        for token in base.split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == " " }).map(String.init) {
            let upper = token.uppercased()
            if maker == nil, words.isEmpty, let name = profileMakers[upper] {
                maker = name
            } else if upper == "MK" || upper == "PK" {
                ink = upper
            } else if !printerTokens.contains(upper), mediaCodes[upper] == nil {
                words.append(spaced(token))
            }
        }
        guard !words.isEmpty else { return base.replacingOccurrences(of: "_", with: " ") }
        let name = ([maker].compactMap { $0 } + words).joined(separator: " ")
        return ink.map { "\(name) (\($0))" } ?? name
    }

    /// "PhotoPaperProLuster" → "Photo Paper Pro Luster", "FAPearl" → "FA Pearl".
    private static func spaced(_ s: String) -> String {
        let chars = Array(s)
        var out = ""
        for (i, c) in chars.enumerated() {
            if i > 0, c.isUppercase {
                let previous = chars[i - 1]
                let next = i + 1 < chars.count ? chars[i + 1] : nil
                if previous.isLowercase || (previous.isUppercase && next?.isLowercase == true) { out.append(" ") }
            }
            out.append(c)
        }
        return out
    }

    /// Media type a profile was made for, read from its file name. Nil when the name does not say.
    func mediaType(forProfileNamed fileName: String) -> MediaType? {
        if let canon = mediaTypes.first(where: { $0.profile?.fileName == fileName }) { return canon }
        let base = (fileName as NSString).deletingPathExtension
        let tokens = base.split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == " " }).map { $0.uppercased() }
        for token in tokens.reversed() {
            if let name = Self.mediaCodes[token], let media = mediaTypes.first(where: { $0.name == name }) {
                return media
            }
        }
        return nil
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
    /// Set from the margins, see `CanonDriver.marginPlan`.
    var cancelMarginRegulation: Bool?
    var borderlessExtensionID: String?

    mutating func apply(_ plan: CanonDriver.MarginPlan) {
        margin = plan.margin
        cancelMarginRegulation = plan.cancelMarginRegulation
        borderlessExtensionID = plan.borderlessExtension
    }
}
