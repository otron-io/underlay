import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, MenuControllerDelegate {
    private let settings = Settings.shared
    private var wallpapers: WallpaperController!
    private var tint: TintSync!
    private var rotation: Rotation!
    private var menu: MenuController!
    private var watchers: [URL: FileWatcher] = [:]
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        tint = TintSync(settings: settings)
        if settings.sessionRunning {
            // The previous session crashed or was killed before it could clean up.
            tint.restoreOriginals()
        }
        settings.sessionRunning = true
        tint.captureOriginals()

        wallpapers = WallpaperController(source: settings.sourceURL, displayMode: settings.displayMode)
        wallpapers.overrides = settings.displaySources
        wallpapers.onPageLoad = { [weak self] display in
            // didFinish fires before the first frame is painted.
            self?.tint.sync(display, after: 0.6)
        }
        wallpapers.onRebuild = { [weak self] in
            guard let self else { return }
            tint.captureOriginals()
            tint.restoreOriginals(excluding: Set(wallpapers.displays.map(\.displayID)))
            watchSources()
        }
        tint.displays = { [weak self] in self?.wallpapers.displays ?? [] }
        tint.interval = settings.tintSyncInterval
        tint.isEnabled = settings.tintSyncEnabled

        wallpapers.rebuild()
        rotation = Rotation(settings: settings) { [weak self] url in self?.show(url) }
        rotation.reschedule()
        menu = MenuController(settings: settings, rotation: rotation, delegate: self)
        installSignalHandlers()
    }

    func applicationWillTerminate(_ notification: Notification) {
        tint.restoreOriginals()
        settings.sessionRunning = false
    }

    // MARK: MenuControllerDelegate

    func menuDidChooseSource(_ url: URL) {
        show(url)
        // Give a hand-picked wallpaper a full interval before rotating away.
        rotation.reschedule()
    }

    func menuDidChooseSource(_ url: URL?, forDisplay uuid: String) {
        settings.displaySources[uuid] = url
        wallpapers.overrides = settings.displaySources
        watchSources()
    }

    func menuDidRequestReload() {
        wallpapers.reload()
    }

    func menuDidChangeSettings() {
        tint.interval = settings.tintSyncInterval
        tint.isEnabled = settings.tintSyncEnabled
        wallpapers.displayMode = settings.displayMode
    }

    // MARK: Private

    private func show(_ url: URL) {
        settings.sourceURL = url
        wallpapers.source = url
        watchSources()
    }

    /// Keeps one file watcher per local file currently on screen.
    private func watchSources() {
        let shown = Set(wallpapers.displays.compactMap(\.source).filter(\.isFileURL))
        for (url, watcher) in watchers where !shown.contains(url) {
            watcher.stop()
            watchers[url] = nil
        }
        for url in shown where watchers[url] == nil {
            watchers[url] = FileWatcher(fileURL: url) { [weak self] in
                self?.wallpapers.reload(showing: url)
            }
        }
    }

    /// Route SIGTERM/SIGINT/SIGHUP through `terminate` so original wallpapers get restored.
    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated { NSApp.terminate(nil) }
            }
            source.resume()
            signalSources.append(source)
        }
    }
}
