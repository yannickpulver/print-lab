@preconcurrency import ColorSync
import CoreGraphics
import Foundation

enum RenderingIntent: String, CaseIterable, Codable, Sendable {
    case perceptual
    case relativeColorimetric

    var label: String {
        switch self {
        case .perceptual: "Perceptual"
        case .relativeColorimetric: "Relative Colorimetric"
        }
    }

    fileprivate var colorSync: CFString {
        switch self {
        case .perceptual: kColorSyncRenderingIntentPerceptual.takeUnretainedValue()
        case .relativeColorimetric: kColorSyncRenderingIntentRelative.takeUnretainedValue()
        }
    }
}

struct ColorSettings: Codable, Hashable, Sendable {
    var intent: RenderingIntent = .perceptual
    var blackPointCompensation = true
}

/// A 16-bit RGB pixel buffer with the profile its numbers belong to.
struct RGB16Image: @unchecked Sendable {
    let width: Int
    let height: Int
    /// Interleaved RGB, little-endian UInt16, no alpha.
    var pixels: [UInt16]
    let profile: ColorSyncProfile

    var bytesPerRow: Int { width * 6 }

    /// Pixel values tagged with an arbitrary color space (the numbers stay unchanged).
    func cgImage(taggedAs space: CGColorSpace) -> CGImage? {
        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 48, bytesPerRow: bytesPerRow,
            space: space, bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder16Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }

    /// Pixel values tagged with their own profile.
    func cgImage() -> CGImage? {
        guard let data = ColorSyncProfileCopyData(profile, nil)?.takeRetainedValue(),
              let space = CGColorSpace(iccData: data) else { return nil }
        return cgImage(taggedAs: space)
    }
}

enum ColorPipelineError: Error {
    case unreadableProfile(URL)
    case unsupportedImage
    case transformFailed
}

/// Color conversion with ColorSync.
///
/// Print path: source → paper profile. The result is later tagged as sRGB, the color space macOS hands
/// to the Canon driver, so neither macOS nor the driver ("No Color Correction") changes the numbers again.
enum ColorPipeline {
    static let handoffSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    static func profile(at url: URL) throws -> ColorSyncProfile {
        guard let profile = ColorSyncProfileCreateWithURL(url as CFURL, nil)?.takeRetainedValue() else {
            throw ColorPipelineError.unreadableProfile(url)
        }
        return profile
    }

    static func displayProfile() -> ColorSyncProfile {
        let space = CGColorSpace(name: CGColorSpace.displayP3)!
        return profile(of: space)!
    }

    static func profile(of space: CGColorSpace) -> ColorSyncProfile? {
        guard let data = space.copyICCData() else { return nil }
        return ColorSyncProfileCreate(data, nil)?.takeRetainedValue()
    }

    /// Draws any CGImage into a 16-bit RGB buffer. RGB images keep their profile and their numbers;
    /// other models (gray, CMYK, untagged) are converted to Display P3 first.
    static func normalize(_ image: CGImage, maxPixelSize: Int? = nil) throws -> RGB16Image {
        var width = image.width
        var height = image.height
        if let maxPixelSize, max(width, height) > maxPixelSize {
            let scale = Double(maxPixelSize) / Double(max(width, height))
            width = max(1, Int((Double(width) * scale).rounded()))
            height = max(1, Int((Double(height) * scale).rounded()))
        }
        let source = image.colorSpace
        let space: CGColorSpace
        if let source, source.model == .rgb, source.copyICCData() != nil {
            space = source
        } else {
            space = CGColorSpace(name: CGColorSpace.displayP3)!
        }
        guard let profile = profile(of: space) else { throw ColorPipelineError.unsupportedImage }

        // CoreGraphics needs a padded RGBX layout for 16-bit contexts.
        let rowBytes = width * 8
        var rgbx = [UInt16](repeating: 0, count: width * height * 4)
        let drawn: Bool = rgbx.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 16,
                bytesPerRow: rowBytes, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
            ) else { return false }
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw ColorPipelineError.unsupportedImage }

        var rgb = [UInt16](repeating: 0, count: width * height * 3)
        for i in 0..<(width * height) {
            rgb[i * 3] = rgbx[i * 4]
            rgb[i * 3 + 1] = rgbx[i * 4 + 1]
            rgb[i * 3 + 2] = rgbx[i * 4 + 2]
        }
        return RGB16Image(width: width, height: height, pixels: rgb, profile: profile)
    }

    /// Converts pixel values from the image's profile into `target`.
    static func convert(
        _ image: RGB16Image, to target: ColorSyncProfile, intent: CFString, blackPointCompensation: Bool
    ) throws -> RGB16Image {
        let sequence: [[String: Any]] = [
            [
                kColorSyncProfile.takeUnretainedValue() as String: image.profile,
                kColorSyncRenderingIntent.takeUnretainedValue() as String: intent,
                kColorSyncTransformTag.takeUnretainedValue() as String:
                    kColorSyncTransformDeviceToPCS.takeUnretainedValue(),
            ],
            [
                kColorSyncProfile.takeUnretainedValue() as String: target,
                kColorSyncRenderingIntent.takeUnretainedValue() as String: intent,
                kColorSyncTransformTag.takeUnretainedValue() as String:
                    kColorSyncTransformPCSToDevice.takeUnretainedValue(),
                kColorSyncBlackPointCompensation.takeUnretainedValue() as String: blackPointCompensation,
            ],
        ]
        guard let transform = ColorSyncTransformCreate(sequence as CFArray, nil)?.takeRetainedValue() else {
            throw ColorPipelineError.transformFailed
        }
        var output = [UInt16](repeating: 0, count: image.pixels.count)
        let layout = ColorSyncDataLayout(kColorSyncAlphaNone.rawValue) | ColorSyncDataLayout(kColorSyncByteOrder16Little)
        let ok = output.withUnsafeMutableBytes { dst in
            image.pixels.withUnsafeBytes { src in
                ColorSyncTransformConvert(
                    transform, image.width, image.height,
                    dst.baseAddress!, kColorSync16BitInteger, layout, image.bytesPerRow,
                    src.baseAddress!, kColorSync16BitInteger, layout, image.bytesPerRow, nil
                )
            }
        }
        guard ok else { throw ColorPipelineError.transformFailed }
        return RGB16Image(width: image.width, height: image.height, pixels: output, profile: target)
    }

    /// Source → paper profile with the chosen intent: the numbers the printer receives.
    static func toPaper(_ image: RGB16Image, paper: ColorSyncProfile, settings: ColorSettings) throws -> RGB16Image {
        try convert(image, to: paper, intent: settings.intent.colorSync,
                    blackPointCompensation: settings.blackPointCompensation)
    }

    /// Paper numbers → display. With `simulatePaperWhite` the paper's own white and black show on screen.
    static func softproof(_ paperImage: RGB16Image, simulatePaperWhite: Bool) throws -> RGB16Image {
        let intent = simulatePaperWhite
            ? kColorSyncRenderingIntentAbsolute.takeUnretainedValue()
            : kColorSyncRenderingIntentRelative.takeUnretainedValue()
        return try convert(paperImage, to: displayProfile(), intent: intent,
                           blackPointCompensation: !simulatePaperWhite)
    }
}
