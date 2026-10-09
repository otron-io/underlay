import Foundation

enum DisplayMode: String {
    case all
    case main
}

/// A desktop picture as it was before Underlay replaced it.
struct SavedWallpaper: Codable {
    var url: URL
    var scaling: UInt?
    var allowClipping: Bool?
}

/// Thin typed wrapper around UserDefaults.
final class Settings {
    static let shared = Settings()

    static let tintIntervals: [TimeInterval] = [0, 2, 5, 15, 60]
    static let rotationIntervals: [TimeInterval] = [0, 60, 300, 600, 1800, 3600]

    private let defaults = UserDefaults.standard

    private enum Key {
        static let source = "sourceURL"
        static let tintEnabled = "tintSyncEnabled"
        static let tintInterval = "tintSyncInterval"
        static let displayMode = "displayMode"
        static let originals = "originalWallpapers"
        static let running = "sessionRunning"
        static let rotation = "rotationURLs"
        static let rotationInterval = "rotationInterval"
        static let rotationShuffle = "rotationShuffle"
        static let displaySources = "displaySources"
    }

    private init() {
        defaults.register(defaults: [
            Key.tintEnabled: true,
            Key.tintInterval: 5.0,
            Key.rotationInterval: 600.0,
            Key.displayMode: DisplayMode.all.rawValue,
        ])
    }

    /// The page to show. Falls back to the bundled example when unset.
    var sourceURL: URL? {
        get { defaults.string(forKey: Key.source).flatMap(URL.init(string:)) ?? Self.bundledExampleURL() }
        set { defaults.set(newValue?.absoluteString, forKey: Key.source) }
    }

    var tintSyncEnabled: Bool {
        get { defaults.bool(forKey: Key.tintEnabled) }
        set { defaults.set(newValue, forKey: Key.tintEnabled) }
    }

    /// Seconds between periodic tint refreshes; 0 disables the timer.
    var tintSyncInterval: TimeInterval {
        get { defaults.double(forKey: Key.tintInterval) }
        set { defaults.set(newValue, forKey: Key.tintInterval) }
    }

    var displayMode: DisplayMode {
        get { defaults.string(forKey: Key.displayMode).flatMap(DisplayMode.init(rawValue:)) ?? .all }
        set { defaults.set(newValue.rawValue, forKey: Key.displayMode) }
    }

    /// Wallpapers pinned to specific displays, keyed by display UUID. Displays without an entry
    /// show `sourceURL` (and follow the rotation).
    var displaySources: [String: URL] {
        get {
            let raw = defaults.dictionary(forKey: Key.displaySources) as? [String: String] ?? [:]
            return raw.compactMapValues(URL.init(string:))
        }
        set { defaults.set(newValue.mapValues(\.absoluteString), forKey: Key.displaySources) }
    }

    /// Wallpapers to cycle through, in order.
    var rotationURLs: [URL] {
        get { (defaults.stringArray(forKey: Key.rotation) ?? []).compactMap(URL.init(string:)) }
        set { defaults.set(newValue.map(\.absoluteString), forKey: Key.rotation) }
    }

    /// Seconds between rotations; 0 disables rotation.
    var rotationInterval: TimeInterval {
        get { defaults.double(forKey: Key.rotationInterval) }
        set { defaults.set(newValue, forKey: Key.rotationInterval) }
    }

    var rotationShuffle: Bool {
        get { defaults.bool(forKey: Key.rotationShuffle) }
        set { defaults.set(newValue, forKey: Key.rotationShuffle) }
    }

    /// Original desktop pictures keyed by `NSScreenNumber`.
    var originalWallpapers: [String: SavedWallpaper] {
        get {
            guard let data = defaults.data(forKey: Key.originals) else { return [:] }
            return (try? JSONDecoder().decode([String: SavedWallpaper].self, from: data)) ?? [:]
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Key.originals) }
    }

    /// True while the app runs; still set at launch means the last session crashed.
    var sessionRunning: Bool {
        get { defaults.bool(forKey: Key.running) }
        set {
            defaults.set(newValue, forKey: Key.running)
            defaults.synchronize()
        }
    }

    /// A short human name: the folder name for `index.html` files, the filename otherwise, or the host.
    static func displayName(for url: URL) -> String {
        guard url.isFileURL else { return url.host ?? url.absoluteString }
        let name = url.lastPathComponent
        return name.lowercased() == "index.html" ? url.deletingLastPathComponent().lastPathComponent : name
    }

    /// `examples/gradient.html`, from the app bundle or, under `swift run`, the package checkout.
    static func bundledExampleURL() -> URL? {
        let relative = "examples/gradient.html"
        if let resources = Bundle.main.resourceURL {
            let url = resources.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: url.path) { return url.absoluteURL }
        }
        let starts = [
            Bundle.main.bundleURL,
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
        ]
        for start in starts {
            var dir = start
            while dir.path != "/" {
                let url = dir.appendingPathComponent(relative)
                if FileManager.default.fileExists(atPath: url.path) { return url.absoluteURL }
                dir.deleteLastPathComponent()
            }
        }
        return nil
    }
}
