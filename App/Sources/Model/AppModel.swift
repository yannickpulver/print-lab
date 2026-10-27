import CoreGraphics
import Foundation
import Observation
import Sparkle

struct LibraryItem: Identifiable, @unchecked Sendable {
    let id: UUID
    let url: URL
    let name: String
    /// Upright pixel size of the original.
    let pixelSize: CGSize
    /// Downscaled upright pixels in the image's own profile, used for the preview.
    let preview: RGB16Image
    let thumbnail: CGImage?
}

struct JobInfo: Hashable {
    let id: Int32
    var state: JobState
}

@MainActor
@Observable
final class AppModel {
    nonisolated static let previewPixelSize = 1600

    var queues: [PrinterQueue] = []
    var queue: PrinterQueue? {
        didSet { if oldValue != queue { loadDriver() } }
    }
    private(set) var driver: CanonDriver?

    private(set) var library: [LibraryItem] = []
    var sheet: Sheet {
        didSet { if oldValue != sheet { sheetChanged(from: oldValue) } }
    }
    var color = ColorSettings() {
        didSet { if oldValue != color { refreshPreviews(); savePreferences() } }
    }
    var softproof = true {
        didSet { if oldValue != softproof { refreshPreviews() } }
    }
    var simulatePaperWhite = false {
        didSet { if oldValue != simulatePaperWhite { refreshPreviews() } }
    }

    var selectedCellID: UUID?
    /// Page shown on the canvas.
    var currentPage = 0 {
        didSet { if selectedCell?.page != currentPage { selectedCellID = nil } }
    }
    var showImporter = false
    var errorMessage: String?
    /// Result of the last `printlab://` command, written to the state file.
    var lastCommand: CommandResult?

    private(set) var status = PrinterStatus()
    private(set) var job: JobInfo?
    private(set) var isPreparingJob = false
    /// Images to draw in the sheet preview, by library id.
    private(set) var displayImages: [UUID: CGImage] = [:]
    /// Paper color on screen when paper white is simulated, else nil (plain white).
    private(set) var paperColor: CGColor?

    /// Sparkle updates from the GitHub releases. Debug builds carry build number 1 and skip the check.
    @ObservationIgnored
    private let updater = SPUStandardUpdaterController(
        startingUpdater: !AppModel.isDebug, updaterDelegate: nil, userDriverDelegate: nil)

    #if DEBUG
    private static let isDebug = true
    #else
    private static let isDebug = false
    #endif

    private var previewGeneration = 0
    private var statusTask: Task<Void, Never>?

    init() {
        sheet = Sheet(print: PrintSettings(paperID: "", margin: .standard, mediaTypeID: "", qualityID: ""))
        reloadQueues()
        startStatusPolling()
        startStateExport()
    }

    // MARK: - Derived state

    var geometry: SheetGeometry? {
        guard let page = driver?.pageSize(for: sheet.print) else { return nil }
        return SheetGeometry(pageSize: page, orientation: sheet.orientation)
    }

    var paperProfile: CanonDriver.PaperProfile? { driver?.profile(for: sheet.print) }

    var conflicts: [String] { driver?.conflicts(for: sheet.print) ?? [] }

    var marginPlan: CanonDriver.MarginPlan? {
        driver?.marginPlan(paperID: sheet.print.paperID, mediaID: sheet.print.mediaTypeID,
                           orientation: sheet.orientation, margins: sheet.layout.margins)
    }

    var selectedCell: Cell? { sheet.cells.first { $0.id == selectedCellID } }

    var canPrint: Bool {
        queue != nil && driver != nil && !isPreparingJob && !(job.map { !$0.state.isFinal } ?? false)
            && sheet.cells.contains { $0.imageID != nil } && conflicts.isEmpty
    }

    func item(_ id: UUID?) -> LibraryItem? { library.first { $0.id == id } }

    // MARK: - Printers

    func reloadQueues() {
        queues = CUPSClient.canonQueues()
        let preferred = Preferences.queueName.flatMap { name in queues.first { $0.name == name } }
        queue = preferred ?? queues.first { $0.host != nil } ?? queues.first
    }

    private func loadDriver() {
        guard let queue, let ppd = try? PPDFile(contentsOf: queue.ppdURL), let driver = CanonDriver(ppd: ppd) else {
            driver = nil
            return
        }
        self.driver = driver
        Preferences.queueName = queue.name
        var next = sheet
        next.print = Preferences.printSettings.flatMap { saved in
            driver.paper(saved.paperID) != nil && driver.mediaType(saved.mediaTypeID) != nil ? saved : nil
        } ?? driver.defaultSettings()
        if let layout = Preferences.layout { next.layout = layout }
        if let orientation = Preferences.orientation { next.orientation = orientation }
        if let color = Preferences.color { self.color = color }
        sheet = next
        relayout()
        refreshStatus()
    }

    private func startStatusPolling() {
        statusTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refreshStatus()
                let busy = self?.job.map { !$0.state.isFinal } ?? false
                try? await Task.sleep(for: .seconds(busy ? 2 : 10))
            }
        }
    }

    func refreshStatus() {
        guard let queue else { return }
        let job = self.job
        Task.detached {
            var status = CUPSClient.status(of: queue)
            if let host = queue.host { status.remoteUI = await RemoteUIClient.shared.status(host: host) }
            let jobState = job.map { CUPSClient.jobState(id: $0.id, queue: queue.name) }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.status = status
                if let jobState, let current = self.job, current.id == job?.id, !current.state.isFinal {
                    self.job?.state = jobState
                }
            }
        }
    }

    // MARK: - Library

    /// Loads one image after the other: keeps the order and the memory use of 16-bit decoding low.
    /// The first image goes into `cellID` when given, and the canvas shows its page.
    func addImages(_ urls: [URL], into cellID: UUID? = nil, completion: (@MainActor () -> Void)? = nil) {
        Task.detached(priority: .userInitiated) {
            for (index, url) in urls.enumerated() {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                do {
                    let loaded = try ImageLoader.load(url)
                    let preview = try ImageLoader.uprightBuffer(loaded, maxPixelSize: Self.previewPixelSize)
                    let item = LibraryItem(
                        id: UUID(), url: url, name: url.lastPathComponent, pixelSize: loaded.uprightSize,
                        preview: preview, thumbnail: preview.cgImage()
                    )
                    await MainActor.run { [weak self] in
                        self?.didLoad(item, into: index == 0 ? cellID : nil, reveal: index == 0)
                    }
                } catch {
                    await MainActor.run { [weak self] in
                        self?.errorMessage = "\(url.lastPathComponent) could not be opened."
                    }
                }
            }
            await MainActor.run { completion?() }
        }
    }

    func clearLibrary() {
        library = []
        displayImages = [:]
        var next = sheet
        for i in next.cells.indices { next.cells[i].imageID = nil }
        sheet = next
        relayout()
    }

    private func didLoad(_ item: LibraryItem, into cellID: UUID?, reveal: Bool) {
        library.append(item)
        if sheet.layout.template == .contactSheet {
            relayout()
        } else {
            if let index = sheet.cells.firstIndex(where: { $0.id == cellID }) ?? nextFreeCell() {
                place(item.id, inCellAt: index)
                if reveal { currentPage = sheet.cells[index].page }
            }
        }
        refreshPreviews()
    }

    /// First empty cell, on a new page when all are taken.
    private func nextFreeCell() -> Int? {
        if let index = sheet.cells.firstIndex(where: { $0.imageID == nil }) { return index }
        guard !sheet.cells.isEmpty else { return nil }
        var next = sheet
        next.appendPage()
        sheet = next
        return sheet.cells.firstIndex { $0.imageID == nil }
    }

    func removeFromLibrary(_ id: UUID) {
        library.removeAll { $0.id == id }
        displayImages[id] = nil
        var next = sheet
        for i in next.cells.indices where next.cells[i].imageID == id {
            next.cells[i].imageID = nil
        }
        next.removeEmptyPages()
        sheet = next
        if sheet.layout.template == .contactSheet { relayout() }
    }

    // MARK: - Sheet editing

    func place(_ imageID: UUID, inCell cellID: UUID) {
        guard let index = sheet.cells.firstIndex(where: { $0.id == cellID }) else { return }
        place(imageID, inCellAt: index)
        selectedCellID = cellID
    }

    /// Puts an image into the selected cell, else the first empty one, else on a new page.
    func placeInNextCell(_ imageID: UUID) {
        guard let index = sheet.cells.firstIndex(where: { $0.id == selectedCellID }) ?? nextFreeCell() else { return }
        place(imageID, inCellAt: index)
        currentPage = sheet.cells[index].page
    }

    private func place(_ imageID: UUID, inCellAt index: Int) {
        var next = sheet
        next.cells[index].imageID = imageID
        next.cells[index].cropOffset = .zero
        next.cells[index].quarterTurns = autoTurns(for: imageID, frame: next.cells[index].frame)
        sheet = next
    }

    func clearCell(_ cellID: UUID) {
        guard let index = sheet.cells.firstIndex(where: { $0.id == cellID }) else { return }
        var next = sheet
        next.cells[index].imageID = nil
        next.removeEmptyPages()
        sheet = next
    }

    func updateCell(_ cellID: UUID, _ change: (inout Cell) -> Void) {
        guard let index = sheet.cells.firstIndex(where: { $0.id == cellID }) else { return }
        var next = sheet
        change(&next.cells[index])
        sheet = next
    }

    func relayout() {
        guard let geometry else { return }
        var next = sheet
        LayoutEngine.relayout(&next, geometry: geometry, imageIDs: library.map(\.id))
        for i in next.cells.indices {
            if let id = next.cells[i].imageID {
                next.cells[i].quarterTurns = autoTurns(for: id, frame: next.cells[i].frame)
            }
        }
        sheet = next
        if let selectedCellID, !sheet.cells.contains(where: { $0.id == selectedCellID }) {
            self.selectedCellID = nil
        }
    }

    func showPage(_ page: Int) {
        currentPage = min(max(0, page), sheet.pageCount - 1)
    }

    /// A quarter turn when the image and the cell have different orientations.
    private func autoTurns(for imageID: UUID, frame: CGRect) -> Int {
        guard sheet.layout.autoRotate, let size = item(imageID)?.pixelSize else { return 0 }
        let imageLandscape = size.width > size.height
        let cellLandscape = frame.width > frame.height
        return imageLandscape == cellLandscape ? 0 : 1
    }

    private func sheetChanged(from old: Sheet) {
        // The margins decide the page variant (standard, borderless, fine art).
        if let plan = marginPlan {
            var planned = sheet.print
            planned.apply(plan)
            if planned != sheet.print { sheet.print = planned }
        }
        let geometryChanged = old.print.paperID != sheet.print.paperID || old.print.margin != sheet.print.margin
            || old.orientation != sheet.orientation || old.layout != sheet.layout
        if geometryChanged { relayout() }
        if currentPage >= sheet.pageCount { currentPage = sheet.pageCount - 1 }
        if old.print.mediaTypeID != sheet.print.mediaTypeID || old.print.customProfilePath != sheet.print.customProfilePath {
            refreshPreviews()
        }
        if old.print != sheet.print || old.layout != sheet.layout || old.orientation != sheet.orientation {
            savePreferences()
        }
    }

    // MARK: - Preview

    /// Recomputes the preview pixels: softproofed through the paper profile, or the source as is.
    func refreshPreviews() {
        previewGeneration += 1
        let generation = previewGeneration
        let items = library
        let profileURL = paperProfile?.url
        let color = self.color
        let softproof = self.softproof && profileURL != nil
        let paperWhite = simulatePaperWhite
        Task.detached(priority: .userInitiated) {
            let paper = profileURL.flatMap { try? ColorPipeline.profile(at: $0) }
            var paperColor: CGColor?
            if softproof, paperWhite, let paper {
                let white = RGB16Image(width: 1, height: 1, pixels: [65535, 65535, 65535], profile: paper)
                if let proof = try? ColorPipeline.softproof(white, simulatePaperWhite: true) {
                    let c = proof.pixels.map { CGFloat($0) / 65535 }
                    paperColor = CGColor(colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!,
                                         components: [c[0], c[1], c[2], 1])
                }
            }
            var result: [UUID: CGImage] = [:]
            for item in items {
                if softproof, let paper,
                   let onPaper = try? ColorPipeline.toPaper(item.preview, paper: paper, settings: color),
                   let proof = try? ColorPipeline.softproof(onPaper, simulatePaperWhite: paperWhite) {
                    result[item.id] = proof.cgImage()
                } else {
                    result[item.id] = item.preview.cgImage()
                }
            }
            await MainActor.run { [weak self] in
                guard let self, generation == self.previewGeneration else { return }
                self.displayImages = result
                self.paperColor = paperColor
            }
        }
    }

    func checkForUpdates() {
        updater.checkForUpdates(nil)
    }

    // MARK: - Printing

    /// Shows the confirmation before anything goes to the printer.
    var confirmingPrint = false

    func requestPrint() {
        guard canPrint else { return }
        confirmingPrint = true
    }

    /// What the confirmation lists: paper, media, profile, quality, margins, feed and image count.
    var printSummary: [String] {
        guard let driver else { return [] }
        let paper = driver.paper(sheet.print.paperID)?.label ?? sheet.print.paperID
        let orientation = sheet.orientation == .portrait ? "portrait" : "landscape"
        let media = driver.mediaType(sheet.print.mediaTypeID)?.name ?? sheet.print.mediaTypeID
        let quality = driver.qualities.first { $0.id == sheet.print.qualityID }?.name ?? sheet.print.qualityID
        let source = driver.paperSources.first { $0.id == sheet.print.paperSourceID }?.name
        let m = sheet.layout.margins
        let margins = [m.top, m.left, m.bottom, m.right].allSatisfy { $0 == m.top }
            ? String(format: "%g mm", m.top)
            : String(format: "%g / %g / %g / %g mm", m.top, m.left, m.bottom, m.right)
        let images = sheet.cells.filter { $0.imageID != nil }.count
        let sheets = Set(sheet.cells.filter { $0.imageID != nil }.map(\.page)).count
        let manualFeed = source?.localizedCaseInsensitiveContains("Manual") == true
        return [
            "\(paper), \(orientation)" + (source.map { " · \($0)" } ?? ""),
            media,
            "Profile: \(paperProfile?.fileName ?? "none")",
            "Quality: \(quality)",
            "Margins: \(margins) (\(sheet.print.margin.label))",
            (images == 1 ? "1 image" : "\(images) images") + (sheets > 1 ? " on \(sheets) sheets" : ""),
        ] + (manualFeed ? ["", "Manual feed: load the sheet when the printer asks and press OK on the printer."] : [])
    }

    func print() {
        confirmingPrint = false
        guard canPrint, let queue, let driver else { return }
        let request = PrintRequest(
            sheet: sheet, queue: queue, driver: driver, color: color,
            sources: Dictionary(uniqueKeysWithValues: library.map { ($0.id, $0.url) }),
            captions: Dictionary(uniqueKeysWithValues: library.map { ($0.id, $0.name) }),
            title: library.first { item in sheet.cells.contains { $0.imageID == item.id } }?.name ?? "Print Lab"
        )
        isPreparingJob = true
        Task.detached(priority: .userInitiated) {
            do {
                let id = try PrintJob.submit(request)
                await MainActor.run { [weak self] in
                    self?.isPreparingJob = false
                    self?.job = JobInfo(id: id, state: .pending)
                    self?.refreshStatus()
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.isPreparingJob = false
                    self?.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func cancelJob() {
        guard let job, let queue else { return }
        CUPSClient.cancel(job: job.id, queue: queue.name)
        refreshStatus()
    }

    // MARK: - Presets & preferences

    var presets: [Preset] = Preferences.presets {
        didSet { Preferences.presets = presets }
    }

    /// The preset the current settings match exactly, if any.
    var activePreset: Preset? {
        presets.first { $0.print == sheet.print && $0.layout == sheet.layout
            && $0.orientation == sheet.orientation && $0.color == color }
    }

    /// Saves the current settings under a name. A preset with the same name gets replaced.
    func savePreset(named name: String) {
        let preset = makePreset(named: name)
        if let index = presets.firstIndex(where: { $0.name.localizedCaseInsensitiveCompare(preset.name) == .orderedSame }) {
            presets[index] = Preset(id: presets[index].id, name: preset.name, print: preset.print,
                                    layout: preset.layout, orientation: preset.orientation, color: preset.color)
        } else {
            presets.append(preset)
        }
    }

    func makePreset(named name: String) -> Preset {
        Preset(name: name.trimmingCharacters(in: .whitespaces), print: sheet.print, layout: sheet.layout,
               orientation: sheet.orientation, color: color)
    }

    func apply(_ preset: Preset) {
        guard let driver, driver.paper(preset.print.paperID) != nil,
              driver.mediaType(preset.print.mediaTypeID) != nil else {
            errorMessage = "This preset does not match the selected printer."
            return
        }
        var next = sheet
        next.print = preset.print
        next.layout = preset.layout
        next.orientation = preset.orientation
        sheet = next
        color = preset.color
    }

    private func savePreferences() {
        guard driver != nil else { return }
        Preferences.printSettings = sheet.print
        Preferences.layout = sheet.layout
        Preferences.orientation = sheet.orientation
        Preferences.color = color
    }
}
