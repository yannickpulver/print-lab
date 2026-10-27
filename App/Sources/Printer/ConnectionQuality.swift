import Foundation

/// How steady the network link to the printer is. Canon's driver sends a lot of data for a photo print.
/// On a weak link the printer waits for it between passes, and a print takes much longer.
///
/// The thresholds are a first guess, to be tuned with real printers.
struct ConnectionQuality: Hashable, Sendable {
    enum Rating: String, Sendable {
        case good, fair, poor
    }

    /// One status request to the printer.
    struct Check: Hashable, Sendable {
        let answered: Bool
        let seconds: Double
    }

    /// How many recent checks the rating looks at.
    static let window = 10

    let rating: Rating
    /// Wi-Fi values from the printer in percent. Nil on a cable or when the web page gives none.
    let signal: Int?
    let linkQuality: Int?
    let checks: Int
    let answered: Int
    /// Mean answer time of the answered checks.
    let averageSeconds: Double
    /// What pulls the rating down, the worst first. Lowercase, to follow a colon.
    let causes: [String]
    /// What helps, the most effective first. Empty when the rating is good.
    let fixes: [String]

    /// Nil before the first check and while the last check got no answer: then the printer is off or gone,
    /// which the printer alert already says.
    init?(signal: Int?, linkQuality: Int?, checks: [Check]) {
        let recent = checks.suffix(Self.window)
        guard recent.last?.answered == true else { return nil }
        let answered = recent.filter(\.answered)
        let average = answered.map(\.seconds).reduce(0, +) / Double(answered.count)
        let missed = recent.count - answered.count

        // Assumed: Canon reports 0 for both values when the printer is on a cable.
        let onWiFi = (signal ?? 0) > 0 || (linkQuality ?? 0) > 0
        let wifiSignal = onWiFi ? signal : nil
        let wifiLink = onWiFi ? linkQuality : nil

        var poor: [String] = []
        var fair: [String] = []
        func add(_ cause: String, poorIf isPoor: Bool) {
            if isPoor { poor.append(cause) } else { fair.append(cause) }
        }
        if let signal = wifiSignal, signal < 60 {
            add("weak Wi-Fi signal (\(signal) %)", poorIf: signal < 40)
        }
        if let linkQuality = wifiLink, linkQuality < 70 {
            add("low Wi-Fi link quality (\(linkQuality) %)", poorIf: linkQuality < 50)
        }
        if missed > 0 {
            add("\(missed) of the last \(recent.count) status checks got no answer", poorIf: missed >= 2)
        }
        if average > 1.5 {
            add(String(format: "slow answers from the printer (%.1f s)", average), poorIf: false)
        }

        let weakSignal = (wifiSignal ?? 100) < 60
        let lowLink = (wifiLink ?? 100) < 70
        let unsteady = missed > 0 || average > 1.5
        var fixes: [String] = []
        if !poor.isEmpty || !fair.isEmpty {
            fixes.append("Connect the printer with a network cable or USB, if it has the port. That skips Wi-Fi.")
            if weakSignal {
                fixes.append("Bring the printer and the router closer, or put a mesh node or repeater near the printer.")
            }
            if lowLink && !weakSignal {
                fixes.append("A good signal with low link quality points to a crowded channel. "
                    + "Set the router to a fixed, less used channel (on 2.4 GHz: 1, 6 or 11).")
            }
            if unsteady && !weakSignal && !lowLink {
                fixes.append("The printer's Wi-Fi looks fine, so the Mac's connection may be the weak part. "
                    + "Try the Mac closer to the router or on a cable.")
            }
        }

        self.rating = !poor.isEmpty ? .poor : !fair.isEmpty ? .fair : .good
        self.signal = wifiSignal
        self.linkQuality = wifiLink
        self.checks = recent.count
        self.answered = answered.count
        self.averageSeconds = average
        self.causes = poor + fair
        self.fixes = fixes
    }

    var label: String {
        switch rating {
        case .good: "Good"
        case .fair: "Fair"
        case .poor: "Poor"
        }
    }

    /// The numbers behind the rating, for a tooltip.
    var details: String {
        var parts: [String] = []
        if let signal { parts.append("Signal \(signal) %") }
        if let linkQuality { parts.append("Link quality \(linkQuality) %") }
        parts.append("\(answered) of \(checks) checks answered")
        parts.append(String(format: "%.1f s per answer", averageSeconds))
        return parts.joined(separator: " · ")
    }
}
