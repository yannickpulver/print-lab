import CoreGraphics
import Testing
@testable import CanonPrintLab

struct PPDFileTests {
    static let sample = """
    *PPD-Adobe: "4.3"
    *NickName: "Test Printer"
    *% A comment
    *OpenUI *PageSize/Paper Size: PickOne
    *DefaultPageSize: A4
    *PageSize A4/A4: "<</PageSize[595 842]>>setpagedevice"
    *PageSize A4.FullBleed/A4 borderless: "<</PageSize[595 842]
    >>setpagedevice"
    *de.PageSize A4/A4 (Deutsch): ""
    *CloseUI: *PageSize
    *PaperDimension A4/A4: "595.28 841.89"
    *PaperDimension A4.FullBleed/A4 borderless: "595.28 841.89"
    *ImageableArea A4/A4: "9.64 14.17 585.64 827.72"
    *ImageableArea A4.FullBleed/A4 borderless: "0 0 595.28 841.89"
    *OpenUI *CNIJMediaType/Media Type: PickOne
    *DefaultCNIJMediaType: 63
    *CNIJMediaType 0/Plain Paper: ""
    *CNIJMediaType 63/Photo Paper Pro Luster: ""
    *CloseUI: *CNIJMediaType
    *UIConstraints: *PageSize A4.FullBleed *CNIJMediaType 0
    *cupsICCProfile RGB16.5./CN_PRO-1000_500_PhotoPaperProLuster.icc: "/tmp/luster.icc"
    """

    @Test func parsesOptionsAndDefaults() {
        let ppd = PPDFile(text: Self.sample)
        #expect(ppd.nickName == "Test Printer")
        #expect(ppd.option("PageSize")?.label == "Paper Size")
        #expect(ppd.option("PageSize")?.choices.map(\.key) == ["A4", "A4.FullBleed"])
        #expect(ppd.defaultChoice("CNIJMediaType") == "63")
        #expect(ppd.option("CNIJMediaType")?.label(for: "63") == "Photo Paper Pro Luster")
    }

    @Test func parsesPageSizesInPoints() {
        let ppd = PPDFile(text: Self.sample)
        let a4 = ppd.pageSizes.first { $0.name == "A4" }
        #expect(a4?.size == CGSize(width: 595.28, height: 841.89))
        #expect(a4?.imageableArea.minX == 9.64)
        #expect(abs((a4?.imageableArea.maxY ?? 0) - 827.72) < 0.001)
    }

    @Test func findsConstraintConflicts() {
        let ppd = PPDFile(text: Self.sample)
        #expect(ppd.conflicts(in: ["PageSize": "A4.FullBleed", "CNIJMediaType": "0"]).count == 1)
        #expect(ppd.conflicts(in: ["PageSize": "A4.FullBleed", "CNIJMediaType": "63"]).isEmpty)
    }

    @Test func readsICCProfiles() {
        let ppd = PPDFile(text: Self.sample)
        #expect(ppd.iccProfiles["CN_PRO-1000_500_PhotoPaperProLuster.icc"] == "/tmp/luster.icc")
    }
}
