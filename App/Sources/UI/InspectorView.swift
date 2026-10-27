import SwiftUI

struct InspectorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                if model.driver != nil { PresetCard() }
                PrinterCard()
                if model.driver != nil {
                    PaperCard()
                    LayoutCard()
                    if model.selectedCell != nil { ImageCard() }
                    ColorCard()
                    PrintCard()
                }
            }
            .padding(16)
        }
    }
}

// MARK: - Building blocks

/// Tabler icon from the asset catalog, tinted like text.
struct TablerIcon: View {
    let name: String
    var size: CGFloat = 16

    init(_ name: String, size: CGFloat = 16) {
        self.name = name
        self.size = size
    }

    var body: some View {
        Image("ti-\(name)")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
    }
}

/// A titled group: icon and title above a rounded panel.
private struct Card<Content: View, Accessory: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                TablerIcon(icon)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.headline)
                Spacer()
                accessory
            }
            .padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

extension Card where Accessory == EmptyView {
    init(title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.init(title: title, icon: icon, accessory: { EmptyView() }, content: content)
    }
}

/// Label in a fixed column on the left, control on the right. Pickers fill the rest of the row,
/// so all controls in a card start and end at the same edges.
private struct Row<Control: View>: View {
    let label: String
    var labelWidth: CGFloat? = 92
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: labelWidth, alignment: .leading)
                .fixedSize(horizontal: labelWidth == nil, vertical: false)
            Spacer(minLength: 0)
            control
        }
        .frame(minHeight: 22)
    }
}

/// Label above a control that needs the full width, e.g. long media and profile names.
private struct StackedRow<Accessory: View, Control: View>: View {
    let label: String
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var control: Control

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label).foregroundStyle(.secondary)
                Spacer()
                accessory
            }
            control
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension StackedRow where Accessory == EmptyView {
    init(label: String, @ViewBuilder control: () -> Control) {
        self.init(label: label, accessory: { EmptyView() }, control: control)
    }
}

private struct SwitchRow: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Row(label: label, labelWidth: nil) {
            Toggle(label, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

/// A hint below a control: small, with an icon.
private struct Hint: View {
    let icon: String
    let text: String
    var tint: Color = .secondary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            TablerIcon(icon, size: 13)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
        .foregroundStyle(tint)
    }
}

struct MillimeterField: View {
    let title: String
    @Binding var value: Double
    var showsUnit = true

    var body: some View {
        HStack(spacing: 4) {
            TextField(title, value: $value, format: .number.precision(.fractionLength(0...1)))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder)
                .frame(width: 56)
            if showsUnit { Text("mm").foregroundStyle(.secondary) }
        }
        .fixedSize()
    }
}

// MARK: - Printer

private struct PrinterCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Card(title: "Printer", icon: "printer") {
            Picker("Printer", selection: $model.queue) {
                ForEach(model.queues) { queue in
                    Text(queue.info).tag(Optional(queue))
                }
            }
            .labelsHidden()
            HStack(spacing: 6) {
                PrinterStatusBadge()
                Spacer(minLength: 8)
                if let queue = model.queue {
                    TablerIcon("wifi", size: 13)
                    Text(queue.host ?? "USB")
                    if let connection = model.connection {
                        Text("· \(connection.label)")
                            .foregroundStyle(connection.rating == .good ? Color.secondary : connection.tint)
                            .help(connection.details)
                    }
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            // The badge already names the alert.
            if let alert = model.printerAlert {
                Hint(icon: "alert-triangle", text: alert.message, tint: alert.severity == .error ? .red : .orange)
            }
            ForEach(model.status.reasons.compactMap(Self.describe), id: \.self) { reason in
                Hint(icon: "alert-triangle", text: reason, tint: .orange)
            }
            if let connection = model.connection, connection.rating != .good {
                ConnectionHint(connection: connection)
            }
            if !model.status.markers.isEmpty {
                InkLevels(markers: model.status.markers)
                    .padding(.top, 4)
            }
        }
    }

    /// Readable text for IPP printer-state-reasons. Normal reasons return nil.
    static func describe(_ reason: String) -> String? {
        let known: [String: String] = [
            "marker-waste-almost-full": "Maintenance cartridge almost full",
            "marker-waste-full": "Maintenance cartridge full",
            "marker-supply-low": "Ink low",
            "marker-supply-empty": "Ink empty",
            "media-empty": "Out of paper",
            "media-needed": "Load paper",
            "media-jam": "Paper jam",
            "cover-open": "Cover open",
            "door-open": "Door open",
            "offline": "Printer offline",
            "paused": "Printer paused",
        ]
        let base = reason.replacingOccurrences(of: "-warning", with: "")
            .replacingOccurrences(of: "-error", with: "")
            .replacingOccurrences(of: "-report", with: "")
        if reason.hasSuffix("-report") || ["spool-area-full", "other"].contains(base) { return nil }
        return known[base] ?? base.replacingOccurrences(of: "-", with: " ").capitalized
    }
}

/// Why the link to the printer is weak and what helps.
private struct ConnectionHint: View {
    let connection: ConnectionQuality

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Hint(icon: "wifi",
                 text: "\(connection.label) connection, prints can take much longer: "
                    + connection.causes.joined(separator: ", ") + ".",
                 tint: connection.tint)
            ForEach(connection.fixes, id: \.self) { fix in
                Text("• " + fix)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 19)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .help(connection.details)
    }
}

private extension ConnectionQuality {
    var tint: Color { rating == .poor ? .red : .orange }
}

/// Dot and one word or line about the printer or the running job.
private struct PrinterStatusBadge: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .help(model.queue?.deviceURI ?? "")
    }

    private var text: String {
        if let alert = model.printerAlert { return alert.title }
        if model.isPreparingJob { return "Preparing print…" }
        if let job = model.job, job.state != .completed { return job.state.label }
        guard model.queue != nil else { return "No Canon printer" }
        return model.status.state.label
    }

    private var color: Color {
        if let alert = model.printerAlert { return alert.severity == .error ? .red : .orange }
        return switch model.status.state {
        case .idle: .green
        case .processing: .blue
        case .stopped: .orange
        case .unknown: .gray
        }
    }
}

private struct InkLevels: View {
    let markers: [PrinterStatus.Marker]

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(markers) { marker in
                VStack(spacing: 4) {
                    GeometryReader { proxy in
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.15))
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color(hex: marker.color) ?? .secondary)
                                .frame(height: proxy.size.height * CGFloat(marker.level ?? 0) / 100)
                        }
                    }
                    .frame(height: 40)
                    Text(marker.name)
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
                .help("\(marker.name): \(marker.level.map { "\($0) %" } ?? "unknown")")
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

// MARK: - Paper

/// Everything about the sheet in the printer: size, media type, feed and the profile measured for that media.
private struct PaperCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        if let driver = model.driver {
            Card(title: "Paper", icon: "file-description") {
                PaperPicker()

                Divider()

                Row(label: "Size") {
                    Picker("Size", selection: $model.sheet.print.paperID) {
                        ForEach(driver.papers) { paper in
                            Text(paper.label).tag(paper.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                Row(label: "Orientation") {
                    Picker("Orientation", selection: $model.sheet.orientation) {
                        Text("Portrait").tag(Orientation.portrait)
                        Text("Landscape").tag(Orientation.landscape)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }

                Divider()

                Row(label: "Media", labelWidth: nil) {
                    Picker("Media type", selection: $model.sheet.print.mediaTypeID) {
                        ForEach(driver.mediaSections, id: \.title) { section in
                            Section(section.title) {
                                ForEach(section.media) { media in
                                    // "Highest Density Fine Art Paper" fits on one line as "… Fine Art".
                                    Text(media.name.replacingOccurrences(of: " Fine Art Paper", with: " Fine Art")).tag(media.id)
                                }
                            }
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                if !driver.paperSources.isEmpty {
                    Row(label: "Feed") {
                        Picker("Feed", selection: $model.sheet.print.paperSourceID) {
                            ForEach(driver.paperSources) { source in
                                Text(source.name).tag(Optional(source.id))
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                ForEach(model.conflicts, id: \.self) { conflict in
                    Hint(icon: "alert-triangle", text: conflict, tint: .orange)
                }
                if let profile = model.paperProfile,
                   let expected = driver.mediaType(forProfileNamed: profile.fileName),
                   expected.id != model.sheet.print.mediaTypeID {
                    HStack(alignment: .firstTextBaseline) {
                        Hint(icon: "alert-triangle", text: "This profile was made for \(expected.name).", tint: .orange)
                        Spacer(minLength: 8)
                        Button("Use it") { model.sheet.print.mediaTypeID = expected.id }
                            .buttonStyle(.link)
                            .font(.callout)
                    }
                }
            }
        }
    }
}

// MARK: - Layout

private struct LayoutCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Card(title: "Layout", icon: "layout-grid") {
            Row(label: "Template") {
                Picker("Template", selection: $model.sheet.layout.template) {
                    ForEach(Template.allCases, id: \.self) { template in
                        Text(template.label).tag(template)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            if model.sheet.layout.template == .grid {
                Row(label: "Rows") {
                    Stepper("\(model.sheet.layout.rows)", value: $model.sheet.layout.rows, in: 1...12)
                }
            }
            if model.sheet.layout.template != .single {
                Row(label: "Columns") {
                    Stepper("\(model.sheet.layout.columns)", value: $model.sheet.layout.columns, in: 1...12)
                }
                Row(label: "Gap") {
                    MillimeterField(title: "Gap", value: $model.sheet.layout.gapMM)
                }
            }

            Divider()

            MarginsEditor(margins: $model.sheet.layout.margins,
                          paperSize: model.geometry?.paperSize ?? CGSize(width: 210, height: 297),
                          artMargins: model.marginPlan?.artMargins)
            ForEach(model.marginPlan?.notes ?? [], id: \.self) { note in
                Hint(icon: "info-circle", text: note)
            }

            Divider()

            SwitchRow(label: "Captions", isOn: $model.sheet.layout.captions)
            SwitchRow(label: "Rotate to fit cells", isOn: $model.sheet.layout.autoRotate)
        }
    }
}

private struct MarginsEditor: View {
    @Binding var margins: EdgeInsetsMM
    let paperSize: CGSize
    /// Set when the margins go below Canon's fine art margin.
    let artMargins: EdgeInsetsMM?
    @State private var individual = false

    var body: some View {
        Row(label: "Margins") {
            if !individual {
                MillimeterField(title: "Margins", value: Binding(
                    get: { margins.top },
                    set: { margins = .all($0) }
                ))
            }
            Button(individual ? "All sides" : "Per side") {
                if individual { margins = .all(margins.top) }
                individual.toggle()
            }
            .buttonStyle(.link)
            .font(.callout)
            .help(individual ? "Same margin on all sides" : "Set each side separately")
        }
        .onAppear {
            individual = !(margins.top == margins.left && margins.left == margins.bottom
                && margins.bottom == margins.right)
        }
        if individual {
            // Each field sits at the side of the page it sets.
            Grid(horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    MillimeterField(title: "Top", value: $margins.top, showsUnit: false)
                }
                GridRow {
                    MillimeterField(title: "Left", value: $margins.left, showsUnit: false)
                    MarginsDiagram(paperSize: paperSize, margins: margins, artMargins: artMargins)
                    MillimeterField(title: "Right", value: $margins.right, showsUnit: false)
                }
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    MillimeterField(title: "Bottom", value: $margins.bottom, showsUnit: false)
                }
            }
            .frame(maxWidth: .infinity)
        } else if artMargins != nil {
            MarginsDiagram(paperSize: paperSize, margins: margins, artMargins: artMargins)
                .frame(maxWidth: .infinity)
        }
        if artMargins != nil {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(MarginsDiagram.artMarginColor)
                    .frame(width: 10, height: 10)
                Text("Fine art margin: may leave marks")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
        }
    }
}

/// The page with its content area inset by the margins, to scale. Thin margins stay visible.
/// Sides closer to the edge than Canon's fine art margin show that margin in orange.
private struct MarginsDiagram: View {
    static let artMarginColor = Color.orange.opacity(0.7)

    let paperSize: CGSize
    let margins: EdgeInsetsMM
    let artMargins: EdgeInsetsMM?
    var height: CGFloat = 72

    var body: some View {
        let scale = height / max(paperSize.width, paperSize.height)
        let size = CGSize(width: (paperSize.width * scale).rounded(), height: (paperSize.height * scale).rounded())
        let top = max(margins.top * scale, 2), left = max(margins.left * scale, 2)
        let bottom = max(margins.bottom * scale, 2), right = max(margins.right * scale, 2)
        let content = CGRect(x: left, y: top, width: max(size.width - left - right, 0),
                             height: max(size.height - top - bottom, 0))
        Canvas { context, size in
            let paper = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 1.5)
            context.fill(paper, with: .color(.white))
            context.fill(Path(content), with: .color(Color(white: 0.55)))
            if let art = artMargins {
                let e = 0.05
                if margins.top < art.top - e {
                    context.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: art.top * scale)),
                                 with: .color(Self.artMarginColor))
                }
                if margins.bottom < art.bottom - e {
                    let h = art.bottom * scale
                    context.fill(Path(CGRect(x: 0, y: size.height - h, width: size.width, height: h)),
                                 with: .color(Self.artMarginColor))
                }
                if margins.left < art.left - e {
                    context.fill(Path(CGRect(x: 0, y: 0, width: art.left * scale, height: size.height)),
                                 with: .color(Self.artMarginColor))
                }
                if margins.right < art.right - e {
                    let w = art.right * scale
                    context.fill(Path(CGRect(x: size.width - w, y: 0, width: w, height: size.height)),
                                 with: .color(Self.artMarginColor))
                }
            }
            context.stroke(paper, with: .color(.black.opacity(0.2)), lineWidth: 0.5)
        }
        .overlay(alignment: .topLeading) {
            Text("mm")
                .font(.caption2)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .foregroundStyle(.white)
                .frame(width: content.width, height: content.height)
                .offset(x: content.minX, y: content.minY)
        }
        .frame(width: size.width, height: size.height)
        .frame(width: height, height: height)
    }
}

// MARK: - Selected image

private struct ImageCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let cell = model.selectedCell {
            Card(title: "Image", icon: "photo") {
                if let item = model.item(cell.imageID) {
                    Text(item.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 6) {
                        Text(printSize(cell))
                        Text("·")
                        Text(resolution(cell, item: item))
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    Row(label: "Fit") {
                        Picker("Fit", selection: Binding(
                            get: { cell.fit },
                            set: { fit in model.updateCell(cell.id) { $0.fit = fit; $0.cropOffset = .zero } }
                        )) {
                            Text("Fill").tag(Fit.fill)
                            Text("Fit").tag(Fit.fit)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    HStack(spacing: 14) {
                        Button { model.updateCell(cell.id) { $0.quarterTurns -= 1 } } label: { TablerIcon("rotate") }
                            .help("Rotate left")
                        Button { model.updateCell(cell.id) { $0.quarterTurns += 1 } } label: { TablerIcon("rotate-clockwise") }
                            .help("Rotate right")
                        Button { model.updateCell(cell.id) { $0.cropOffset = .zero } } label: { TablerIcon("focus-centered") }
                            .help("Center the crop")
                            .disabled(cell.cropOffset == .zero)
                        Spacer()
                        Button { model.clearCell(cell.id) } label: { TablerIcon("trash") }
                            .help("Remove the image from this cell")
                    }
                    .buttonStyle(.borderless)
                } else {
                    Hint(icon: "photo-plus", text: "Drop an image from the list onto this cell, or double-click an image.")
                }
            }
        }
    }

    private func printSize(_ cell: Cell) -> String {
        String(format: "%.1f × %.1f cm", cell.frame.width / 10, cell.frame.height / 10)
    }

    /// Effective pixels per inch on paper. Below 240 ppi prints can look soft.
    private func resolution(_ cell: Cell, item: LibraryItem) -> String {
        let rect = SheetRenderer.imageRect(imageSize: item.pixelSize, cell: cell)
        let longSidePixels = max(item.pixelSize.width, item.pixelSize.height)
        let ppi = longSidePixels / (max(rect.width, rect.height) / 25.4)
        return "\(Int(ppi.rounded())) ppi" + (ppi < 240 ? " (low)" : "")
    }
}

// MARK: - Color

private struct ColorCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Card(title: "Color", icon: "palette") {
            Row(label: "Intent") {
                Picker("Intent", selection: $model.color.intent) {
                    ForEach(RenderingIntent.allCases, id: \.self) { intent in
                        Text(intent.label).tag(intent)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            SwitchRow(label: "Black point compensation", isOn: $model.color.blackPointCompensation)

            Divider()

            SwitchRow(label: "Softproof", isOn: $model.softproof)
            SwitchRow(label: "Simulate paper white", isOn: $model.simulatePaperWhite)
                .disabled(!model.softproof)
        }
    }
}

/// The paper in the printer: a paper maker's profile or a Canon paper. Picking one sets the profile
/// and the media type it was made for. Two lines like the preset menu: readable name, then the file.
private struct PaperPicker: View {
    @Environment(AppModel.self) private var model
    @State private var installed = ProfileLibrary.printerProfiles()
    @State private var choosingFile = false

    var body: some View {
        let driver = model.driver
        let custom = model.sheet.print.customProfilePath
        let active = model.paperProfile
        let forPrinter = installed.filter { driver?.isForThisPrinter(profileNamed: $0.fileName) ?? true }
        let others = installed.filter { !forPrinter.contains($0) }
        StackedRow(label: "Paper") {
            Button("Choose File…") { choosingFile = true }
                .buttonStyle(.link)
                .font(.callout)
        } control: {
            Menu {
                ForEach(forPrinter, id: \.url) { profile in
                    item(profile.fileName, path: profile.url.path)
                }
                if let custom, !installed.contains(where: { $0.url.path == custom }) {
                    item(URL(fileURLWithPath: custom).lastPathComponent, path: custom)
                }
                Divider()
                Section("Canon") {
                    ForEach(driver?.mediaTypes.filter { $0.profile != nil } ?? []) { media in
                        canonItem(media)
                    }
                }
                if !others.isEmpty {
                    Divider()
                    Menu("Other Printers") {
                        ForEach(others, id: \.url) { profile in
                            item(profile.fileName, path: profile.url.path)
                        }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.paperName ?? "No profile")
                        Text(active?.fileName ?? "")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .truncationMode(.middle)
                    }
                    .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .focusEffectDisabled()
            .frame(maxWidth: .infinity)
        }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.init(filenameExtension: "icc")!,
                                                                        .init(filenameExtension: "icm")!]) { result in
            if case .success(let url) = result { model.choosePaper(profileAt: url.path) }
        }
        .onAppear { installed = ProfileLibrary.printerProfiles() }
    }

    /// Paper maker's profile: readable name with the file name below, checked when active.
    private func item(_ fileName: String, path: String) -> some View {
        Toggle(isOn: Binding(
            get: { model.sheet.print.customProfilePath == path },
            set: { if $0 { model.choosePaper(profileAt: path) } }
        )) {
            Text(CanonDriver.displayName(forProfileNamed: fileName))
            Text(fileName)
        }
    }

    /// Canon paper: the media type with Canon's profile, checked when active.
    private func canonItem(_ media: CanonDriver.MediaType) -> some View {
        Toggle(isOn: Binding(
            get: { model.sheet.print.customProfilePath == nil && model.sheet.print.mediaTypeID == media.id },
            set: { if $0 { model.choosePaper(canonMedia: media.id) } }
        )) {
            Text(media.name)
            Text(media.profile?.fileName ?? "")
        }
    }
}

// MARK: - Print

private struct PrintCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        if let driver = model.driver {
            Card(title: "Print", icon: "send") {
                Row(label: "Quality") {
                    Picker("Quality", selection: $model.sheet.print.qualityID) {
                        ForEach(driver.qualities) { quality in
                            Text(quality.name).tag(quality.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                if !driver.dryingTimes.isEmpty {
                    Row(label: "Drying time") {
                        Picker("Drying time", selection: $model.sheet.print.dryingTimeID) {
                            ForEach(driver.dryingTimes) { time in
                                Text(time.name).tag(Optional(time.id))
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                if model.isPreparingJob {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Preparing…").foregroundStyle(.secondary)
                    }
                } else if let job = model.job {
                    HStack(spacing: 4) {
                        Group {
                            Text(job.state.label)
                            // Running time while the job is open, total time when it is done.
                            if let finished = job.finished {
                                Text("· " + Duration.seconds(finished.timeIntervalSince(job.started))
                                    .formatted(.units(allowed: [.hours, .minutes, .seconds], maximumUnitCount: 2)))
                            } else {
                                Text("· \(Text(job.started, style: .timer))").monospacedDigit()
                            }
                        }
                        .foregroundStyle(.secondary)
                        Spacer()
                        if !job.state.isFinal {
                            Button("Cancel Job", role: .destructive) { model.cancelJob() }
                                .buttonStyle(.link)
                        }
                    }
                    .font(.callout)
                }
                Button {
                    model.requestPrint()
                } label: {
                    Label { Text("Print…") } icon: { TablerIcon("printer") }
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!model.canPrint)
                .padding(.top, 4)
            }
        }
    }
}

// MARK: - Presets

/// Dropdown on top: shows the preset the settings match, applies, saves and deletes presets.
private struct PresetCard: View {
    @Environment(AppModel.self) private var model
    @State private var naming = false
    @State private var newName = ""

    var body: some View {
        let active = model.activePreset
        Card(title: "Preset", icon: "bookmark") {
            HStack(spacing: 10) {
                Menu {
                    Picker("Preset", selection: Binding(
                        get: { active?.id },
                        set: { id in if let preset = model.presets.first(where: { $0.id == id }) { model.apply(preset) } }
                    )) {
                        ForEach(model.presets) { preset in
                            Label {
                                Text(preset.name)
                                Text(summary(preset.print))
                            } icon: {
                                thumbnail(preset.print, preset.layout, preset.orientation, height: 28)
                            }
                            .tag(Optional(preset.id))
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    HStack(spacing: 10) {
                        thumbnail(model.sheet.print, model.sheet.layout, model.sheet.orientation, height: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(active?.name ?? "Custom settings")
                                .fontWeight(.medium)
                            Text(summary(model.sheet.print))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .disabled(model.presets.isEmpty)
                .frame(maxWidth: .infinity)
                Button {
                    newName = ""
                    naming = true
                } label: { TablerIcon("plus", size: 15) }
                    .buttonStyle(.borderless)
                    .help("Save the current settings as a new preset")
                Button {
                    model.presets.removeAll { $0.id == active?.id }
                } label: { TablerIcon("trash", size: 15) }
                    .buttonStyle(.borderless)
                    .disabled(active == nil)
                    .help(active.map { "Delete \($0.name)" } ?? "Choose a preset to delete it")
            }
            // The first control in the window gets focus at launch; no ring on this card.
            .focusEffectDisabled()
        }
        .alert("Save Preset", isPresented: $naming) {
            TextField("Name", text: $newName)
            Button("Save") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { model.savePreset(named: name) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves paper, media, profile, layout and color settings. Images are not part of a preset.")
        }
    }

    /// "A3 · Baryta Photographic"
    private func summary(_ print: PrintSettings) -> String {
        let paper = model.driver?.paper(print.paperID)?.label ?? print.paperID
        let media = model.driver?.mediaType(print.mediaTypeID)?.name ?? print.mediaTypeID
        return "\(paper) · \(media)"
    }

    /// Menus only show images, so the thumbnail gets rendered once per item.
    private func thumbnail(_ print: PrintSettings, _ layout: LayoutSpec, _ orientation: Orientation,
                           height: CGFloat) -> Image {
        let size = model.driver?.paper(print.paperID)?.size ?? CGSize(width: 595, height: 842)
        let paper = CGSize(width: Units.mm(size.width), height: Units.mm(size.height))
        let view = SheetThumbnail(
            paperSize: orientation == .portrait ? paper : CGSize(width: paper.height, height: paper.width),
            layout: layout,
            fineArt: model.driver?.isFineArt(print.mediaTypeID) ?? false,
            height: height
        )
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return renderer.nsImage.map { Image(nsImage: $0) } ?? Image(systemName: "doc")
    }
}

/// A tiny sheet: paper shape, margins and cells, in a square so text next to it lines up.
/// Fine art paper is warm white.
private struct SheetThumbnail: View {
    let paperSize: CGSize
    let layout: LayoutSpec
    let fineArt: Bool
    let height: CGFloat

    var body: some View {
        let scale = height / max(paperSize.width, paperSize.height)
        let m = layout.margins
        let content = CGRect(x: m.left, y: m.top, width: paperSize.width - m.left - m.right,
                             height: paperSize.height - m.top - m.bottom)
        let cells = LayoutEngine.frames(spec: layout, content: content, imageCount: layout.columns * layout.columns)
        Canvas { context, size in
            let paper = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 1.5)
            context.fill(paper, with: .color(fineArt ? Color(red: 0.96, green: 0.94, blue: 0.88) : .white))
            for cell in cells {
                let rect = CGRect(x: cell.minX * scale, y: cell.minY * scale,
                                  width: cell.width * scale, height: cell.height * scale)
                context.fill(Path(rect), with: .color(Color(white: 0.55)))
            }
            context.stroke(paper, with: .color(.black.opacity(0.2)), lineWidth: 0.5)
        }
        .frame(width: (paperSize.width * scale).rounded(), height: (paperSize.height * scale).rounded())
        .frame(width: height + 2, height: height + 2)
    }
}

extension Color {
    /// "#RRGGBB" as sent by printers in `marker-colors`.
    init?(hex: String?) {
        guard let hex, hex.hasPrefix("#"), hex.count >= 7, let value = UInt32(hex.dropFirst().prefix(6), radix: 16) else {
            return nil
        }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
