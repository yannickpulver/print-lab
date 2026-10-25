import SwiftUI

@main
struct PrintLabApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Print Lab", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 1000, minHeight: 650)
                .onAppear { appDelegate.model = model }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { model.checkForUpdates() }
            }
            CommandGroup(replacing: .newItem) {
                Button("Add Images…") { model.showImporter = true }
                    .keyboardShortcut("o")
            }
            CommandGroup(replacing: .printItem) {
                Button("Print…") { model.requestPrint() }
                    .keyboardShortcut("p")
                    .disabled(!model.canPrint)
            }
        }
    }
}

/// Receives files opened from Finder or dropped on the Dock icon, and `printlab://` commands.
/// SwiftUI's `onOpenURL` only gets the first URL.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel? {
        didSet { flushPending() }
    }
    private var pending: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        pending += urls
        flushPending()
    }

    private func flushPending() {
        guard let model, !pending.isEmpty else { return }
        let urls = pending
        pending = []
        model.addImages(urls.filter(\.isFileURL))
        for url in urls where url.scheme == RemoteControl.scheme {
            RemoteControl.handle(url, model: model)
        }
    }
}
