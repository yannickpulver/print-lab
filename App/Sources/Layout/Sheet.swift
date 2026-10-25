import CoreGraphics
import Foundation

enum Orientation: String, CaseIterable, Codable, Sendable {
    case portrait
    case landscape
}

enum Fit: String, CaseIterable, Codable, Sendable {
    /// Image fills the cell, overflow is cropped.
    case fill
    /// Whole image visible inside the cell.
    case fit
}

enum Template: String, CaseIterable, Codable, Sendable {
    case single
    case grid
    case contactSheet

    var label: String {
        switch self {
        case .single: "Single image"
        case .grid: "Grid"
        case .contactSheet: "Contact sheet"
        }
    }
}

struct EdgeInsetsMM: Codable, Hashable, Sendable {
    var top: Double
    var left: Double
    var bottom: Double
    var right: Double

    static func all(_ v: Double) -> EdgeInsetsMM { EdgeInsetsMM(top: v, left: v, bottom: v, right: v) }
}

struct LayoutSpec: Codable, Hashable, Sendable {
    var template: Template = .single
    var rows = 2
    var columns = 2
    var gapMM = 5.0
    var margins = EdgeInsetsMM.all(15)
    var captions = false
    var captionHeightMM = 5.0
    /// Turns images a quarter when their orientation differs from the cell.
    var autoRotate = true
}

/// One image slot on the sheet. Frames are in millimeters, origin at the top-left paper corner.
struct Cell: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var frame: CGRect
    var imageID: UUID?
    var fit: Fit = .fill
    /// Clockwise quarter turns.
    var quarterTurns = 0
    /// Pan inside a `.fill` crop, -1...1 per axis, 0 = centered.
    var cropOffset = CGPoint.zero
}

struct Sheet: Codable, Hashable, Sendable {
    var print: PrintSettings
    var orientation: Orientation = .portrait
    var layout = LayoutSpec()
    var cells: [Cell] = []
}

enum Units {
    static let mmPerPoint = 25.4 / 72
    static func mm(_ points: CGFloat) -> Double { Double(points) * mmPerPoint }
    static func points(_ mm: Double) -> CGFloat { CGFloat(mm / mmPerPoint) }
}

/// Paper geometry in sheet space: millimeters, top-left origin, orientation applied.
struct SheetGeometry: Sendable {
    let paperSize: CGSize
    /// Area the printer can reach.
    let printable: CGRect
    let orientation: Orientation

    init(pageSize: PPDFile.PageSize, orientation: Orientation) {
        self.orientation = orientation
        let w = Units.mm(pageSize.size.width)
        let h = Units.mm(pageSize.size.height)
        // PPD imageable area is bottom-left based; flip to top-left.
        let area = pageSize.imageableArea
        let portrait = CGRect(
            x: Units.mm(area.minX),
            y: h - Units.mm(area.maxY),
            width: Units.mm(area.width),
            height: Units.mm(area.height)
        )
        if orientation == .portrait {
            paperSize = CGSize(width: w, height: h)
            printable = portrait
        } else {
            // Landscape = portrait page turned 90° counter-clockwise.
            paperSize = CGSize(width: h, height: w)
            printable = CGRect(x: portrait.minY, y: w - portrait.maxX, width: portrait.height, height: portrait.width)
        }
    }

    /// Content area: user margins, but never outside the printable area.
    func contentRect(margins: EdgeInsetsMM) -> CGRect {
        let wanted = CGRect(
            x: margins.left, y: margins.top,
            width: paperSize.width - margins.left - margins.right,
            height: paperSize.height - margins.top - margins.bottom
        )
        let clipped = wanted.intersection(printable)
        return clipped.isNull ? printable : clipped
    }
}

enum LayoutEngine {
    /// Cell frames for a template. `imageCount` sizes the contact sheet.
    static func frames(spec: LayoutSpec, content: CGRect, imageCount: Int) -> [CGRect] {
        switch spec.template {
        case .single:
            return [content]
        case .grid:
            return grid(rows: spec.rows, columns: spec.columns, spec: spec, content: content)
        case .contactSheet:
            let columns = max(1, spec.columns)
            let rows = max(1, Int((Double(max(imageCount, 1)) / Double(columns)).rounded(.up)))
            return grid(rows: rows, columns: columns, spec: spec, content: content)
        }
    }

    private static func grid(rows: Int, columns: Int, spec: LayoutSpec, content: CGRect) -> [CGRect] {
        let rows = max(1, rows)
        let columns = max(1, columns)
        let gap = spec.gapMM
        let caption = spec.captions ? spec.captionHeightMM : 0
        let cellW = (content.width - gap * Double(columns - 1)) / Double(columns)
        let slotH = (content.height - gap * Double(rows - 1)) / Double(rows)
        let cellH = slotH - caption
        guard cellW > 0, cellH > 0 else { return [] }
        var frames: [CGRect] = []
        for r in 0..<rows {
            for c in 0..<columns {
                frames.append(CGRect(
                    x: content.minX + Double(c) * (cellW + gap),
                    y: content.minY + Double(r) * (slotH + gap),
                    width: cellW, height: cellH
                ))
            }
        }
        return frames
    }

    /// Rebuilds the cells of a sheet, keeping image assignments in order.
    static func relayout(_ sheet: inout Sheet, geometry: SheetGeometry, imageIDs: [UUID]) {
        let content = geometry.contentRect(margins: sheet.layout.margins)
        let assigned = sheet.cells.compactMap(\.imageID)
        let ids = sheet.layout.template == .contactSheet ? imageIDs : assigned
        let frames = frames(spec: sheet.layout, content: content, imageCount: ids.count)
        var cells: [Cell] = []
        for (i, frame) in frames.enumerated() {
            var cell = i < sheet.cells.count ? sheet.cells[i] : Cell(frame: frame)
            cell.frame = frame
            cell.imageID = i < ids.count ? ids[i] : nil
            cells.append(cell)
        }
        sheet.cells = cells
    }
}
