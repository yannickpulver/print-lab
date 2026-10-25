import Foundation

/// Error details from the printer's built-in web page ("Remote UI"). IPP only reports "other-error";
/// the web page knows the support code and Canon's message for it.
///
/// `JS_MDL/model.js` holds the live state as JavaScript variables:
/// `g_bst_st` (≠ "0": error), `g_prndoc` (support code as decimal, shown in hex), `g_err_msg_id`
/// (key into `rui/JS_TBL/table_error.js`, which points to a text in `LANG/messID.js`), `g_err_url` (Canon help).
struct RemoteUIStatus: Hashable, Sendable {
    struct PrinterError: Hashable, Sendable {
        /// Canon support code, e.g. "1250". Nil when the printer gives none.
        let code: String?
        let message: String
        let helpURL: URL?
    }

    var error: PrinterError?
    /// Wi-Fi signal strength and link quality in percent.
    var signal: Int?
    var linkQuality: Int?

    /// Hints for codes where the printer only says "Operator error has occurred."
    static let hints: [String: String] = [
        "1250": "The paper output tray is closed. Open the output tray.",
    ]

    /// Parses model.js. `messages` maps `g_err_msg_id` keys to text.
    static func parse(modelJS: String, messages: [String: String]) -> RemoteUIStatus {
        let vars = variables(in: modelJS)
        var status = RemoteUIStatus()
        status.signal = vars["g_signal_strength"].flatMap { Int($0) }
        status.linkQuality = vars["g_link_quality"].flatMap { Int($0) }
        guard let state = vars["g_bst_st"], state != "0" else { return status }

        var code: String?
        if state == "3", let doc = vars["g_prndoc"].flatMap({ Int($0) }) {
            code = String(doc, radix: 16, uppercase: true)
        }
        let key = vars["g_err_msg_id"] ?? ""
        let message = code.flatMap { hints[$0] }
            ?? messages[key].flatMap { $0.isEmpty ? nil : $0 }
            ?? "The printer reports an error. Check the printer display."
        let help = vars["g_err_url"].map { $0.replacingOccurrences(of: "&amp;", with: "&") }.flatMap(URL.init(string:))
        status.error = PrinterError(code: code, message: message, helpURL: help)
        return status
    }

    /// Joins table_error.js (key → message id) with messID.js (message id → text).
    static func messages(errorTable: String, texts: String) -> [String: String] {
        let textByID = Dictionary(
            matches(#"(MES[0-9A-Z]+):\s*"((?:[^"\\]|\\.)*)""#, in: texts).map { ($0[0], $0[1]) },
            uniquingKeysWith: { a, _ in a }
        )
        return Dictionary(
            matches(#"(HTTP_ERR_DISP_[A-Z0-9_]+):\s*new ErrDtlMsg\(\{\s*errmsg:\s*'([A-Z0-9]*)'"#, in: errorTable)
                .map { ($0[0], textByID[$0[1]] ?? "") },
            uniquingKeysWith: { a, _ in a }
        )
    }

    private static func variables(in js: String) -> [String: String] {
        Dictionary(
            matches(#"var (g_[A-Za-z_]+)\s*=\s*'([^']*)'"#, in: js).map { ($0[0], $0[1]) },
            uniquingKeysWith: { a, _ in a }
        )
    }

    private static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).map { match in
            (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
        }
    }
}

/// Loads the Remote UI files. The message table is fetched once per host.
actor RemoteUIClient {
    static let shared = RemoteUIClient()
    private var messageCache: [String: [String: String]] = [:]

    func status(host: String) async -> RemoteUIStatus? {
        guard let model = await fetch(host, "/JS_MDL/model.js") else { return nil }
        if messageCache[host] == nil,
           let table = await fetch(host, "/rui/JS_TBL/table_error.js"),
           let texts = await fetch(host, "/LANG/messID.js") {
            messageCache[host] = RemoteUIStatus.messages(errorTable: table, texts: texts)
        }
        return RemoteUIStatus.parse(modelJS: model, messages: messageCache[host] ?? [:])
    }

    private func fetch(_ host: String, _ path: String) async -> String? {
        guard let url = URL(string: "http://\(host)\(path)") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 4)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
