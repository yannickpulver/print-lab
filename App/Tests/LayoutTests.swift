import CoreGraphics
import Foundation
import Testing
@testable import CanonPrintLab

struct LayoutTests {
    /// A4 with 3.4 mm side margins, 5 mm bottom, 5 mm top (in points).
    let a4 = PPDFile.PageSize(
        name: "A4", label: "A4", size: CGSize(width: 595.28, height: 841.89),
        imageableArea: CGRect(x: 9.64, y: 14.17, width: 576, height: 813.55)
    )

    @Test func portraitGeometryFlipsImageableAreaToTopLeft() {
        let g = SheetGeometry(pageSize: a4, orientation: .portrait)
        #expect(abs(g.paperSize.width - 210) < 0.01)
        #expect(abs(g.paperSize.height - 297) < 0.01)
        #expect(abs(g.printable.minX - 3.4) < 0.01)
        // 14.17 pt bottom margin = 5 mm, so the printable area ends 5 mm above the bottom edge.
        #expect(abs(g.printable.maxY - 292) < 0.01)
    }

    @Test func landscapeGeometrySwapsSidesAndKeepsMarginsOnTheSameEdges() {
        let g = SheetGeometry(pageSize: a4, orientation: .landscape)
        #expect(abs(g.paperSize.width - 297) < 0.01)
        #expect(abs(g.paperSize.height - 210) < 0.01)
        // The portrait bottom (5 mm) becomes the landscape left edge.
        #expect(abs(g.printable.minX - 5) < 0.01)
        #expect(abs(g.printable.width - Units.mm(813.55)) < 0.01)
    }

    @Test func contentRectStaysInsidePrintableArea() {
        let g = SheetGeometry(pageSize: a4, orientation: .portrait)
        let content = g.contentRect(margins: .all(1))
        #expect(g.printable.contains(content))
        #expect(abs(content.minX - 3.4) < 0.01)
    }

    @Test func gridFillsContentWithGaps() {
        var spec = LayoutSpec()
        spec.template = .grid
        spec.rows = 2
        spec.columns = 3
        spec.gapMM = 6
        let content = CGRect(x: 10, y: 10, width: 192, height: 100)
        let frames = LayoutEngine.frames(spec: spec, content: content, imageCount: 0)
        #expect(frames.count == 6)
        #expect(frames[0].width == 60)
        #expect(frames[0].height == 47)
        #expect(frames[5].maxX == content.maxX)
        #expect(frames[5].maxY == content.maxY)
    }

    @Test func contactSheetGrowsRowsWithImages() {
        var spec = LayoutSpec()
        spec.template = .contactSheet
        spec.columns = 4
        spec.captions = true
        let frames = LayoutEngine.frames(spec: spec, content: CGRect(x: 0, y: 0, width: 200, height: 280), imageCount: 9)
        #expect(frames.count == 12)
    }

    @Test func relayoutKeepsImagesInOrder() {
        let g = SheetGeometry(pageSize: a4, orientation: .portrait)
        var sheet = Sheet(print: PrintSettings(paperID: "A4", margin: .standard, mediaTypeID: "63", qualityID: "10"))
        sheet.layout.template = .grid
        LayoutEngine.relayout(&sheet, geometry: g, imageIDs: [])
        let a = UUID(), b = UUID()
        sheet.cells[0].imageID = a
        sheet.cells[1].imageID = b
        sheet.layout.columns = 3
        LayoutEngine.relayout(&sheet, geometry: g, imageIDs: [])
        #expect(sheet.cells.count == 6)
        #expect(sheet.cells.compactMap(\.imageID) == [a, b])
    }

    @Test func fillCoversCellAndFitStaysInside() {
        var cell = Cell(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let image = CGSize(width: 3000, height: 2000)
        let fill = SheetRenderer.imageRect(imageSize: image, cell: cell)
        #expect(fill.height == 100 && fill.width == 150)
        cell.fit = .fit
        let fit = SheetRenderer.imageRect(imageSize: image, cell: cell)
        #expect(fit.width == 100 && abs(fit.height - 66.667) < 0.01)
        cell.quarterTurns = 1
        let turned = SheetRenderer.imageRect(imageSize: image, cell: cell)
        #expect(abs(turned.width - 66.667) < 0.01 && turned.height == 100)
    }

    @Test func cropOffsetMovesWithinOverflow() {
        var cell = Cell(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        cell.cropOffset = CGPoint(x: 1, y: 0)
        let rect = SheetRenderer.imageRect(imageSize: CGSize(width: 3000, height: 2000), cell: cell)
        // Fully panned: the image's right edge meets the cell's right edge.
        #expect(rect.maxX == 100)
    }
}
