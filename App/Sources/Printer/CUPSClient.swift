import CUPS
import Foundation

/// A CUPS queue that uses Canon's IJ driver.
struct PrinterQueue: Identifiable, Hashable, Sendable {
    let name: String
    let info: String
    let deviceURI: String
    let ppdURL: URL

    var id: String { name }

    /// Host of a network printer, nil for USB.
    var host: String? {
        guard let url = URL(string: deviceURI), ["ipp", "ipps", "http", "https"].contains(url.scheme ?? "") else {
            return nil
        }
        return url.host
    }
}

struct PrinterStatus: Hashable, Sendable {
    struct Marker: Hashable, Sendable, Identifiable {
        let name: String
        /// 0...100, nil if unknown.
        let level: Int?
        /// "#RRGGBB" from the printer.
        let color: String?
        var id: String { name }
    }

    enum State: String, Sendable {
        case idle, processing, stopped, unknown
    }

    var state: State = .unknown
    var reasons: [String] = []
    var message: String?
    var markers: [Marker] = []
    /// The printer holds a job it has stopped, e.g. after a closed tray. It waits for OK on its panel.
    var printerJobStopped = false
    /// Support code, message and Wi-Fi from the printer's web page.
    var remoteUI: RemoteUIStatus?
}

enum JobState: Hashable, Sendable {
    case pending, held, processing, stopped, canceled, aborted, completed, unknown

    var isFinal: Bool { [.canceled, .aborted, .completed].contains(self) }
}

enum CUPSError: LocalizedError {
    case submitFailed(String)

    var errorDescription: String? {
        switch self {
        case .submitFailed(let message): "The print job could not be sent: \(message)"
        }
    }
}

/// Thin wrapper around libcups.
enum CUPSClient {
    /// Queues whose PPD comes from Canon's IJ driver (it has a `CNIJMediaType` option).
    static func canonQueues() -> [PrinterQueue] {
        var dests: UnsafeMutablePointer<cups_dest_t>?
        let count = cupsGetDests(&dests)
        defer { cupsFreeDests(count, dests) }
        guard let dests else { return [] }

        var result: [PrinterQueue] = []
        for i in 0..<Int(count) {
            let dest = dests[i]
            guard dest.instance == nil else { continue }
            let name = String(cString: dest.name)
            let uri = cupsGetOption("device-uri", dest.num_options, dest.options).map { String(cString: $0) } ?? ""
            let info = cupsGetOption("printer-info", dest.num_options, dest.options).map { String(cString: $0) } ?? name
            let ppd = URL(fileURLWithPath: "/etc/cups/ppd/\(name).ppd")
            guard let head = try? String(contentsOf: ppd, encoding: .utf8), head.contains("*OpenUI *CNIJMediaType") else {
                continue
            }
            result.append(PrinterQueue(name: name, info: info, deviceURI: uri, ppdURL: ppd))
        }
        return result
    }

    /// Asks the printer itself for state and ink levels. USB queues fall back to the values CUPS cached.
    static func status(of queue: PrinterQueue) -> PrinterStatus {
        let host = queue.host
        let http: OpaquePointer?
        let printerURI: String
        let resource: String
        if let host, let url = URL(string: queue.deviceURI) {
            http = httpConnect2(host, Int32(url.port ?? 631), nil, AF_UNSPEC, HTTP_ENCRYPTION_IF_REQUESTED, 1, 5000, nil)
            printerURI = queue.deviceURI
            resource = url.path.isEmpty ? "/ipp/print" : url.path
        } else {
            http = nil
            printerURI = "ipp://localhost/printers/\(queue.name)"
            resource = "/printers/\(queue.name)"
        }
        defer { if let http { httpClose(http) } }

        let request = ippNewRequest(IPP_OP_GET_PRINTER_ATTRIBUTES)
        ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_URI, "printer-uri", nil, printerURI)
        guard let response = cupsDoRequest(http, request, resource) else { return PrinterStatus() }
        defer { ippDelete(response) }

        var status = PrinterStatus()
        if let attr = ippFindAttribute(response, "printer-state", IPP_TAG_ENUM) {
            switch ipp_pstate_t(UInt32(ippGetInteger(attr, 0))) {
            case IPP_PSTATE_IDLE: status.state = .idle
            case IPP_PSTATE_PROCESSING: status.state = .processing
            case IPP_PSTATE_STOPPED: status.state = .stopped
            default: status.state = .unknown
            }
        }
        status.reasons = strings(response, "printer-state-reasons").filter { $0 != "none" }
        status.message = strings(response, "printer-state-message").first.flatMap { $0.isEmpty ? nil : $0 }
        let names = strings(response, "marker-names")
        let levels = integers(response, "marker-levels")
        let colors = strings(response, "marker-colors")
        status.markers = names.enumerated().map { i, name in
            PrinterStatus.Marker(
                name: name,
                level: i < levels.count && levels[i] >= 0 ? levels[i] : nil,
                color: i < colors.count ? colors[i] : nil
            )
        }
        if host != nil {
            status.printerJobStopped = activeJobStates(http: http, printerURI: printerURI, resource: resource)
                .contains(IPP_JSTATE_STOPPED)
        }
        return status
    }

    /// States of the jobs the printer itself is working on.
    private static func activeJobStates(http: OpaquePointer?, printerURI: String, resource: String) -> [ipp_jstate_t] {
        let request = ippNewRequest(IPP_OP_GET_JOBS)
        ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_URI, "printer-uri", nil, printerURI)
        ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_KEYWORD, "requested-attributes", nil, "job-state")
        guard let response = cupsDoRequest(http, request, resource) else { return [] }
        defer { ippDelete(response) }
        var states: [ipp_jstate_t] = []
        var attr = ippFirstAttribute(response)
        while let current = attr {
            if let name = ippGetName(current), String(cString: name) == "job-state" {
                states.append(ipp_jstate_t(UInt32(ippGetInteger(current, 0))))
            }
            attr = ippNextAttribute(response)
        }
        return states
    }

    /// Sends a file to a queue and returns the job id.
    static func submit(file: URL, title: String, queue: String, options: [String: String]) throws -> Int32 {
        var cupsOptions: UnsafeMutablePointer<cups_option_t>?
        var count: Int32 = 0
        for (key, value) in options {
            count = cupsAddOption(key, value, count, &cupsOptions)
        }
        defer { cupsFreeOptions(count, cupsOptions) }
        let id = cupsPrintFile(queue, file.path, title, count, cupsOptions)
        guard id > 0 else { throw CUPSError.submitFailed(String(cString: cupsLastErrorString())) }
        return id
    }

    static func jobState(id: Int32, queue: String) -> JobState {
        var jobs: UnsafeMutablePointer<cups_job_t>?
        let count = cupsGetJobs(&jobs, queue, 0, CUPS_WHICHJOBS_ALL)
        defer { cupsFreeJobs(count, jobs) }
        guard let jobs else { return .unknown }
        for i in 0..<Int(count) where jobs[i].id == id {
            switch jobs[i].state {
            case IPP_JSTATE_PENDING: return .pending
            case IPP_JSTATE_HELD: return .held
            case IPP_JSTATE_PROCESSING: return .processing
            case IPP_JSTATE_STOPPED: return .stopped
            case IPP_JSTATE_CANCELED: return .canceled
            case IPP_JSTATE_ABORTED: return .aborted
            case IPP_JSTATE_COMPLETED: return .completed
            default: return .unknown
            }
        }
        return .unknown
    }

    static func cancel(job id: Int32, queue: String) {
        cupsCancelJob(queue, id)
    }

    private static func strings(_ response: OpaquePointer, _ name: String) -> [String] {
        guard let attr = ippFindAttribute(response, name, IPP_TAG_ZERO) else { return [] }
        return (0..<ippGetCount(attr)).compactMap { i in
            ippGetString(attr, i, nil).map { String(cString: $0) }
        }
    }

    private static func integers(_ response: OpaquePointer, _ name: String) -> [Int] {
        guard let attr = ippFindAttribute(response, name, IPP_TAG_ZERO) else { return [] }
        return (0..<ippGetCount(attr)).map { Int(ippGetInteger(attr, $0)) }
    }
}
