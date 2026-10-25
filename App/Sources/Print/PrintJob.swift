import CoreGraphics
import Foundation

struct PrintRequest: Sendable {
    let sheet: Sheet
    let queue: PrinterQueue
    let driver: CanonDriver
    let color: ColorSettings
    let sources: [UUID: URL]
    let captions: [UUID: String]
    let title: String
}

enum PrintJobError: LocalizedError {
    case noPageSize
    case noProfile
    case emptySheet

    var errorDescription: String? {
        switch self {
        case .noPageSize: "The selected paper size is not available."
        case .noProfile: "No color profile found for this paper."
        case .emptySheet: "The sheet has no images."
        }
    }
}

enum PrintJob {
    /// The Canon driver rasterizes at 600 dpi, more pixels add nothing.
    static let printPPI = 600.0

    /// Builds the print-ready PDF: every image converted into the paper profile, tagged as the handoff space.
    static func makePDF(_ request: PrintRequest, to url: URL) throws {
        let sheet = request.sheet
        guard let page = request.driver.pageSize(for: sheet.print) else { throw PrintJobError.noPageSize }
        guard let profileInfo = request.driver.profile(for: sheet.print) else { throw PrintJobError.noProfile }
        let paper = try ColorPipeline.profile(at: profileInfo.url)

        // Largest printed size per image, in pixels at print resolution.
        var loaded: [UUID: LoadedImage] = [:]
        var neededPixels: [UUID: Int] = [:]
        for cell in sheet.cells {
            guard let id = cell.imageID, let source = request.sources[id] else { continue }
            if loaded[id] == nil { loaded[id] = try ImageLoader.load(source) }
            let rect = SheetRenderer.imageRect(imageSize: loaded[id]!.uprightSize, cell: cell)
            let pixels = Int((max(rect.width, rect.height) / 25.4 * printPPI).rounded(.up))
            neededPixels[id] = max(neededPixels[id] ?? 0, pixels)
        }
        guard !loaded.isEmpty else { throw PrintJobError.emptySheet }

        var images: [UUID: CGImage] = [:]
        for (id, image) in loaded {
            try autoreleasepool {
                let buffer = try ImageLoader.uprightBuffer(image, maxPixelSize: neededPixels[id])
                let converted = try ColorPipeline.toPaper(buffer, paper: paper, settings: request.color)
                images[id] = converted.cgImage(taggedAs: ColorPipeline.handoffSpace)
            }
        }
        try SheetRenderer.writePDF(sheet, pageSize: page.size, images: images, captions: request.captions, to: url)
    }

    /// Builds the PDF and hands it to CUPS. Returns the job id.
    static func submit(_ request: PrintRequest) throws -> Int32 {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("canon-print-lab-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try makePDF(request, to: url)
        // CUPS copies the file into its spool, so the temporary PDF can go right after.
        return try CUPSClient.submit(
            file: url, title: request.title, queue: request.queue.name,
            options: request.driver.cupsOptions(for: request.sheet.print)
        )
    }
}
