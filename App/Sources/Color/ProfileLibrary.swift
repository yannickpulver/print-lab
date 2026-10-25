import Foundation

/// Printer profiles installed on this Mac, e.g. from paper makers. Canon's own profiles are left out:
/// the app picks those by media type.
enum ProfileLibrary {
    static let folders = [
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/ColorSync/Profiles"),
        URL(fileURLWithPath: "/Library/ColorSync/Profiles"),
    ]

    static func printerProfiles() -> [CanonDriver.PaperProfile] {
        folders.flatMap { folder -> [CanonDriver.PaperProfile] in
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            return files
                .filter { ["icc", "icm"].contains($0.pathExtension.lowercased()) && !$0.lastPathComponent.hasPrefix("CN_") }
                .filter(isRGBPrinterProfile)
                .map { CanonDriver.PaperProfile(profileID: "", fileName: $0.lastPathComponent, url: $0) }
        }
        .sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
    }

    /// ICC header: device class "prtr" at byte 12, color space "RGB " at byte 16.
    static func isRGBPrinterProfile(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url), let header = try? handle.read(upToCount: 20),
              header.count == 20 else { return false }
        try? handle.close()
        return header[12..<16] == Data("prtr".utf8) && header[16..<20] == Data("RGB ".utf8)
    }
}
