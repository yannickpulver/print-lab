import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var showInspector = true

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            LibraryView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
        } detail: {
            SheetCanvasView()
                .inspector(isPresented: $showInspector) {
                    InspectorView()
                        .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
                }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                PrinterStatusBadge()
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Toggle(isOn: $model.softproof) {
                    Label("Softproof", systemImage: "eye")
                }
                .help("Show colors as they will look on the selected paper")
                Button {
                    showInspector.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.right")
                }
            }
        }
        .fileImporter(
            isPresented: $model.showImporter,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result { model.addImages(urls) }
        }
        .confirmationDialog("Print this sheet?", isPresented: $model.confirmingPrint) {
            Button("Print") { model.print() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.printSummary.joined(separator: "\n"))
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

struct PrinterStatusBadge: View {
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
        .padding(.horizontal, 8)
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

/// Shown above the sheet while the printer needs attention.
struct PrinterAlertBanner: View {
    @Environment(AppModel.self) private var model
    let alert: PrinterAlert

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: alert.severity == .error ? "exclamationmark.octagon.fill" : "pause.circle.fill")
                .font(.title2)
                .foregroundStyle(alert.severity == .error ? .red : .orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(alert.title).font(.headline)
                Text(alert.message)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let url = alert.helpURL {
                Link("Help", destination: url)
            }
            if let job = model.job, !job.state.isFinal {
                Button("Cancel Job", role: .destructive) { model.cancelJob() }
            }
        }
        .padding(14)
        .frame(maxWidth: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(
            (alert.severity == .error ? Color.red : .orange).opacity(0.5)))
        .padding(.top, 12)
        .padding(.horizontal, 16)
    }
}

extension PrinterStatus.State {
    var label: String {
        switch self {
        case .idle: "Ready"
        case .processing: "Printing"
        case .stopped: "Stopped"
        case .unknown: "Not reachable"
        }
    }
}

extension JobState {
    var label: String {
        switch self {
        case .pending: "Waiting for printer…"
        case .held: "Job on hold"
        case .processing: "Printing…"
        case .stopped: "Job stopped"
        case .canceled: "Canceled"
        case .aborted: "Print failed"
        case .completed: "Done"
        case .unknown: "Job sent"
        }
    }
}
