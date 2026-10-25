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
                    MediaCard()
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

    var body: some View {
        HStack(spacing: 4) {
            TextField(title, value: $value, format: .number.precision(.fractionLength(0...1)))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder)
                .frame(width: 56)
            Text("mm").foregroundStyle(.secondary)
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
            if let queue = model.queue {
                HStack(spacing: 6) {
                    TablerIcon("wifi", size: 13)
                    Text(queue.host ?? "USB")
                    if let signal = model.status.remoteUI?.signal {
                        Text("· \(signal) %" + (signal < 50 ? " (weak)" : ""))
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            if let alert = model.printerAlert {
                Hint(icon: "alert-triangle", text: "\(alert.title): \(alert.message)",
                     tint: alert.severity == .error ? .red : .orange)
            }
            ForEach(model.status.reasons.compactMap(Self.describe), id: \.self) { reason in
                Hint(icon: "alert-triangle", text: reason, tint: .orange)
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

private struct PaperCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        if let driver = model.driver {
            Card(title: "Paper", icon: "file-description") {
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
            }
        }
    }
}

// MARK: - Media

/// Media type and profile belong together: the profile is measured for one media type.
private struct MediaCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        if let driver = model.driver {
            Card(title: "Media", icon: "droplet") {
                Row(label: "Type") {
                    Picker("Media type", selection: $model.sheet.print.mediaTypeID) {
                        ForEach(driver.mediaTypes) { media in
                            Text(media.name).tag(media.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                ProfilePicker()
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

            MarginsEditor(margins: $model.sheet.layout.margins)
            HStack(spacing: 6) {
                Group {
                    TablerIcon("border-outer", size: 13)
                    Text("Printer mode: \(model.sheet.print.margin.label)")
                }
                .foregroundStyle(.secondary)
                Spacer()
                Button("Make borderless") { model.sheet.layout.margins = .all(0) }
                    .buttonStyle(.link)
                    .disabled(model.sheet.layout.margins == .all(0))
                    .help("Set all margins to 0 mm")
            }
            .font(.callout)
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
            Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Top").foregroundStyle(.secondary)
                    MillimeterField(title: "Top", value: $margins.top)
                    Text("Bottom").foregroundStyle(.secondary)
                    MillimeterField(title: "Bottom", value: $margins.bottom)
                }
                GridRow {
                    Text("Left").foregroundStyle(.secondary)
                    MillimeterField(title: "Left", value: $margins.left)
                    Text("Right").foregroundStyle(.secondary)
                    MillimeterField(title: "Right", value: $margins.right)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
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

/// Canon's profile for the media type, or a third-party profile (e.g. from the paper maker).
private struct ProfilePicker: View {
    @Environment(AppModel.self) private var model
    @State private var installed = ProfileLibrary.printerProfiles()
    @State private var choosingFile = false

    var body: some View {
        @Bindable var model = model
        let canon = model.driver?.profile(for: model.sheet.print.mediaTypeID)?.fileName ?? "none"
        let custom = model.sheet.print.customProfilePath
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Profile").foregroundStyle(.secondary)
                Spacer()
                Button("Choose File…") { choosingFile = true }
                    .buttonStyle(.link)
                    .font(.callout)
            }
            Picker("Profile", selection: $model.sheet.print.customProfilePath) {
                Text("Canon: \(canon)").tag(String?.none)
                Divider()
                ForEach(installed, id: \.url) { profile in
                    Text(profile.fileName).tag(Optional(profile.url.path))
                }
                if let custom, !installed.contains(where: { $0.url.path == custom }) {
                    Text(URL(fileURLWithPath: custom).lastPathComponent).tag(Optional(custom))
                }
            }
            .labelsHidden()
        }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.init(filenameExtension: "icc")!,
                                                                        .init(filenameExtension: "icm")!]) { result in
            if case .success(let url) = result { model.sheet.print.customProfilePath = url.path }
        }
        .onAppear { installed = ProfileLibrary.printerProfiles() }
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
                    HStack {
                        Text(job.state.label).foregroundStyle(.secondary)
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
                Picker("Preset", selection: Binding(
                    get: { active?.id },
                    set: { id in if let preset = model.presets.first(where: { $0.id == id }) { model.apply(preset) } }
                )) {
                    if active == nil {
                        Text("Custom settings").tag(UUID?.none)
                        Divider()
                    }
                    ForEach(model.presets) { preset in
                        Text(preset.name).tag(Optional(preset.id))
                    }
                }
                .labelsHidden()
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
