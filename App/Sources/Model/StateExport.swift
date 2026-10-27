import Foundation

/// Everything a script needs to check a sheet before a person prints it.
struct RemoteState: Encodable, Equatable {
    struct Option: Encodable, Equatable {
        let id: String
        let name: String
    }

    struct Paper: Encodable, Equatable {
        let id: String
        let name: String
        let edges: [String]
    }

    struct Printer: Encodable, Equatable {
        let queue: String?
        let connection: String?
        let state: String
        let warnings: [String]
        let ink: [String: Int]
        let alert: String?
        let wifiSignal: Int?
    }

    struct Settings: Encodable, Equatable {
        let paper: Option?
        let edge: String
        let orientation: String
        let media: Option?
        let profile: String?
        let quality: Option?
        let source: Option?
        let drying: Option?
        let intent: String
        let blackPointCompensation: Bool
        let softproof: Bool
        let simulatePaperWhite: Bool
    }

    struct Image: Encodable, Equatable {
        let index: Int
        let name: String
        let path: String
        let pixels: String
    }

    struct CellInfo: Encodable, Equatable {
        let index: Int
        let frameMM: [Double]
        let image: String?
        let fit: String
        let quarterTurns: Int
        let crop: [Double]
        let ppi: Int?
    }

    let printer: Printer
    let settings: Settings
    let layout: LayoutSpec
    let images: [Image]
    let cells: [CellInfo]
    let selectedCell: Int?
    let conflicts: [String]
    let marginNotes: [String]
    /// Canon's fine art margin per side, when the margins go below it.
    let artMargins: EdgeInsetsMM?
    let readyToPrint: Bool
    let job: String?
    let lastCommand: CommandResult?
    let options: [String: [Option]]
    let papers: [Paper]
}

extension AppModel {
    /// Writes `state.json` whenever the state changes.
    func startStateExport() {
        Task { [weak self] in
            var last: RemoteState?
            while !Task.isCancelled {
                if let self {
                    let state = self.remoteState()
                    if state != last {
                        self.write(state)
                        last = state
                    }
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func write(_ state: RemoteState) {
        let url = RemoteControl.stateURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try? encoder.encode(state).write(to: url, options: .atomic)
    }

    func remoteState() -> RemoteState {
        let driver = self.driver
        func option(_ id: String?, _ choices: [CanonDriver.Choice]?) -> RemoteState.Option? {
            guard let id, let choice = choices?.first(where: { $0.id == id }) else { return nil }
            return RemoteState.Option(id: choice.id, name: choice.name)
        }
        let media = driver?.mediaType(sheet.print.mediaTypeID)
        let paper = driver?.paper(sheet.print.paperID)
        let names = Dictionary(uniqueKeysWithValues: library.map { ($0.id, $0.name) })

        let cells = sheet.cells.enumerated().map { index, cell in
            var ppi: Int?
            if let item = item(cell.imageID) {
                let rect = SheetRenderer.imageRect(imageSize: item.pixelSize, cell: cell)
                let longSide = max(item.pixelSize.width, item.pixelSize.height)
                ppi = Int((longSide / (max(rect.width, rect.height) / 25.4)).rounded())
            }
            return RemoteState.CellInfo(
                index: index,
                frameMM: [cell.frame.minX, cell.frame.minY, cell.frame.width, cell.frame.height].map { (Double($0) * 10).rounded() / 10 },
                image: cell.imageID.flatMap { names[$0] },
                fit: cell.fit.rawValue,
                quarterTurns: cell.quarterTurns,
                crop: [cell.cropOffset.x, cell.cropOffset.y],
                ppi: ppi
            )
        }

        return RemoteState(
            printer: RemoteState.Printer(
                queue: queue?.name,
                connection: queue.map { $0.host ?? "USB" },
                state: status.state.rawValue,
                warnings: status.reasons,
                ink: Dictionary(status.markers.compactMap { m in m.level.map { (m.name, $0) } }, uniquingKeysWith: { a, _ in a }),
                alert: printerAlert.map { "\($0.title): \($0.message)" },
                wifiSignal: status.remoteUI?.signal
            ),
            settings: RemoteState.Settings(
                paper: paper.map { RemoteState.Option(id: $0.id, name: $0.label) },
                edge: sheet.print.margin.rawValue,
                orientation: sheet.orientation.rawValue,
                media: media.map { RemoteState.Option(id: $0.id, name: $0.name) },
                profile: paperProfile?.fileName,
                quality: option(sheet.print.qualityID, driver?.qualities),
                source: option(sheet.print.paperSourceID, driver?.paperSources),
                drying: option(sheet.print.dryingTimeID, driver?.dryingTimes),
                intent: color.intent.rawValue,
                blackPointCompensation: color.blackPointCompensation,
                softproof: softproof,
                simulatePaperWhite: simulatePaperWhite
            ),
            layout: sheet.layout,
            images: library.enumerated().map { index, item in
                RemoteState.Image(index: index, name: item.name, path: item.url.path,
                                  pixels: "\(Int(item.pixelSize.width))x\(Int(item.pixelSize.height))")
            },
            cells: cells,
            selectedCell: sheet.cells.firstIndex { $0.id == selectedCellID },
            conflicts: conflicts,
            marginNotes: marginPlan?.notes ?? [],
            artMargins: marginPlan?.artMargins,
            readyToPrint: canPrint,
            job: isPreparingJob ? "preparing" : job.map { "\($0.id): \($0.state)" },
            lastCommand: lastCommand,
            options: [
                "media": driver?.mediaTypes.map { RemoteState.Option(id: $0.id, name: $0.name) } ?? [],
                "quality": driver?.qualities.map { RemoteState.Option(id: $0.id, name: $0.name) } ?? [],
                "source": driver?.paperSources.map { RemoteState.Option(id: $0.id, name: $0.name) } ?? [],
                "drying": driver?.dryingTimes.map { RemoteState.Option(id: $0.id, name: $0.name) } ?? [],
                "queue": queues.map { RemoteState.Option(id: $0.name, name: $0.info) },
                "preset": presets.map { RemoteState.Option(id: $0.id.uuidString, name: $0.name) },
                "profile": ProfileLibrary.printerProfiles().map { RemoteState.Option(id: $0.url.path, name: $0.fileName) },
            ],
            papers: driver?.papers.map { p in
                RemoteState.Paper(id: p.id, name: p.label,
                                  edges: CanonDriver.Margin.allCases.filter { p.variants[$0] != nil }.map(\.rawValue))
            } ?? []
        )
    }
}
