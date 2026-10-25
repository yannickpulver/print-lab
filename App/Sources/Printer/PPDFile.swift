import CoreGraphics
import Foundation

/// Minimal reader for CUPS PPD files: UI options, page sizes, constraints and ICC profiles.
/// Localized entries (`*de.Key`) and comments are ignored.
struct PPDFile: Sendable {
    struct Choice: Hashable, Sendable {
        let key: String
        let label: String
    }

    struct Option: Sendable {
        let keyword: String
        let label: String
        var choices: [Choice]
        var defaultChoice: String?

        func label(for key: String) -> String? {
            choices.first { $0.key == key }?.label
        }
    }

    struct PageSize: Hashable, Sendable {
        let name: String
        let label: String
        /// Paper size in points.
        let size: CGSize
        /// Printable area in points, PostScript coordinates (origin bottom-left).
        let imageableArea: CGRect
    }

    /// `*UIConstraints: *Key1 Choice1 *Key2 Choice2`. A missing choice means "any value except off".
    struct Constraint: Hashable, Sendable {
        let key1: String
        let choice1: String?
        let key2: String
        let choice2: String?
    }

    struct Entry: Sendable {
        let keyword: String
        let option: String?
        let translation: String?
        let value: String
    }

    private(set) var nickName = ""
    private(set) var options: [String: Option] = [:]
    private(set) var pageSizes: [PageSize] = []
    private(set) var constraints: [Constraint] = []
    /// `*cupsICCProfile` entries: translation (usually the file name) → absolute path.
    private(set) var iccProfiles: [String: String] = [:]
    private(set) var entries: [Entry] = []

    init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url)
        let text = String(decoding: data, as: UTF8.self)
        self.init(text: text)
    }

    init(text: String) {
        entries = Self.parseEntries(text)
        build()
    }

    func option(_ keyword: String) -> Option? { options[keyword] }

    func defaultChoice(_ keyword: String) -> String? { options[keyword]?.defaultChoice }

    /// Constraints violated by the given selection (keyword → choice key).
    func conflicts(in selection: [String: String]) -> [Constraint] {
        constraints.filter { c in
            Self.matches(selection[c.key1], c.choice1) && Self.matches(selection[c.key2], c.choice2)
        }
    }

    private static func matches(_ selected: String?, _ required: String?) -> Bool {
        guard let selected else { return false }
        if let required { return selected == required }
        return !["None", "False", "Off", "OFF", "0"].contains(selected)
    }

    // MARK: - Parsing

    private static func parseEntries(_ text: String) -> [Entry] {
        var result: [Entry] = []
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).makeIterator()
        while let raw = lines.next() {
            let line = String(raw)
            guard line.hasPrefix("*"), !line.hasPrefix("*%"), let colon = line.firstIndex(of: ":") else { continue }
            let head = line[line.index(after: line.startIndex)..<colon]
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            // Quoted values may span several lines.
            if value.hasPrefix("\""), value.filter({ $0 == "\"" }).count % 2 == 1 {
                while let next = lines.next() {
                    value += "\n" + next
                    if next.contains("\"") { break }
                }
            }
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }

            let keyword: String
            var option: String?
            var translation: String?
            if let space = head.firstIndex(where: { $0 == " " || $0 == "\t" }) {
                keyword = String(head[..<space])
                let spec = head[head.index(after: space)...].trimmingCharacters(in: .whitespaces)
                if let slash = spec.firstIndex(of: "/") {
                    option = String(spec[..<slash])
                    translation = String(spec[spec.index(after: slash)...])
                } else {
                    option = spec
                }
            } else {
                keyword = String(head)
            }
            // Skip localized entries such as "*de.CNIJMediaType".
            if keyword.contains(".") { continue }
            result.append(Entry(keyword: keyword, option: option, translation: translation, value: value))
        }
        return result
    }

    private mutating func build() {
        var openUI: [(keyword: String, label: String)] = []
        for e in entries where e.keyword == "OpenUI" {
            guard let opt = e.option else { continue }
            let keyword = opt.hasPrefix("*") ? String(opt.dropFirst()) : opt
            openUI.append((keyword, e.translation ?? keyword))
        }
        for (keyword, label) in openUI {
            options[keyword] = Option(keyword: keyword, label: label, choices: [], defaultChoice: nil)
        }

        var dimensions: [String: CGSize] = [:]
        var imageable: [String: CGRect] = [:]

        for e in entries {
            switch e.keyword {
            case "NickName":
                nickName = e.value
            case "PaperDimension":
                if let name = e.option, let n = Self.numbers(e.value), n.count == 2 {
                    dimensions[name] = CGSize(width: n[0], height: n[1])
                }
            case "ImageableArea":
                if let name = e.option, let n = Self.numbers(e.value), n.count == 4 {
                    imageable[name] = CGRect(x: n[0], y: n[1], width: n[2] - n[0], height: n[3] - n[1])
                }
            case "UIConstraints":
                if let c = Self.parseConstraint(e.value) { constraints.append(c) }
            case "cupsICCProfile":
                if let name = e.translation { iccProfiles[name] = e.value }
            default:
                if e.keyword.hasPrefix("Default"), e.option == nil {
                    let keyword = String(e.keyword.dropFirst("Default".count))
                    options[keyword]?.defaultChoice = e.value
                } else if let opt = e.option, options[e.keyword] != nil {
                    options[e.keyword]?.choices.append(Choice(key: opt, label: e.translation ?? opt))
                }
            }
        }

        pageSizes = (options["PageSize"]?.choices ?? []).compactMap { choice in
            guard let size = dimensions[choice.key] else { return nil }
            let area = imageable[choice.key] ?? CGRect(origin: .zero, size: size)
            return PageSize(name: choice.key, label: choice.label, size: size, imageableArea: area)
        }
    }

    private static func numbers(_ value: String) -> [CGFloat]? {
        let parts = value.split(whereSeparator: \.isWhitespace).compactMap { Double($0) }
        return parts.isEmpty ? nil : parts.map { CGFloat($0) }
    }

    private static func parseConstraint(_ value: String) -> Constraint? {
        let tokens = value.split(whereSeparator: \.isWhitespace).map(String.init)
        var groups: [(String, String?)] = []
        for token in tokens {
            if token.hasPrefix("*") {
                groups.append((String(token.dropFirst()), nil))
            } else if !groups.isEmpty, groups[groups.count - 1].1 == nil {
                groups[groups.count - 1].1 = token
            }
        }
        guard groups.count == 2 else { return nil }
        return Constraint(key1: groups[0].0, choice1: groups[0].1, key2: groups[1].0, choice2: groups[1].1)
    }
}
