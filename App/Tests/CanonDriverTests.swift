import Foundation
import Testing
@testable import PrintLab

/// Runs against the Canon PPD installed on this Mac. Skipped elsewhere.
@Suite(.enabled(if: TestSupport.canonPPD != nil))
struct CanonDriverTests {
    let driver = CanonDriver(ppd: try! PPDFile(contentsOf: TestSupport.canonPPD!))!

    @Test func readsAllMediaTypes() {
        #expect(driver.mediaTypes.count == 22)
        #expect(driver.mediaType("17448")?.name == "Baryta Photo Paper")
    }

    @Test func mapsEveryPhotoPaperToItsProfile() {
        let withoutProfile = driver.mediaTypes.filter { $0.profile == nil }.map(\.name)
        #expect(Set(withoutProfile) == ["Plain Paper", "Hagaki A", "Ink Jet Hagaki", "Hagaki"])
        #expect(driver.mediaType("17448")?.profile?.fileName == "CN_PRO-1000_500_BarytaPhotoPaper-P.icc")
        #expect(driver.mediaType("17448")?.profile?.profileID == "11")
        for media in driver.mediaTypes {
            if let url = media.profile?.url {
                #expect(FileManager.default.fileExists(atPath: url.path), "\(media.name)")
            }
        }
    }

    @Test func groupsMediaTypesIntoSections() {
        let sections = driver.mediaSections
        #expect(sections.map(\.title) == ["Photo", "Matte", "Fine Art", "Other"])
        #expect(sections.flatMap(\.media).count == driver.mediaTypes.count)
        let names = Dictionary(uniqueKeysWithValues: sections.map { ($0.title, $0.media.map(\.name)) })
        #expect(names["Matte"] == ["Matte Photo Paper", "Photo Paper Pro Premium Matte A", "Photo Paper Pro Premium Matte"])
        #expect(names["Fine Art"]?.last == "Japanese Paper Washi")
        #expect(names["Other"] == ["Plain Paper", "Hagaki A", "Ink Jet Hagaki", "Hagaki"])
        #expect(names["Photo"]?.contains("Baryta Photo Paper") == true)
    }

    @Test func plainPaperFallsBackToGenericProfile() {
        #expect(driver.profile(for: "0")?.fileName == "CN_IJPrinter_Profile2015.icc")
    }

    @Test func customProfileOverridesCanonProfile() throws {
        let path = NSTemporaryDirectory() + "TECCO_test.icc"
        FileManager.default.createFile(atPath: path, contents: Data([0]))
        defer { try? FileManager.default.removeItem(atPath: path) }
        var settings = driver.defaultSettings()
        settings.mediaTypeID = "75"
        #expect(driver.profile(for: settings)?.fileName == "CN_PRO-1000_500_HeavyweightFineArtPaper-P.icc")
        settings.customProfilePath = path
        #expect(driver.profile(for: settings)?.fileName == "TECCO_test.icc")
        // The driver still gets "No Color Correction"; the profile only matters inside the app.
        #expect(driver.cupsOptions(for: settings)["CNIJIntent2"] == "1001")
    }

    // Media ids from the PPD: 63 Photo Paper Pro Luster, 0 Plain Paper, 75 Heavyweight Fine Art Paper.

    @Test func normalMarginsUseStandardPage() {
        let plan = driver.marginPlan(paperID: "A4", mediaID: "63", orientation: .portrait, margins: .all(15))
        #expect(plan.margin == .standard)
        #expect(plan.cancelMarginRegulation == false)
        #expect(plan.notes.isEmpty)
    }

    @Test func smallMarginsSwitchToBorderlessWithoutBleed() {
        // 2 mm is below the standard minimum (3–5 mm) but not 0: keep the margins exact.
        let plan = driver.marginPlan(paperID: "A4", mediaID: "63", orientation: .portrait, margins: .all(2))
        #expect(plan.margin == .borderless)
        #expect(plan.borderlessExtension == "0")
    }

    @Test func zeroMarginBleedsWithDriverDefault() {
        var margins = EdgeInsetsMM.all(10)
        margins.left = 0
        let plan = driver.marginPlan(paperID: "A4", mediaID: "63", orientation: .portrait, margins: margins)
        #expect(plan.margin == .borderless)
        #expect(plan.borderlessExtension == nil)
    }

    @Test func plainPaperCannotGoBorderless() {
        let plan = driver.marginPlan(paperID: "A4", mediaID: "0", orientation: .portrait, margins: .all(0))
        #expect(plan.margin == .standard)
        #expect(plan.notes.count == 1)
    }

    @Test func fineArtUsesCanonsArtMarginWhenMarginsAllowIt() {
        let plan = driver.marginPlan(paperID: "A4", mediaID: "75", orientation: .portrait, margins: .all(25))
        #expect(plan.margin == .artMargin)
        #expect(plan.cancelMarginRegulation == false)
    }

    @Test func fineArtBelow25mmCancelsMarginRegulation() {
        var settings = driver.defaultSettings()
        settings.paperID = "A4"
        settings.mediaTypeID = "75"
        let plan = driver.marginPlan(paperID: "A4", mediaID: "75", orientation: .portrait, margins: .all(10))
        settings.apply(plan)
        #expect(plan.margin == .standard)
        #expect(plan.notes.count == 1)
        #expect(driver.cupsOptions(for: settings)["CNIJCancelMarginRegulation"] == "2")
    }

    @Test func landscapeComparesMarginsOnTheTurnedEdges() {
        // Fine art 25 mm sits at the portrait top and bottom, which are left and right in landscape.
        var margins = EdgeInsetsMM.all(10)
        margins.left = 25
        margins.right = 25
        let plan = driver.marginPlan(paperID: "A4", mediaID: "75", orientation: .landscape, margins: margins)
        #expect(plan.margin == .artMargin)
    }

    @Test func readsMediaTypeFromProfileNames() {
        #expect(driver.mediaType(forProfileNamed: "TECCO_pro1000_PD190_HWFAP.icc")?.name == "Heavyweight Fine Art Paper")
        #expect(driver.mediaType(forProfileNamed: "TECCO_pro1000_PPG250_PPPS.icc")?.name == "Photo Paper Plus Semi-gloss")
        #expect(driver.mediaType(forProfileNamed: "CN_PRO-1000_500_BarytaPhotoPaper-P.icc")?.id == "17448")
        // Hahnemühle names say nothing about the media type.
        #expect(driver.mediaType(forProfileNamed: "HFA_CanPro1000_MK_PhotoRag.icc") == nil)
    }

    @Test(arguments: [
        ("CN_PRO-1000_500_HighestDensityFineArtPaper-P.icc", "Canon Highest Density Fine Art Paper"),
        ("CN_PRO-1000_500_PhotoPaperProLuster.icc", "Canon Photo Paper Pro Luster"),
        ("CN_PRO-200_S1_HeavyweightFineArtPaper-P.icc", "Canon Heavyweight Fine Art Paper"),
        ("CN_PRO-200S_S1MkII_PhotoPaperPlusSemi-gloss.icc", "Canon Photo Paper Plus Semi-gloss"),
        ("HFA_CanPro1000_MK_PhotoRag.icc", "Hahnemühle Photo Rag (MK)"),
        ("Hanemuehle_CanPro1000_PK_FAPearl_BarytaSetting_BarytaPapier.icc", "Hahnemühle FA Pearl Baryta Setting Baryta Papier (PK)"),
        ("TECCO_pro1000_PD190_HWFAP.icc", "Tecco PD190"),
        ("ILFORD_CANpro-1000_GPTC_HDFAP.icc", "Ilford GPTC"),
        ("My Paper.icc", "My Paper"),
    ])
    func readableProfileNames(fileName: String, expected: String) {
        #expect(CanonDriver.displayName(forProfileNamed: fileName) == expected)
    }

    @Test func groupsPaperSizesWithMarginVariants() {
        let a3 = driver.paper("A3")
        #expect(a3?.variants[.standard]?.name == "A3")
        #expect(a3?.variants[.borderless]?.name == "A3.FullBleed")
        #expect(a3?.variants[.artMargin]?.name == "A3.ArtPaper25")
        #expect(driver.paper("329x483mm")?.variants[.artMargin]?.name == "DMSIZE_A3_PLUS_MARGIN_25")
    }

    @Test func turnsOffDriverColorCorrection() {
        var settings = driver.defaultSettings()
        settings.paperID = "A3"
        settings.mediaTypeID = "17448"
        settings.qualityID = "0"
        let options = driver.cupsOptions(for: settings)
        #expect(options["CNIJIntent2"] == "1001")
        #expect(options["ColorModel"] == "RGB16")
        #expect(options["PageSize"] == "A3")
        #expect(options["CNIJProfileID"] == "11")
        #expect(options["CNIJPQualitySlider"] == "5")
    }

    @Test func reportsBorderlessOnPlainPaper() {
        var settings = driver.defaultSettings()
        settings.paperID = "A4"
        settings.margin = .borderless
        settings.mediaTypeID = "0"
        #expect(driver.conflicts(for: settings).count == 1)
        settings.mediaTypeID = "17448"
        #expect(driver.conflicts(for: settings).isEmpty)
    }
}

/// Profile names from Canon's PRO-200 driver (30.10.1.0): other printers use other prefixes.
struct CanonProfileNameTests {
    let profiles = [
        "CN_IJPrinter_Profile2015.icc",
        "CN_PRO-200_S1_PhotoPaperPlusGlossyIIA.icc",
        "CN_PRO-200_S1_PhotoPaperProLuster.icc",
        "CN_PRO-200_S1_PhotoPaperPlusSemi-gloss.icc",
        "CN_PRO-200_S1_HeavyweightFineArtPaper-P.icc",
        "CN_PRO-200_S1_ExtraHeavyweightFineArtPaper-P.icc",
        "CN_PRO-200_S1_Canvas-P.icc",
    ].enumerated().map { index, name in
        CanonDriver.PaperProfile(profileID: "\(index + 1)", fileName: name, url: URL(fileURLWithPath: "/" + name))
    }

    @Test(arguments: [
        ("Photo Paper Plus Glossy II A", "CN_PRO-200_S1_PhotoPaperPlusGlossyIIA.icc"),
        ("Photo Paper Pro Luster", "CN_PRO-200_S1_PhotoPaperProLuster.icc"),
        ("Photo Paper Plus Semi-gloss", "CN_PRO-200_S1_PhotoPaperPlusSemi-gloss.icc"),
        ("Heavyweight Fine Art Paper", "CN_PRO-200_S1_HeavyweightFineArtPaper-P.icc"),
        ("Extra Heavyweight Fine Art Paper", "CN_PRO-200_S1_ExtraHeavyweightFineArtPaper-P.icc"),
        ("Canvas", "CN_PRO-200_S1_Canvas-P.icc"),
    ])
    func mapsMediaToProfile(media: String, fileName: String) {
        #expect(CanonDriver.profile(forMedia: media, in: profiles)?.fileName == fileName)
    }

    @Test func plainPaperHasNoProfile() {
        #expect(CanonDriver.profile(forMedia: "Plain Paper", in: profiles) == nil)
        #expect(CanonDriver.canonMediaName(ofProfileNamed: "CN_IJPrinter_Profile2015.icc") == nil)
    }
}

enum TestSupport {
    static let pdfToRaster = "/usr/libexec/cups/filter/cgpdftoraster"

    static let canonPPD: URL? = {
        let dir = URL(fileURLWithPath: "/etc/cups/ppd")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.first { url in
            guard url.pathExtension == "ppd", let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
            return text.contains("*OpenUI *CNIJMediaType") && text.contains("PRO-1000")
        }
    }()
}
