import CoreGraphics
import CoreText
import Foundation

/// Draws a sheet. Preview and PDF share this code, so the screen shows what gets printed.
/// All drawing happens in sheet space: millimeters, top-left origin, y pointing down.
enum SheetRenderer {
    static let captionFontSizeMM = 2.6

    /// Draws the cells of one page. `images` maps image ids to the pixels to draw (proofed or print-ready).
    static func drawCells(
        _ sheet: Sheet, page: Int, images: [UUID: CGImage], captions: [UUID: String], in ctx: CGContext
    ) {
        for cell in sheet.cells(onPage: page) {
            guard let id = cell.imageID, let image = images[id] else { continue }
            drawImage(image, in: cell, ctx: ctx)
            if sheet.layout.captions, let caption = captions[id] {
                drawCaption(caption, below: cell.frame, ctx: ctx)
            }
        }
    }

    /// Rect of the rotated image inside a cell, in sheet space, before clipping.
    static func imageRect(imageSize: CGSize, cell: Cell) -> CGRect {
        let frame = cell.frame
        let turns = ((cell.quarterTurns % 4) + 4) % 4
        let aspect = turns % 2 == 0 ? imageSize.width / imageSize.height : imageSize.height / imageSize.width
        let cellAspect = frame.width / frame.height
        let size: CGSize
        switch cell.fit {
        case .fill:
            size = aspect > cellAspect
                ? CGSize(width: frame.height * aspect, height: frame.height)
                : CGSize(width: frame.width, height: frame.width / aspect)
        case .fit:
            size = aspect > cellAspect
                ? CGSize(width: frame.width, height: frame.width / aspect)
                : CGSize(width: frame.height * aspect, height: frame.height)
        }
        let extraX = max(0, size.width - frame.width)
        let extraY = max(0, size.height - frame.height)
        let center = CGPoint(
            x: frame.midX - cell.cropOffset.x * extraX / 2,
            y: frame.midY - cell.cropOffset.y * extraY / 2
        )
        return CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }

    static func drawImage(_ image: CGImage, in cell: Cell, ctx: CGContext) {
        let rect = imageRect(imageSize: CGSize(width: image.width, height: image.height), cell: cell)
        let turns = ((cell.quarterTurns % 4) + 4) % 4
        ctx.saveGState()
        ctx.clip(to: cell.frame)
        ctx.translateBy(x: rect.midX, y: rect.midY)
        ctx.rotate(by: CGFloat(turns) * .pi / 2)
        let w = turns % 2 == 0 ? rect.width : rect.height
        let h = turns % 2 == 0 ? rect.height : rect.width
        // Sheet space points down; images draw bottom-up.
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
        ctx.restoreGState()
    }

    static func drawCaption(_ text: String, below frame: CGRect, ctx: CGContext) {
        let font = CTFontCreateWithName("Helvetica" as CFString, captionFontSizeMM, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        let truncated = width > frame.width
            ? CTLineCreateTruncatedLine(line, frame.width, .middle, nil) ?? line
            : line
        let drawnWidth = min(width, frame.width)
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.translateBy(x: frame.midX - drawnWidth / 2, y: frame.maxY + captionFontSizeMM * 1.3)
        ctx.scaleBy(x: 1, y: -1)
        CTLineDraw(truncated, ctx)
        ctx.restoreGState()
    }

    /// Maps sheet space to PDF page points. The PDF page is always portrait, like the PPD page size.
    static func pageTransform(pageSize: CGSize, orientation: Orientation) -> CGAffineTransform {
        let k = 1 / Units.mmPerPoint
        switch orientation {
        case .portrait:
            return CGAffineTransform(a: k, b: 0, c: 0, d: -k, tx: 0, ty: pageSize.height)
        case .landscape:
            return CGAffineTransform(a: 0, b: -k, c: -k, d: 0, tx: pageSize.width, ty: pageSize.height)
        }
    }

    /// Writes a PDF ready for the Canon driver, one PDF page per sheet with images.
    static func writePDF(
        _ sheet: Sheet, pageSize: CGSize, images: [UUID: CGImage], captions: [UUID: String], to url: URL
    ) throws {
        var box = CGRect(origin: .zero, size: pageSize)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        for page in 0..<sheet.pageCount where sheet.cells(onPage: page).contains(where: { $0.imageID != nil }) {
            ctx.beginPDFPage(nil)
            ctx.concatenate(pageTransform(pageSize: pageSize, orientation: sheet.orientation))
            drawCells(sheet, page: page, images: images, captions: captions, in: ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }
}
