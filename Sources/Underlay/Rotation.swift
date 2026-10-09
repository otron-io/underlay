import Foundation

/// Cycles the wallpaper through `Settings.rotationURLs` on a timer.
@MainActor
final class Rotation: NSObject {
    private let settings: Settings
    private let show: (URL) -> Void
    private var timer: Timer?

    init(settings: Settings, show: @escaping (URL) -> Void) {
        self.settings = settings
        self.show = show
        super.init()
    }

    /// Restarts the countdown, e.g. after settings change or the user picked a wallpaper.
    func reschedule() {
        timer?.invalidate()
        timer = nil
        let interval = settings.rotationInterval
        guard interval > 0, settings.rotationURLs.count > 1 else { return }
        let timer = Timer(timeInterval: interval, target: self, selector: #selector(timerFired), userInfo: nil, repeats: true)
        timer.tolerance = min(interval * 0.1, 30)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Shows the next wallpaper in the rotation, skipping local files that no longer exist.
    func advance() {
        let candidates = settings.rotationURLs.filter { !$0.isFileURL || FileManager.default.fileExists(atPath: $0.path) }
        guard !candidates.isEmpty else { return }
        let current = settings.sourceURL
        let next: URL
        if settings.rotationShuffle {
            next = candidates.filter { $0 != current }.randomElement() ?? candidates[0]
        } else if let current, let index = candidates.firstIndex(of: current) {
            next = candidates[(index + 1) % candidates.count]
        } else {
            next = candidates[0]
        }
        show(next)
        reschedule()
    }

    // MARK: Editing

    /// Adds wallpapers, expanding folders: a folder with an `index.html` counts as one wallpaper,
    /// otherwise its subfolders' `index.html` files and its own `.html` files are added.
    func add(_ urls: [URL]) {
        var list = settings.rotationURLs
        for url in urls.flatMap(Self.wallpapers(in:)) where !list.contains(url) {
            list.append(url)
        }
        settings.rotationURLs = list
        reschedule()
    }

    func remove(_ url: URL) {
        settings.rotationURLs.removeAll { $0 == url }
        reschedule()
    }

    func clear() {
        settings.rotationURLs = []
        reschedule()
    }

    @objc private func timerFired() {
        advance()
    }

    private static func wallpapers(in url: URL) -> [URL] {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard url.isFileURL, fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return [url]
        }
        let index = url.appendingPathComponent("index.html")
        if fm.fileExists(atPath: index.path) { return [index.standardizedFileURL] }

        let children = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)) ?? []
        return children
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .compactMap { child in
                if (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    let index = child.appendingPathComponent("index.html")
                    return fm.fileExists(atPath: index.path) ? index.standardizedFileURL : nil
                }
                return ["html", "htm"].contains(child.pathExtension.lowercased()) ? child.standardizedFileURL : nil
            }
    }
}
