import CoreGraphics
import Foundation
import ImageIO

struct LoadedImage: @unchecked Sendable {
    let image: CGImage
    /// Clockwise quarter turns needed to show the image upright (from EXIF orientation).
    let uprightTurns: Int

    /// Pixel size as displayed, orientation applied.
    var uprightSize: CGSize {
        uprightTurns % 2 == 0
            ? CGSize(width: image.width, height: image.height)
            : CGSize(width: image.height, height: image.width)
    }
}

enum ImageLoader {
    static let supportedTypes = ["public.tiff", "public.jpeg", "public.png", "public.heic", "com.adobe.photoshop-image"]

    /// Full-resolution image with its original bit depth and profile.
    static func load(_ url: URL) throws -> LoadedImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { throw CocoaError(.fileReadCorruptFile) }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = properties?[kCGImagePropertyOrientation] as? UInt32 ?? 1
        return LoadedImage(image: image, uprightTurns: turns(forEXIF: orientation))
    }

    /// Upright 16-bit buffer in the image's own profile, optionally downscaled.
    static func uprightBuffer(_ loaded: LoadedImage, maxPixelSize: Int? = nil) throws -> RGB16Image {
        let buffer = try ColorPipeline.normalize(loaded.image, maxPixelSize: maxPixelSize)
        return buffer.rotated(quarterTurns: loaded.uprightTurns)
    }

    /// EXIF orientations 1, 3, 6, 8. Mirrored variants are treated like their unmirrored rotation.
    static func turns(forEXIF orientation: UInt32) -> Int {
        switch orientation {
        case 3, 4: 2
        case 6, 5: 1
        case 8, 7: 3
        default: 0
        }
    }
}

extension RGB16Image {
    /// Rotates the pixels clockwise by quarter turns.
    func rotated(quarterTurns: Int) -> RGB16Image {
        let turns = ((quarterTurns % 4) + 4) % 4
        guard turns != 0 else { return self }
        let newW = turns % 2 == 0 ? width : height
        let newH = turns % 2 == 0 ? height : width
        var out = [UInt16](repeating: 0, count: pixels.count)
        for y in 0..<height {
            for x in 0..<width {
                let (nx, ny): (Int, Int)
                switch turns {
                case 1: (nx, ny) = (height - 1 - y, x)
                case 2: (nx, ny) = (width - 1 - x, height - 1 - y)
                default: (nx, ny) = (y, width - 1 - x)
                }
                let src = (y * width + x) * 3
                let dst = (ny * newW + nx) * 3
                out[dst] = pixels[src]
                out[dst + 1] = pixels[src + 1]
                out[dst + 2] = pixels[src + 2]
            }
        }
        return RGB16Image(width: newW, height: newH, pixels: out, profile: profile)
    }
}
