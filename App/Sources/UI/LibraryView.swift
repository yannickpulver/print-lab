import SwiftUI

struct LibraryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            ForEach(model.library) { item in
                LibraryRow(item: item, isPlaced: model.sheet.cells.contains { $0.imageID == item.id })
                    .draggable(item.id.uuidString)
                    .onTapGesture(count: 2) { model.placeInNextCell(item.id) }
                    .contextMenu {
                        Button("Place on Sheet") { model.placeInNextCell(item.id) }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                        Divider()
                        Button("Remove", role: .destructive) { model.removeFromLibrary(item.id) }
                    }
            }
        }
        .overlay {
            if model.library.isEmpty {
                ContentUnavailableView {
                    Label { Text("No Images") } icon: { TablerIcon("photo", size: 40) }
                } description: {
                    Text("Drop images here or press ⌘O.")
                } actions: {
                    Button("Add Images…") { model.showImporter = true }
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.addImages(urls)
            return true
        }
        .toolbar {
            ToolbarItem {
                Button {
                    model.showImporter = true
                } label: {
                    Label { Text("Add Images") } icon: { TablerIcon("photo-plus", size: 18) }
                }
            }
        }
        .navigationTitle("Images")
    }
}

private struct LibraryRow: View {
    let item: LibraryItem
    let isPlaced: Bool

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let thumbnail = item.thumbnail {
                    Image(decorative: thumbnail, scale: 1)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color.secondary.opacity(0.2)
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(Int(item.pixelSize.width)) × \(Int(item.pixelSize.height)) px")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if isPlaced {
                TablerIcon("circle-check", size: 15)
                    .foregroundStyle(.secondary)
                    .help("On the sheet")
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}
