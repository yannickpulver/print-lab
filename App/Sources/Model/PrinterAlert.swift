import Foundation

/// What the printer needs from the person in front of it, if anything.
struct PrinterAlert: Hashable {
    enum Severity { case error, attention }

    let severity: Severity
    let title: String
    let message: String
    let helpURL: URL?
}

extension AppModel {
    var printerAlert: PrinterAlert? {
        if let error = status.remoteUI?.error {
            return PrinterAlert(
                severity: .error,
                title: error.code.map { "Support Code \($0)" } ?? "Printer error",
                message: error.message,
                helpURL: error.helpURL
            )
        }
        if status.state == .stopped {
            let reasons = status.reasons.filter { !$0.hasSuffix("-warning") && !$0.hasSuffix("-report") }
            return PrinterAlert(
                severity: .error,
                title: "Printer stopped",
                message: status.message ?? (reasons.isEmpty ? "Check the printer display." : reasons.joined(separator: ", ")),
                helpURL: nil
            )
        }
        if status.printerJobStopped {
            return PrinterAlert(
                severity: .attention,
                title: "Job paused on the printer",
                message: "The printer stopped the job and waits. Press OK on the printer to continue, or cancel the job.",
                helpURL: nil
            )
        }
        if let job, !job.state.isFinal, status.state == .unknown {
            return PrinterAlert(
                severity: .attention,
                title: "Printer not reachable",
                message: "The job waits in the queue. Check that the printer is on and in the Wi-Fi.",
                helpURL: nil
            )
        }
        return nil
    }
}
