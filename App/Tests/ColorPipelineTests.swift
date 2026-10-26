@preconcurrency import ColorSync
import CoreGraphics
import Foundation
import Testing
@testable import PrintLab

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

    @Test(.enabled(if: TestSupport.canonPPD != nil))
    func softproofShowsPaperBlackAsDisplayBlack() throws {
        let paper = try ColorPipeline.profile(
            at: URL(fileURLWithPath: "/Library/ColorSync/Profiles/CN_PRO-1000_500_HighestDensityFineArtPaper-P.icc"))
        let black = RGB16Image(width: 1, height: 1, pixels: [0, 0, 0], profile: paper)
        // Matte paper black is around L* 16; black point compensation maps it to display black.
        let proof = try ColorPipeline.softproof(black, simulatePaperWhite: false)
        #expect(proof.pixels.allSatisfy { $0 < 1500 })
        // Simulating the paper keeps its lighter black.
        let paperBlack = try ColorPipeline.softproof(black, simulatePaperWhite: true)
        #expect(paperBlack.pixels.allSatisfy { $0 > 6000 })
    }

    @Test(.enabled(if: TestSupport.canonPPD != nil))
    func blackPointCompensationPrintsDeepestPaperBlack() throws {
        let paper = try ColorPipeline.profile(
            at: URL(fileURLWithPath: "/Library/ColorSync/Profiles/CN_PRO-1000_500_HighestDensityFineArtPaper-P.icc"))
        // Canon's matte profile squeezes the shadows into paper black itself. Aiming source black at the
        // profile's RGB 0,0,0 printed it at device ~6000 and proofed it at display ~10000.
        let black = RGB16Image(width: 1, height: 1, pixels: [0, 0, 0], profile: srgb)
        let settings = ColorSettings(intent: .relativeColorimetric, blackPointCompensation: true)
        let onPaper = try ColorPipeline.toPaper(black, paper: paper, settings: settings)
        #expect(onPaper.pixels.allSatisfy { $0 < 500 })
        let proof = try ColorPipeline.softproof(onPaper, simulatePaperWhite: false)
        #expect(proof.pixels.allSatisfy { $0 < 1000 })
    }

    @Test(.enabled(if: TestSupport.canonPPD != nil))
    func blackPointCompensationLiftsShadowsIntoPaperBlack() throws {
        let paper = try ColorPipeline.profile(
            at: URL(fileURLWithPath: "/Library/ColorSync/Profiles/CN_PRO-1000_500_HighestDensityFineArtPaper-P.icc"))
        // Two dark grays that relative colorimetric clips to the same paper black.
        let image = RGB16Image(width: 2, height: 1, pixels: [2000, 2000, 2000, 6000, 6000, 6000], profile: srgb)
        var settings = ColorSettings(intent: .relativeColorimetric, blackPointCompensation: false)
        let clipped = try ColorPipeline.toPaper(image, paper: paper, settings: settings)
        settings.blackPointCompensation = true
        let compensated = try ColorPipeline.toPaper(image, paper: paper, settings: settings)
        #expect(clipped.pixels != compensated.pixels)
        #expect(compensated.pixels[3] > compensated.pixels[0])
    }

    @Test(.enabled(if: TestSupport.canonPPD != nil))
    func blackPointCompensationKeepsLightColors() throws {
        let paper = try ColorPipeline.profile(
            at: URL(fileURLWithPath: "/Library/ColorSync/Profiles/CN_PRO-1000_500_HighestDensityFineArtPaper-P.icc"))
        // A light warm gray, like a hazy sky. ColorSync's own compensation turned it bluish.
        let sky = RGB16Image(width: 1, height: 1, pixels: [61000, 60000, 57000], profile: srgb)
        let relative = kColorSyncRenderingIntentRelative.takeUnretainedValue()
        let onPaper = try ColorPipeline.convert(sky, to: paper, intent: relative, blackPointCompensation: false)
        let plain = try ColorPipeline.convert(onPaper, to: srgb, intent: relative, blackPointCompensation: false)
        let compensated = try ColorPipeline.convert(onPaper, to: srgb, intent: relative, blackPointCompensation: true)
        for (a, b) in zip(plain.pixels, compensated.pixels) {
            #expect(abs(Int(a) - Int(b)) < 800)
        }
        // Blue must not rise against red.
        #expect(Int(compensated.pixels[2]) - Int(compensated.pixels[0]) <= Int(plain.pixels[2]) - Int(plain.pixels[0]) + 300)
    }
}
