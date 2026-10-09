import AppKit
import UniformTypeIdentifiers
import WebKit

/// Mirrors each wallpaper window into the real desktop picture.
///
/// The menu bar's translucency samples the desktop picture, not the windows beneath it, so
/// without this the menu bar would be tinted by whatever wallpaper was set before Underlay.
@MainActor
final class TintSync: NSObject {
    /// Supplies the wallpapers to snapshot.
    var displays: () -> [DisplayWallpaper] = { [] }

    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            if isEnabled {
                syncAll()
            } else {
                restoreOriginals()
            }
            scheduleTimer()
        }
    }

    /// Seconds between periodic refreshes; 0 means only on load, screen and Space changes.
    var interval: TimeInterval = 5 {
        didSet { if interval != oldValue { scheduleTimer() } }
    }

    private let settings: Settings
    private let directory: URL
    private var timer: Timer?
    private var screensAsleep = false
    /// Pixel hash of the image last set per display, to skip unchanged frames.
    private var fingerprints: [CGDirectDisplayID: Int] = [:]
    private var inFlight: Set<CGDirectDisplayID> = []
    private var needsResync: Set<CGDirectDisplayID> = []
    /// Displays whose original picture was already recorded this session.
    private var captured: Set<CGDirectDisplayID> = []

    init(settings: Settings) {
        self.settings = settings
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = support.appendingPathComponent("Underlay/Tint", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        super.init()

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(activeSpaceDidChange), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(screensDidSleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(screensDidWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
    }

    // MARK: Syncing

    func syncAll() {
        displays().forEach { sync($0) }
    }

    func sync(_ display: DisplayWallpaper, after delay: TimeInterval = 0) {
        guard isEnabled else { return }
        let id = display.displayID
        guard !inFlight.contains(id) else {
            needsResync.insert(id)
            return
        }
        inFlight.insert(id)
        Task { [weak self, weak display] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            if let self, let display {
                await self.capture(display)
            }
            guard let self else { return }
            self.inFlight.remove(id)
            if self.needsResync.remove(id) != nil, let display, !display.isClosed {
                self.sync(display)
            }
        }
    }

    private func capture(_ display: DisplayWallpaper) async {
        guard isEnabled, !display.isClosed else { return }
        let config = WKSnapshotConfiguration()
        config.rect = display.webView.bounds
        guard let image = try? await display.webView.takeSnapshot(configuration: config),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return }

        let scale = display.screen.backingScaleFactor
        let width = Int(display.screen.frame.width * scale)
        let height = Int(display.screen.frame.height * scale)
        let previous = fingerprints[display.displayID]
        let rendered = await Task.detached(priority: .utility) {
            Self.renderPNG(cgImage, width: width, height: height, unlessFingerprint: previous)
        }.value

        guard isEnabled, !display.isClosed, let rendered, let png = rendered.png else { return }
        apply(png, fingerprint: rendered.fingerprint, to: display.displayID)
    }

    private func apply(_ png: Data, fingerprint: Int, to displayID: CGDirectDisplayID) {
        guard let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) else { return }
        captureOriginal(of: screen)

        // macOS caches desktop pictures by URL, so every frame needs a fresh filename.
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let url = directory.appendingPathComponent("tint-\(displayID)-\(stamp).png")
        do {
            try png.write(to: url, options: .atomic)
            try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [
                .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
                .allowClipping: true,
            ])
            fingerprints[displayID] = fingerprint
            removeTintFiles(for: displayID, keeping: url)
        } catch {
            NSLog("Underlay: couldn't set desktop picture: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Draws `image` at exactly `width`×`height` pixels and encodes it as PNG, skipping the
    /// (expensive) encode when the pixels hash to `unlessFingerprint`.
    nonisolated private static func renderPNG(
        _ image: CGImage, width: Int, height: Int, unlessFingerprint previous: Int?
    ) -> (fingerprint: Int, png: Data?)? {
        let colorSpace = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard width > 0, height > 0,
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ),
              let pixels = context.data
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var hasher = Hasher()
        hasher.combine(bytes: UnsafeRawBufferPointer(start: pixels, count: context.bytesPerRow * height))
        let fingerprint = hasher.finalize()
        if fingerprint == previous { return (fingerprint, nil) }

        guard let frame = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, frame, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (fingerprint, data as Data)
    }

    // MARK: Original wallpapers

    func captureOriginals(of screens: [NSScreen] = NSScreen.screens) {
        screens.forEach(captureOriginal(of:))
    }

    private func captureOriginal(of screen: NSScreen) {
        let id = screen.displayID
        guard !captured.contains(id) else { return }
        captured.insert(id)
        // After a crash the current picture is one of ours; keep the previously saved original.
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen), !isTintFile(url) else { return }
        let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
        settings.originalWallpapers[String(id)] = SavedWallpaper(
            url: url,
            scaling: (options[.imageScaling] as? NSNumber)?.uintValue,
            allowClipping: (options[.allowClipping] as? NSNumber)?.boolValue
        )
    }

    /// Puts back the original picture on every screen currently showing an Underlay snapshot.
    /// Screens whose picture the user changed in the meantime are left alone.
    func restoreOriginals(excluding keep: Set<CGDirectDisplayID> = []) {
        let saved = settings.originalWallpapers
        for screen in NSScreen.screens where !keep.contains(screen.displayID) {
            let id = screen.displayID
            captured.remove(id)
            fingerprints[id] = nil
            guard let current = NSWorkspace.shared.desktopImageURL(for: screen), isTintFile(current),
                  let original = saved[String(id)]
            else { continue }

            var options: [NSWorkspace.DesktopImageOptionKey: Any] = [:]
            if let scaling = original.scaling { options[.imageScaling] = scaling }
            if let allowClipping = original.allowClipping { options[.allowClipping] = allowClipping }
            do {
                try NSWorkspace.shared.setDesktopImageURL(original.url, for: screen, options: options)
            } catch {
                NSLog("Underlay: couldn't restore desktop picture \(original.url.path): \(error.localizedDescription)")
            }
        }
    }

    // MARK: Files

    private func isTintFile(_ url: URL) -> Bool {
        url.isFileURL && url.standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path + "/")
    }

    private func removeTintFiles(for displayID: CGDirectDisplayID, keeping kept: URL) {
        let prefix = "tint-\(displayID)-"
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix(prefix) && file.lastPathComponent != kept.lastPathComponent {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: Timer and system events

    private func scheduleTimer() {
        timer?.invalidate()
        timer = nil
        guard isEnabled, interval > 0, !screensAsleep else { return }
        let timer = Timer(timeInterval: interval, target: self, selector: #selector(timerFired), userInfo: nil, repeats: true)
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    @objc private func timerFired() {
        syncAll()
    }

    @objc private func activeSpaceDidChange(_ note: Notification) {
        // Desktop pictures are per Space; the new one hasn't seen our latest frame.
        fingerprints.removeAll()
        syncAll()
    }

    @objc private func screensDidSleep(_ note: Notification) {
        screensAsleep = true
        scheduleTimer()
    }

    @objc private func screensDidWake(_ note: Notification) {
        screensAsleep = false
        scheduleTimer()
        syncAll()
    }
}
