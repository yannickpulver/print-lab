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
        if blackPointCompensation {
            return try convertCompensatingBlack(image, to: target, intent: intent)
        }
        let transform = try transform(image.profile, target, intent)
        var output = [UInt16](repeating: 0, count: image.pixels.count)
        let ok = output.withUnsafeMutableBytes { dst in
            image.pixels.withUnsafeBytes { src in
                ColorSyncTransformConvert(
                    transform, image.width, image.height,
                    dst.baseAddress!, kColorSync16BitInteger, rgb16, image.bytesPerRow,
                    src.baseAddress!, kColorSync16BitInteger, rgb16, image.bytesPerRow, nil
                )
            }
        }
        guard ok else { throw ColorPipelineError.transformFailed }
        return RGB16Image(width: image.width, height: image.height, pixels: output, profile: target)
    }

    /// Black point compensation as Adobe does it: in XYZ, source black → target black, white unchanged.
    /// ColorSync's own (`kColorSyncBlackPointCompensation`) also shifts colors: a light sky turned about
    /// 10 b* bluer with every paper profile tried.
    private static func convertCompensatingBlack(
        _ image: RGB16Image, to target: ColorSyncProfile, intent: CFString
    ) throws -> RGB16Image {
        guard let xyz = ColorSyncProfileCreateWithName(kColorSyncGenericXYZProfile.takeUnretainedValue())?
            .takeRetainedValue() else { throw ColorPipelineError.transformFailed }
        let toXYZ = try transform(image.profile, xyz, intent)
        let fromXYZ = try transform(xyz, target, intent)

        // Black and white of both sides, measured through the same intent.
        let ends: [UInt16] = [0, 0, 0, 65535, 65535, 65535]
        let source = try xyzValues(of: ends, through: toXYZ)
        let destination = try xyzValues(of: ends, through: transform(target, xyz, intent))
        // v' = (v - source black) / (source white - source black) * (target range) + target black
        var scale = [Float](repeating: 1, count: 3)
        var offset = [Float](repeating: 0, count: 3)
        for c in 0..<3 {
            let targetRange: Float = destination[3 + c] - destination[c]
            let sourceRange: Float = source[3 + c] - source[c]
            scale[c] = targetRange / sourceRange
            offset[c] = destination[c] - source[c] * scale[c]
        }

        // In strips, so a large print does not hold a full float copy of the image.
        let width = image.width
        let stripRows = max(1, 1 << 20 / max(1, width))
        var output = [UInt16](repeating: 0, count: image.pixels.count)
        var strip = [Float](repeating: 0, count: stripRows * width * 3)
        var ok = true
        for y in stride(from: 0, to: image.height, by: stripRows) where ok {
            let rows = min(stripRows, image.height - y)
            let start = y * width * 3
            let count = rows * width * 3
            ok = strip.withUnsafeMutableBytes { xyzBuffer in
                image.pixels.withUnsafeBytes { src in
                    ColorSyncTransformConvert(
                        toXYZ, width, rows, xyzBuffer.baseAddress!, kColorSync32BitFloat, xyz32, width * 12,
                        src.baseAddress! + start * 2, kColorSync16BitInteger, rgb16, image.bytesPerRow, nil)
                }
            }
            guard ok else { break }
            for i in 0..<count {
                let c = i % 3
                strip[i] = strip[i] * scale[c] + offset[c]
            }
            ok = output.withUnsafeMutableBytes { dst in
                strip.withUnsafeBytes { xyzBuffer in
                    ColorSyncTransformConvert(
                        fromXYZ, width, rows, dst.baseAddress! + start * 2, kColorSync16BitInteger, rgb16,
                        image.bytesPerRow, xyzBuffer.baseAddress!, kColorSync32BitFloat, xyz32, width * 12, nil)
                }
            }
        }
        guard ok else { throw ColorPipelineError.transformFailed }
        return RGB16Image(width: image.width, height: image.height, pixels: output, profile: target)
    }

    private static let rgb16 = ColorSyncDataLayout(kColorSyncAlphaNone.rawValue)
        | ColorSyncDataLayout(kColorSyncByteOrder16Little)
    private static let xyz32 = ColorSyncDataLayout(kColorSyncAlphaNone.rawValue)
        | ColorSyncDataLayout(kColorSyncByteOrder32Little)

    private static func transform(
        _ from: ColorSyncProfile, _ to: ColorSyncProfile, _ intent: CFString
    ) throws -> ColorSyncTransform {
        let sequence: [[String: Any]] = [
            [
                kColorSyncProfile.takeUnretainedValue() as String: from,
                kColorSyncRenderingIntent.takeUnretainedValue() as String: intent,
                kColorSyncTransformTag.takeUnretainedValue() as String:
                    kColorSyncTransformDeviceToPCS.takeUnretainedValue(),
            ],
            [
                kColorSyncProfile.takeUnretainedValue() as String: to,
                kColorSyncRenderingIntent.takeUnretainedValue() as String: intent,
                kColorSyncTransformTag.takeUnretainedValue() as String:
                    kColorSyncTransformPCSToDevice.takeUnretainedValue(),
            ],
        ]
        guard let transform = ColorSyncTransformCreate(sequence as CFArray, nil)?.takeRetainedValue() else {
            throw ColorPipelineError.transformFailed
        }
        return transform
    }

    private static func xyzValues(of pixels: [UInt16], through transform: ColorSyncTransform) throws -> [Float] {
        let count = pixels.count / 3
        var values = [Float](repeating: 0, count: pixels.count)
        let ok = values.withUnsafeMutableBytes { dst in
            pixels.withUnsafeBytes { src in
                ColorSyncTransformConvert(transform, count, 1, dst.baseAddress!, kColorSync32BitFloat, xyz32,
                                          count * 12, src.baseAddress!, kColorSync16BitInteger, rgb16, count * 6, nil)
            }
        }
        guard ok else { throw ColorPipelineError.transformFailed }
        return values
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
