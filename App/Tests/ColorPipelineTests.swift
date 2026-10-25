@preconcurrency import ColorSync
import CoreGraphics
import Foundation
import Testing
@testable import CanonPrintLab

struct ColorPipelineTests {
    let srgb = ColorPipeline.profile(of: CGColorSpace(name: CGColorSpace.sRGB)!)!

    @Test func sameProfileKeepsValues() throws {
        let image = RGB16Image(width: 2, height: 1, pixels: [0, 32768, 65535, 52000, 30000, 12000], profile: srgb)
        let out = try ColorPipeline.convert(
            image, to: srgb, intent: kColorSyncRenderingIntentRelative.takeUnretainedValue(),
            blackPointCompensation: false
        )
        for (a, b) in zip(image.pixels, out.pixels) {
            #expect(abs(Int(a) - Int(b)) <= 2)
        }
    }

    @Test func normalizeKeeps16BitNumbersOfRGBImages() throws {
        let pixels: [UInt16] = [1234, 40000, 65535]
        let source = RGB16Image(width: 1, height: 1, pixels: pixels, profile: srgb)
        let normalized = try ColorPipeline.normalize(source.cgImage()!)
        #expect(normalized.pixels == pixels)
    }

    @Test func rotatesPixelsClockwise() {
        // 2×1: red, blue → after a quarter turn 1×2: red on top, blue below.
        let image = RGB16Image(width: 2, height: 1, pixels: [65535, 0, 0, 0, 0, 65535], profile: srgb)
        let turned = image.rotated(quarterTurns: 1)
        #expect(turned.width == 1 && turned.height == 2)
        #expect(turned.pixels == [65535, 0, 0, 0, 0, 65535])
        let back = image.rotated(quarterTurns: 3)
        #expect(back.pixels == [0, 0, 65535, 65535, 0, 0])
    }

    @Test(.enabled(if: TestSupport.canonPPD != nil))
    func paperConversionMapsWhiteToPaperWhiteAndChangesMidtones() throws {
        let paper = try ColorPipeline.profile(
            at: URL(fileURLWithPath: "/Library/ColorSync/Profiles/CN_PRO-1000_500_BarytaPhotoPaper-P.icc"))
        let image = RGB16Image(width: 2, height: 1, pixels: [65535, 65535, 65535, 52000, 30000, 12000], profile: srgb)
        let out = try ColorPipeline.toPaper(image, paper: paper, settings: ColorSettings())
        // White stays (nearly) paper white, a saturated orange gets new device values.
        #expect(out.pixels[0...2].allSatisfy { $0 > 64000 })
        #expect(Array(out.pixels[3...5]) != [52000, 30000, 12000])
    }
}
