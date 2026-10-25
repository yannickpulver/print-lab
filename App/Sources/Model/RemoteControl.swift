import Foundation

/// Lets scripts set up a sheet via `canonprintlab://configure?…` and read the result from `state.json`.
/// There is deliberately no print command: a person presses Print.
///
/// Values match by id or by name (case-insensitive, exact first, then "contains"):
///
///     open "canonprintlab://configure?clear=1&image=/path/a.tif&image=/path/b.jpg&paper=A3
///           &media=Baryta&quality=Super%20Fine&template=grid&rows=1&columns=2&margins=20"
///
/// Keys: queue, clear, image (repeatable), paper, edge (standard|borderless|artMargin), orientation,
/// media, quality, source, drying, profile (auto | path | installed file name), template (single|grid|contactSheet), rows, columns, gap, margins,
/// marginTop, marginLeft, marginBottom, marginRight, captions, autorotate, intent (perceptual|relative),
/// bpc, softproof, paperwhite, fit (fill|fit, all cells), fit.N, turns.N, crop.N (x,y in -1…1),
/// select (cell index), preset (saved preset name).
@MainActor
enum RemoteControl {
    static let scheme = "canonprintlab"

    static var stateURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("CanonPrintLab/state.json")
    }

    static func handle(_ url: URL, model: AppModel) {
        guard url.host == "configure",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            model.lastCommand = CommandResult(url: url.absoluteString, errors: ["Unknown command \(url.host ?? "")"])
            return
        }
        var errors: [String] = []
        var images: [URL] = []
        var cellEdits: [(String, String)] = []

        func value(_ item: URLQueryItem) -> String { item.value ?? "" }

        // Queue first: it decides which options exist.
        if let queue = items.first(where: { $0.name == "queue" }).map(value) {
            if let match = model.queues.first(where: { $0.name == queue || $0.info.localizedCaseInsensitiveContains(queue) }) {
                model.queue = match
            } else {
                errors.append("queue: no match for \(queue)")
            }
        }
        if let preset = items.first(where: { $0.name == "preset" }).map(value) {
            if let match = Preferences.presets.first(where: { $0.name.localizedCaseInsensitiveCompare(preset) == .orderedSame }) {
                model.apply(match)
            } else {
                errors.append("preset: no preset named \(preset)")
            }
        }
        guard let driver = model.driver else {
            model.lastCommand = CommandResult(url: url.absoluteString, errors: errors + ["No Canon driver queue"])
            return
        }

        var sheet = model.sheet
        var color = model.color
        for item in items {
            let v = value(item)
            switch item.name {
            case "queue", "preset":
                continue
            case "clear":
                if bool(v) == true { model.clearLibrary() }
            case "image":
                images.append(URL(fileURLWithPath: (v as NSString).expandingTildeInPath))
            case "paper":
                if let id = match(v, driver.papers.map { ($0.id, $0.label) }) { sheet.print.paperID = id }
                else { errors.append("paper: no match for \(v)") }
            case "edge":
                if let edge = CanonDriver.Margin(rawValue: v) { sheet.print.margin = edge }
                else { errors.append("edge: use standard, borderless or artMargin") }
            case "orientation":
                if let o = Orientation(rawValue: v) { sheet.orientation = o }
                else { errors.append("orientation: use portrait or landscape") }
            case "media":
                if let id = match(v, driver.mediaTypes.map { ($0.id, $0.name) }) { sheet.print.mediaTypeID = id }
                else { errors.append("media: no match for \(v)") }
            case "quality":
                if let id = match(v, driver.qualities.map { ($0.id, $0.name) }) { sheet.print.qualityID = id }
                else { errors.append("quality: no match for \(v)") }
            case "source":
                if let id = match(v, driver.paperSources.map { ($0.id, $0.name) }) { sheet.print.paperSourceID = id }
                else { errors.append("source: no match for \(v)") }
            case "profile":
                if ["auto", "canon", ""].contains(v.lowercased()) {
                    sheet.print.customProfilePath = nil
                } else if FileManager.default.fileExists(atPath: (v as NSString).expandingTildeInPath) {
                    sheet.print.customProfilePath = (v as NSString).expandingTildeInPath
                } else if let id = match(v, ProfileLibrary.printerProfiles().map { ($0.url.path, $0.fileName) }) {
                    sheet.print.customProfilePath = id
                } else {
                    errors.append("profile: no installed printer profile matches \(v)")
                }
            case "drying":
                if let id = match(v, driver.dryingTimes.map { ($0.id, $0.name) }) { sheet.print.dryingTimeID = id }
                else { errors.append("drying: no match for \(v)") }
            case "template":
                if let t = Template(rawValue: v) { sheet.layout.template = t }
                else { errors.append("template: use single, grid or contactSheet") }
            case "rows":
                if let n = Int(v), (1...12).contains(n) { sheet.layout.rows = n } else { errors.append("rows: 1…12") }
            case "columns":
                if let n = Int(v), (1...12).contains(n) { sheet.layout.columns = n } else { errors.append("columns: 1…12") }
            case "gap":
                if let mm = Double(v), mm >= 0 { sheet.layout.gapMM = mm } else { errors.append("gap: millimeters") }
            case "margins":
                if let mm = Double(v), mm >= 0 { sheet.layout.margins = .all(mm) } else { errors.append("margins: millimeters") }
            case "marginTop", "marginLeft", "marginBottom", "marginRight":
                guard let mm = Double(v), mm >= 0 else { errors.append("\(item.name): millimeters"); continue }
                switch item.name {
                case "marginTop": sheet.layout.margins.top = mm
                case "marginLeft": sheet.layout.margins.left = mm
                case "marginBottom": sheet.layout.margins.bottom = mm
                default: sheet.layout.margins.right = mm
                }
            case "captions":
                if let b = bool(v) { sheet.layout.captions = b } else { errors.append("captions: true or false") }
            case "autorotate":
                if let b = bool(v) { sheet.layout.autoRotate = b } else { errors.append("autorotate: true or false") }
            case "intent":
                switch v.lowercased() {
                case "perceptual": color.intent = .perceptual
                case "relative", "relativecolorimetric": color.intent = .relativeColorimetric
                default: errors.append("intent: use perceptual or relative")
                }
            case "bpc":
                if let b = bool(v) { color.blackPointCompensation = b } else { errors.append("bpc: true or false") }
            case "softproof":
                if let b = bool(v) { model.softproof = b } else { errors.append("softproof: true or false") }
            case "paperwhite":
                if let b = bool(v) { model.simulatePaperWhite = b } else { errors.append("paperwhite: true or false") }
            case "select":
                cellEdits.append((item.name, v))
            default:
                if item.name == "fit" || item.name.hasPrefix("fit.") || item.name.hasPrefix("turns.")
                    || item.name.hasPrefix("crop.") {
                    cellEdits.append((item.name, v))
                } else {
                    errors.append("unknown key \(item.name)")
                }
            }
        }
        if let paper = driver.paper(sheet.print.paperID), paper.variants[sheet.print.margin] == nil {
            errors.append("edge: \(sheet.print.margin.rawValue) is not available for \(paper.label)")
        }
        model.sheet = sheet
        model.color = color

        let result = CommandResult(url: url.absoluteString, errors: errors)
        model.lastCommand = result
        // Cell edits wait for the images, because placing an image resets rotation and crop.
        model.addImages(images) {
            let cellErrors = applyCellEdits(cellEdits, model: model)
            model.lastCommand = CommandResult(url: result.url, errors: result.errors + cellErrors)
        }
    }

    private static func applyCellEdits(_ edits: [(String, String)], model: AppModel) -> [String] {
        var errors: [String] = []
        for (key, v) in edits {
            let parts = key.split(separator: ".", maxSplits: 1).map(String.init)
            if key == "select" {
                guard let i = Int(v), model.sheet.cells.indices.contains(i) else { errors.append("select: no cell \(v)"); continue }
                model.selectedCellID = model.sheet.cells[i].id
                continue
            }
            if key == "fit" {
                guard let fit = Fit(rawValue: v) else { errors.append("fit: use fill or fit"); continue }
                for cell in model.sheet.cells { model.updateCell(cell.id) { $0.fit = fit; $0.cropOffset = .zero } }
                continue
            }
            guard parts.count == 2, let i = Int(parts[1]), model.sheet.cells.indices.contains(i) else {
                errors.append("\(key): no such cell")
                continue
            }
            let id = model.sheet.cells[i].id
            switch parts[0] {
            case "fit":
                if let fit = Fit(rawValue: v) { model.updateCell(id) { $0.fit = fit; $0.cropOffset = .zero } }
                else { errors.append("\(key): use fill or fit") }
            case "turns":
                if let n = Int(v) { model.updateCell(id) { $0.quarterTurns = n } }
                else { errors.append("\(key): quarter turns as a number") }
            case "crop":
                let xy = v.split(separator: ",").compactMap { Double($0) }
                if xy.count == 2 {
                    model.updateCell(id) { $0.cropOffset = CGPoint(x: min(1, max(-1, xy[0])), y: min(1, max(-1, xy[1]))) }
                } else {
                    errors.append("\(key): use x,y between -1 and 1")
                }
            default:
                errors.append("unknown key \(key)")
            }
        }
        return errors
    }

    /// Id match first, then exact name, then name contains the value.
    private static func match(_ value: String, _ choices: [(id: String, name: String)]) -> String? {
        choices.first { $0.id == value }?.id
            ?? choices.first { $0.name.localizedCaseInsensitiveCompare(value) == .orderedSame }?.id
            ?? choices.first { $0.name.localizedCaseInsensitiveContains(value) }?.id
    }

    private static func bool(_ v: String) -> Bool? {
        switch v.lowercased() {
        case "1", "true", "yes", "on": true
        case "0", "false", "no", "off": false
        default: nil
        }
    }
}

struct CommandResult: Encodable, Hashable {
    let url: String
    let errors: [String]
}
