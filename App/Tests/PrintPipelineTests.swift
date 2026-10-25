import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import CanonPrintLab

/// End to end without paper: the app's PDF runs through macOS's own PDF-to-raster filter with the Canon
/// driver options. The raster that would go to Canon's driver must hold exactly the paper-profile values
/// the app computed, so nothing converts colors a second time.
@Suite(.enabled(if: TestSupport.canonPPD != nil && FileManager.default.fileExists(atPath: TestSupport.pdfToRaster)))
struct PrintPipelineTests {
    let driver = CanonDriver(ppd: try! PPDFile(contentsOf: TestSupport.canonPPD!))!

    @Test(arguments: [
        [52000, 30000, 12000],
        [8000, 20000, 45000],
        [32768, 32768, 32768],
        [65535, 65535, 65535],
    ] as [[UInt16]])
    func rasterHoldsPaperProfileValues(color: [UInt16]) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Uniform 16-bit sRGB image on disk.
        let srgb = ColorPipeline.profile(of: CGColorSpace(name: CGColorSpace.sRGB)!)!
        let source = RGB16Image(width: 64, height: 64, pixels: Array((0..<(64 * 64)).map { _ in color }.joined()),
                                profile: srgb)
        let imageURL = dir.appendingPathComponent("patch.tiff")
        try writeTIFF(source.cgImage()!, to: imageURL)

        // Baryta on A4, one image filling the content area.
        var settings = driver.defaultSettings()
        settings.paperID = "A4"
        settings.mediaTypeID = "17448"
        let page = try #require(driver.pageSize(for: settings))
        var sheet = Sheet(print: settings)
        LayoutEngine.relayout(&sheet, geometry: SheetGeometry(pageSize: page, orientation: .portrait), imageIDs: [])
        let id = UUID()
        sheet.cells[0].imageID = id

        let colorSettings = ColorSettings(intent: .relativeColorimetric, blackPointCompensation: true)
        let request = PrintRequest(sheet: sheet, queue: PrinterQueue(name: "test", info: "", deviceURI: "",
                                                                     ppdURL: TestSupport.canonPPD!),
                                   driver: driver, color: colorSettings, sources: [id: imageURL],
                                   captions: [:], title: "test")
        let pdf = dir.appendingPathComponent("sheet.pdf")
        try PrintJob.makePDF(request, to: pdf)

        // What the app expects the printer to receive.
        let paper = try ColorPipeline.profile(at: try #require(driver.profile(for: "17448")).url)
        let expected = try ColorPipeline.toPaper(
            RGB16Image(width: 1, height: 1, pixels: color, profile: srgb), paper: paper, settings: colorSettings
        ).pixels

        var options = driver.cupsOptions(for: settings)
        options["Resolution"] = "300x300dpi"
        let raster = try runFilter(pdf: pdf, options: options)
        let center = try Raster(data: raster).pixel(atPagePoint: CGPoint(x: page.size.width / 2,
                                                                          y: page.size.height / 2))
        // ±2 of 65535 covers rounding from the TIFF round trip. A second color conversion moves values
        // by thousands (black 0 → 2617 in the first experiment).
        let maxDiff = zip(center, expected).map { abs(Int($0) - Int($1)) }.max() ?? .max
        #expect(maxDiff <= 2, "sent \(color), expected \(expected), raster \(center)")
    }

    private func writeTIFF(_ image: CGImage, to url: URL) throws {
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.tiff" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
    }

    private func runFilter(pdf: URL, options: [String: String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: TestSupport.pdfToRaster)
        let optionString = options.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        process.arguments = ["1", "test", "test", "1", optionString, pdf.path]
        process.environment = [
            "PPD": TestSupport.canonPPD!.path,
            "CONTENT_TYPE": "application/pdf",
            "FINAL_CONTENT_TYPE": "application/vnd.cups-raster",
        ]
        let out = dir(for: pdf).appendingPathComponent("out.ras")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        process.standardOutput = try FileHandle(forWritingTo: out)
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return try Data(contentsOf: out)
    }

    private func dir(for url: URL) -> URL { url.deletingLastPathComponent() }
}

/// Reads a CUPS raster (v3, chunky RGB, 16 bit) as written by cgpdftoraster.
private struct Raster {
    let width: Int
    let bytesPerLine: Int
    let resolution: Double
    let imagingBox: CGRect
    let pixels: Data

    init(data: Data) throws {
        let ints: [UInt32] = data.withUnsafeBytes { raw in
            (0..<110).map { raw.loadUnaligned(fromByteOffset: 4 + 256 + $0 * 4, as: UInt32.self) }
        }
        width = Int(ints[29])
        bytesPerLine = Int(ints[34])
        resolution = Double(ints[5])
        // ImagingBoundingBox: left, bottom, right, top in points.
        imagingBox = CGRect(x: Int(ints[7]), y: Int(ints[8]), width: Int(ints[9] - ints[7]), height: Int(ints[10] - ints[8]))
        #expect(ints[32] == 16, "bits per color")
        pixels = data.subdata(in: (4 + 1796)..<data.count)
    }

    /// Pixel at a page position in points (origin bottom-left).
    func pixel(atPagePoint p: CGPoint) -> [UInt16] {
        let x = Int((p.x - imagingBox.minX) * resolution / 72)
        let y = Int((imagingBox.maxY - p.y) * resolution / 72)
        let offset = y * bytesPerLine + x * 6
        return pixels.withUnsafeBytes { raw in
            (0..<3).map { raw.loadUnaligned(fromByteOffset: offset + $0 * 2, as: UInt16.self) }
        }
    }
}
