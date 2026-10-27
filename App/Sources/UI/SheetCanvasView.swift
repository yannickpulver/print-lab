import SwiftUI
import UniformTypeIdentifiers

/// The sheet as it will print: paper, margins, cells and softproofed images.
struct SheetCanvasView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GeometryReader { proxy in
            if let geometry = model.geometry {
                let padding: CGFloat = 48
                let paper = geometry.paperSize
                let scale = max(0.1, min(
                    (proxy.size.width - padding * 2) / paper.width,
                    (proxy.size.height - padding * 2) / paper.height
                ))
                SheetView(geometry: geometry, scale: scale)
                    .frame(width: paper.width * scale, height: paper.height * scale)
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            } else {
                ContentUnavailableView {
                    Label { Text("No Canon Printer") } icon: { TablerIcon("printer", size: 40) }
                } description: {
                    Text("Add your Canon printer with Canon's driver in System Settings → Printers & Scanners.")
                }
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .overlay(alignment: .bottom) {
            if model.geometry != nil, model.sheet.pageCount > 1 {
                PageBar()
            }
        }
        .overlay(alignment: .top) {
            if let alert = model.printerAlert {
                PrinterAlertBanner(alert: alert)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.default, value: model.printerAlert)
        .contentShape(Rectangle())
        .onTapGesture { model.selectedCellID = nil }
    }
}

/// Pages of the print job: one sheet of paper each.
private struct PageBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Button { model.showPage(model.currentPage - 1) } label: { TablerIcon("chevron-left") }
                .disabled(model.currentPage == 0)
                .help("Previous page")
            Text("Page \(model.currentPage + 1) of \(model.sheet.pageCount)")
                .monospacedDigit()
            Button { model.showPage(model.currentPage + 1) } label: { TablerIcon("chevron-right") }
                .disabled(model.currentPage >= model.sheet.pageCount - 1)
                .help("Next page")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .padding(.bottom, 8)
    }
}

private struct SheetView: View {
    @Environment(AppModel.self) private var model
    let geometry: SheetGeometry
    let scale: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                context.withCGContext { cg in
                    cg.scaleBy(x: scale, y: scale)
                    drawGuides(cg)
                    SheetRenderer.drawCells(
                        model.sheet, page: model.currentPage, images: model.displayImages,
                        captions: Dictionary(uniqueKeysWithValues: model.library.map { ($0.id, $0.name) }),
                        in: cg
                    )
                }
            }
            ForEach(model.sheet.cells(onPage: model.currentPage)) { cell in
                CellOverlay(cell: cell, scale: scale)
                    .frame(width: cell.frame.width * scale, height: cell.frame.height * scale)
                    .offset(x: cell.frame.minX * scale, y: cell.frame.minY * scale)
            }
        }
        .background(Color(cgColor: model.paperColor ?? CGColor(gray: 1, alpha: 1)))
        .compositingGroup()
        .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
    }

    /// Printable area and margins as thin guides. They do not print.
    private func drawGuides(_ cg: CGContext) {
        let content = geometry.contentRect(margins: model.sheet.layout.margins)
        cg.setLineWidth(0.6 / scale)
        cg.setStrokeColor(CGColor(gray: 0.5, alpha: 0.5))
        cg.setLineDash(phase: 0, lengths: [4 / scale, 3 / scale])
        cg.stroke(content)
        if geometry.printable != content {
            cg.setStrokeColor(CGColor(red: 0.9, green: 0.4, blue: 0.2, alpha: 0.35))
            cg.setLineDash(phase: 0, lengths: [1 / scale, 3 / scale])
            cg.stroke(geometry.printable)
        }
        cg.setLineDash(phase: 0, lengths: [])
    }
}

/// Hit area of one cell: select, drop an image, drag to move the crop.
private struct CellOverlay: View {
    @Environment(AppModel.self) private var model
    let cell: Cell
    let scale: CGFloat

    @State private var dragStart: CGPoint?
    @State private var isTargeted = false

    var body: some View {
        let selected = model.selectedCellID == cell.id
        ZStack {
            if cell.imageID == nil {
                // Fixed tones: the paper stays light in dark mode.
                Rectangle()
                    .fill(Color.black.opacity(isTargeted ? 0.12 : 0.04))
                TablerIcon("photo-plus", size: min(28, cell.frame.width * scale / 4))
                    .foregroundStyle(Color.black.opacity(0.25))
            } else if isTargeted {
                Rectangle().fill(Color.accentColor.opacity(0.2))
            }
            Rectangle()
                .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.selectedCellID = cell.id }
        .gesture(cropDrag)
        .onDrop(of: ImageDrop.types, isTargeted: $isTargeted) { providers in
            ImageDrop.handle(providers, model: model, cell: cell.id)
        }
        .help(cell.fit == .fill && cell.imageID != nil ? "Drag to move the crop" : "")
    }

    /// Moving the mouse right shows more of the image's left side, like sliding a print under a mat.
    private var cropDrag: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard cell.fit == .fill, let size = model.item(cell.imageID)?.pixelSize else { return }
                model.selectedCellID = cell.id
                let start = dragStart ?? cell.cropOffset
                if dragStart == nil { dragStart = start }
                let rect = SheetRenderer.imageRect(imageSize: size, cell: Cell(frame: cell.frame, fit: .fill,
                                                                               quarterTurns: cell.quarterTurns))
                let extraX = rect.width - cell.frame.width
                let extraY = rect.height - cell.frame.height
                let dx = extraX > 0 ? -2 * (value.translation.width / scale) / extraX : 0
                let dy = extraY > 0 ? -2 * (value.translation.height / scale) / extraY : 0
                model.updateCell(cell.id) {
                    $0.cropOffset = CGPoint(x: min(1, max(-1, start.x + dx)), y: min(1, max(-1, start.y + dy)))
                }
            }
            .onEnded { _ in dragStart = nil }
    }
}

/// Drops of files from Finder, or of an image from the list (its id as text).
@MainActor
enum ImageDrop {
    /// For cells. Elsewhere only files drop.
    static let types: [UTType] = [.fileURL, .plainText]

    /// Files get added, the first one into `cell`. A list image goes into `cell`.
    static func handle(_ providers: [NSItemProvider], model: AppModel, cell: UUID? = nil) -> Bool {
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        if !files.isEmpty {
            Task {
                var urls: [URL] = []
                for provider in files {
                    if let url = await load(URL.self, from: provider) { urls.append(url) }
                }
                model.addImages(urls.filter(\.isFileURL), into: cell)
            }
            return true
        }
        guard let cell, let provider = providers.first else { return false }
        Task {
            if let text = await load(String.self, from: provider), let id = UUID(uuidString: text) {
                model.place(id, inCell: cell)
            }
        }
        return true
    }

    private static func load<T: Transferable & Sendable>(_ type: T.Type, from provider: NSItemProvider) async -> T? {
        await withCheckedContinuation { continuation in
            _ = provider.loadTransferable(type: type) { continuation.resume(returning: try? $0.get()) }
        }
    }
}
