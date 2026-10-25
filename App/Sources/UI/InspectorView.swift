import SwiftUI

struct InspectorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            PrinterSection()
            if model.driver != nil {
                PaperSection()
                LayoutSection()
                if model.selectedCell != nil { CellSection() }
                ColorSection()
                PrintSection()
                PresetSection()
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Printer

private struct PrinterSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Section("Printer") {
            Picker("Queue", selection: $model.queue) {
                ForEach(model.queues) { queue in
                    Text(queue.info).tag(Optional(queue))
                }
            }
            if let queue = model.queue {
                LabeledContent("Connection", value: queue.host ?? "USB")
            }
            if let signal = model.status.remoteUI?.signal {
                LabeledContent("Wi-Fi Signal", value: "\(signal) %" + (signal < 50 ? " (weak)" : ""))
            }
            if let alert = model.printerAlert {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(alert.title).bold()
                        Text(alert.message)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.octagon.fill")
                }
                .foregroundStyle(alert.severity == .error ? .red : .orange)
            }
            ForEach(model.status.reasons.compactMap(Self.describe), id: \.self) { reason in
                Label(reason, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            if !model.status.markers.isEmpty {
                InkLevels(markers: model.status.markers)
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
                VStack(spacing: 3) {
                    GeometryReader { proxy in
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.15))
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color(hex: marker.color) ?? .secondary)
                                .frame(height: proxy.size.height * CGFloat(marker.level ?? 0) / 100)
                        }
                    }
                    .frame(height: 44)
                    Text(marker.name)
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
                .help("\(marker.name): \(marker.level.map { "\($0) %" } ?? "unknown")")
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Paper

private struct PaperSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        if let driver = model.driver {
            Section("Paper") {
                Picker("Size", selection: $model.sheet.print.paperID) {
                    ForEach(driver.papers) { paper in
                        Text(paper.label).tag(paper.id)
                    }
                }
                Picker("Orientation", selection: $model.sheet.orientation) {
                    Text("Portrait").tag(Orientation.portrait)
                    Text("Landscape").tag(Orientation.landscape)
                }
                .pickerStyle(.segmented)
                Picker("Media Type", selection: $model.sheet.print.mediaTypeID) {
                    ForEach(driver.mediaTypes) { media in
                        Text(media.name).tag(media.id)
                    }
                }
                if !driver.paperSources.isEmpty {
                    Picker("Paper Source", selection: $model.sheet.print.paperSourceID) {
                        ForEach(driver.paperSources) { source in
                            Text(source.name).tag(Optional(source.id))
                        }
                    }
                }
                ForEach(model.conflicts, id: \.self) { conflict in
                    Label(conflict, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
        }
    }
}

// MARK: - Layout

private struct LayoutSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Section("Layout") {
            Picker("Template", selection: $model.sheet.layout.template) {
                ForEach(Template.allCases, id: \.self) { template in
                    Text(template.label).tag(template)
                }
            }
            switch model.sheet.layout.template {
            case .single:
                EmptyView()
            case .grid:
                Stepper("Rows: \(model.sheet.layout.rows)", value: $model.sheet.layout.rows, in: 1...12)
                Stepper("Columns: \(model.sheet.layout.columns)", value: $model.sheet.layout.columns, in: 1...12)
            case .contactSheet:
                Stepper("Columns: \(model.sheet.layout.columns)", value: $model.sheet.layout.columns, in: 1...12)
            }
            if model.sheet.layout.template != .single {
                MillimeterField(title: "Gap", value: $model.sheet.layout.gapMM)
            }
            MarginsEditor(margins: $model.sheet.layout.margins)
            LabeledContent("Printer Mode") {
                HStack {
                    Text(model.sheet.print.margin.label)
                    Button("Borderless") { model.sheet.layout.margins = .all(0) }
                        .controlSize(.small)
                        .disabled(model.sheet.layout.margins == .all(0))
                        .help("Set all margins to 0 mm")
                }
            }
            ForEach(model.marginPlan?.notes ?? [], id: \.self) { note in
                Label(note, systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }
            Toggle("Captions", isOn: $model.sheet.layout.captions)
            Toggle("Rotate images to fit cells", isOn: $model.sheet.layout.autoRotate)
        }
    }
}

private struct MarginsEditor: View {
    @Binding var margins: EdgeInsetsMM
    @State private var individual = false

    var body: some View {
        Toggle("Individual margins", isOn: $individual)
            .onAppear { individual = !(margins.top == margins.left && margins.left == margins.bottom
                && margins.bottom == margins.right) }
        if individual {
            MillimeterField(title: "Top", value: $margins.top)
            MillimeterField(title: "Left", value: $margins.left)
            MillimeterField(title: "Bottom", value: $margins.bottom)
            MillimeterField(title: "Right", value: $margins.right)
        } else {
            MillimeterField(title: "Margins", value: Binding(
                get: { margins.top },
                set: { margins = .all($0) }
            ))
        }
    }
}

struct MillimeterField: View {
    let title: String
    @Binding var value: Double

    var body: some View {
        TextField(title, value: $value, format: .number.precision(.fractionLength(0...1)))
            .multilineTextAlignment(.trailing)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .trailing) {
                Text("mm").foregroundStyle(.secondary).padding(.trailing, -24)
            }
            .padding(.trailing, 24)
    }
}

// MARK: - Selected cell

private struct CellSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let cell = model.selectedCell {
            Section("Selected Image") {
                if let item = model.item(cell.imageID) {
                    LabeledContent("File", value: item.name)
                    LabeledContent("Print size", value: printSize(cell))
                    LabeledContent("Resolution", value: resolution(cell, item: item))
                    Picker("Fit", selection: Binding(
                        get: { cell.fit },
                        set: { fit in model.updateCell(cell.id) { $0.fit = fit; $0.cropOffset = .zero } }
                    )) {
                        Text("Fill").tag(Fit.fill)
                        Text("Fit").tag(Fit.fit)
                    }
                    .pickerStyle(.segmented)
                    HStack {
                        Button {
                            model.updateCell(cell.id) { $0.quarterTurns -= 1 }
                        } label: { Label("Rotate Left", systemImage: "rotate.left") }
                        Button {
                            model.updateCell(cell.id) { $0.quarterTurns += 1 }
                        } label: { Label("Rotate Right", systemImage: "rotate.right") }
                        Spacer()
                        Button("Center") { model.updateCell(cell.id) { $0.cropOffset = .zero } }
                            .disabled(cell.cropOffset == .zero)
                    }
                    .labelStyle(.iconOnly)
                    Button("Remove from Cell", role: .destructive) { model.clearCell(cell.id) }
                } else {
                    Text("Drop an image from the list onto this cell, or double-click an image.")
                        .foregroundStyle(.secondary)
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

private struct ColorSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Section("Color") {
            ProfilePicker()
            Picker("Rendering Intent", selection: $model.color.intent) {
                ForEach(RenderingIntent.allCases, id: \.self) { intent in
                    Text(intent.label).tag(intent)
                }
            }
            Toggle("Black Point Compensation", isOn: $model.color.blackPointCompensation)
            Toggle("Softproof", isOn: $model.softproof)
            Toggle("Simulate Paper White", isOn: $model.simulatePaperWhite)
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
        Button("Choose Profile File…") { choosingFile = true }
            .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.init(filenameExtension: "icc")!,
                                                                            .init(filenameExtension: "icm")!]) { result in
                if case .success(let url) = result { model.sheet.print.customProfilePath = url.path }
            }
            .onAppear { installed = ProfileLibrary.printerProfiles() }
    }
}

// MARK: - Print

private struct PrintSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        if let driver = model.driver {
            Section("Print") {
                Picker("Quality", selection: $model.sheet.print.qualityID) {
                    ForEach(driver.qualities) { quality in
                        Text(quality.name).tag(quality.id)
                    }
                }
                if !driver.dryingTimes.isEmpty {
                    Picker("Drying Time", selection: $model.sheet.print.dryingTimeID) {
                        ForEach(driver.dryingTimes) { time in
                            Text(time.name).tag(Optional(time.id))
                        }
                    }
                }
                HStack {
                    if model.isPreparingJob {
                        ProgressView().controlSize(.small)
                        Text("Preparing…").foregroundStyle(.secondary)
                    } else if let job = model.job {
                        Text(job.state.label).foregroundStyle(.secondary)
                        if !job.state.isFinal {
                            Button("Cancel", role: .destructive) { model.cancelJob() }
                        }
                    }
                    Spacer()
                    Button("Print…") { model.requestPrint() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canPrint)
                }
            }
        }
    }
}

// MARK: - Presets

private struct PresetSection: View {
    @Environment(AppModel.self) private var model
    @State private var newName = ""

    var body: some View {
        Section("Presets") {
            ForEach(model.presets) { preset in
                HStack {
                    Button(preset.name) { model.apply(preset) }
                        .buttonStyle(.link)
                    Spacer()
                    Button {
                        model.presets.removeAll { $0.id == preset.id }
                    } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("Delete preset")
                }
            }
            HStack {
                TextField("New preset name", text: $newName)
                    .textFieldStyle(.roundedBorder)
                Button("Save") {
                    model.savePreset(named: newName)
                    newName = ""
                }
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
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
