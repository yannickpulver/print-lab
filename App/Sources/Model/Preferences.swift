import Foundation

/// Named set of settings to reuse, e.g. "A3 Baryta, 2×2".
struct Preset: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var print: PrintSettings
    var layout: LayoutSpec
    var orientation: Orientation
    var color: ColorSettings
}

/// Last used settings and presets in UserDefaults.
@MainActor
enum Preferences {
    private static let defaults = UserDefaults.standard

    static var queueName: String? {
        get { defaults.string(forKey: "queueName") }
        set { defaults.set(newValue, forKey: "queueName") }
    }

    static var printSettings: PrintSettings? {
        get { value("printSettings") }
        set { store(newValue, "printSettings") }
    }

    static var layout: LayoutSpec? {
        get { value("layout") }
        set { store(newValue, "layout") }
    }

    static var orientation: Orientation? {
        get { value("orientation") }
        set { store(newValue, "orientation") }
    }

    static var color: ColorSettings? {
        get { value("color") }
        set { store(newValue, "color") }
    }

    static var presets: [Preset] {
        get { value("presets") ?? [] }
        set { store(newValue, "presets") }
    }

    private static func value<T: Decodable>(_ key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func store<T: Encodable>(_ value: T?, _ key: String) {
        guard let value, let data = try? JSONEncoder().encode(value) else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(data, forKey: key)
    }
}
