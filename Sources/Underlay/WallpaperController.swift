import AppKit
import WebKit

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    /// Stable across reboots and reconnects, unlike `displayID`.
    var displayUUID: String {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else {
            return String(displayID)
        }
        return CFUUIDCreateString(nil, uuid) as String
    }
}

/// Owns one wallpaper window per screen and rebuilds them when the display setup changes.
@MainActor
final class WallpaperController: NSObject {
    private(set) var displays: [DisplayWallpaper] = []

    /// The wallpaper for displays without an override.
    var source: URL? {
        didSet { refresh() }
    }

    /// Per-display wallpapers keyed by display UUID.
    var overrides: [String: URL] = [:] {
        didSet { refresh() }
    }

    var displayMode: DisplayMode {
        didSet { if displayMode != oldValue { rebuild() } }
    }

    /// Called after a page (or the fallback page) finishes loading on a display.
    var onPageLoad: ((DisplayWallpaper) -> Void)?
    /// Called after windows have been recreated.
    var onRebuild: (() -> Void)?

    private var screenSignature: [String] = []

    init(source: URL?, displayMode: DisplayMode) {
        self.source = source
        self.displayMode = displayMode
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    func rebuild() {
        displays.forEach { $0.close() }
        screenSignature = Self.currentScreenSignature()

        let all = NSScreen.screens
        // The first screen is the one with the menu bar.
        let screens = displayMode == .main ? Array(all.prefix(1)) : all
        displays = screens.enumerated().map { index, screen in
            let display = DisplayWallpaper(screen: screen, index: index)
            display.onLoad = { [weak self] in self?.onPageLoad?($0) }
            display.load(source(for: display))
            return display
        }
        onRebuild?()
    }

    func source(for display: DisplayWallpaper) -> URL? {
        overrides[display.uuid] ?? source
    }

    /// Reloads every display.
    func reload() {
        displays.forEach { $0.load(source(for: $0)) }
    }

    /// Reloads the displays currently showing `url`.
    func reload(showing url: URL) {
        for display in displays where display.source == url {
            display.load(url)
        }
    }

    /// Loads displays whose wallpaper changed, leaving the others running undisturbed.
    private func refresh() {
        for display in displays where display.source != source(for: display) {
            display.load(source(for: display))
        }
    }

    @objc private func screenParametersDidChange(_ note: Notification) {
        // This also fires for changes that don't affect us (e.g. Dock or menu bar auto-hide).
        guard Self.currentScreenSignature() != screenSignature else { return }
        rebuild()
    }

    private static func currentScreenSignature() -> [String] {
        NSScreen.screens.map { "\($0.displayID) \(NSStringFromRect($0.frame)) \($0.backingScaleFactor)" }
    }
}

/// A borderless desktop-level window hosting a web view for a single screen.
@MainActor
final class DisplayWallpaper: NSObject, WKNavigationDelegate {
    let screen: NSScreen
    let index: Int
    let displayID: CGDirectDisplayID
    let uuid: String
    let window: NSWindow
    let webView: WKWebView
    var onLoad: ((DisplayWallpaper) -> Void)?
    private(set) var isClosed = false
    private(set) var source: URL?

    init(screen: NSScreen, index: Int) {
        self.screen = screen
        self.index = index
        displayID = screen.displayID
        uuid = screen.displayUUID

        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        // Lets local pages fetch() sibling files (JSON, shaders, ...).
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        webView = WKWebView(frame: NSRect(origin: .zero, size: screen.frame.size), configuration: config)
        webView.autoresizingMask = [.width, .height]
        // Transparent until the page paints, so reloads don't flash white.
        webView.setValue(false, forKey: "drawsBackground")
        // Pages often fit a fixed-size design to the screen with `transform: scale()`. WebKit
        // rasterizes such layers at their unscaled size, so on 1x displays they get stretched and
        // blurry. Rendering at 2x and letting the window server downsample keeps them sharp.
        if screen.backingScaleFactor < 2,
           webView.responds(to: NSSelectorFromString("_setOverrideDeviceScaleFactor:")) {
            webView.setValue(2.0, forKey: "overrideDeviceScaleFactor")
        }

        window = WallpaperWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = webView
        window.setFrame(screen.frame, display: false)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none

        super.init()
        webView.navigationDelegate = self
        window.orderFrontRegardless()
    }

    func load(_ source: URL?) {
        self.source = source
        guard let source else {
            showFallback(title: "No wallpaper selected", detail: "Choose “Open HTML File…” from the Underlay menu.")
            return
        }
        let target = urlWithScreenInfo(source)
        if source.isFileURL {
            guard FileManager.default.fileExists(atPath: source.path) else {
                showFallback(title: "File not found", detail: source.path)
                return
            }
            webView.loadFileURL(target, allowingReadAccessTo: source.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: target))
        }
    }

    func close() {
        isClosed = true
        onLoad = nil
        webView.navigationDelegate = nil
        webView.stopLoading()
        window.orderOut(nil)
        window.close()
    }

    /// Appends `screen`, `width` and `height` (in points) so pages can vary per display.
    private func urlWithScreenInfo(_ url: URL) -> URL {
        guard var components = URLComponents(url: url.absoluteURL, resolvingAgainstBaseURL: true) else { return url }
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "screen", value: String(index)))
        items.append(URLQueryItem(name: "width", value: String(Int(screen.frame.width))))
        items.append(URLQueryItem(name: "height", value: String(Int(screen.frame.height))))
        components.queryItems = items
        return components.url ?? url
    }

    private func showFallback(title: String, detail: String) {
        webView.loadHTMLString(FallbackPage.html(title: title, detail: detail), baseURL: nil)
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onLoad?(self)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handle(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handle(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        load(source)
    }

    private func handle(_ error: Error) {
        // Cancellation happens whenever a reload interrupts an in-flight load.
        if (error as NSError).code == NSURLErrorCancelled { return }
        showFallback(title: "Couldn’t load wallpaper", detail: error.localizedDescription)
    }
}

private final class WallpaperWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // Keep the window over the menu bar and notch area instead of being pushed below them.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

private enum FallbackPage {
    static func html(title: String, detail: String) -> String {
        """
        <!doctype html>
        <html><head><meta charset="utf-8"><style>
          html, body { margin: 0; height: 100%; }
          body {
            display: flex; align-items: center; justify-content: center;
            background: radial-gradient(circle at 30% 20%, #2b2f45, #12131a 70%);
            color: #e8e9f0; font: 15px/1.5 -apple-system, sans-serif; text-align: center;
          }
          h1 { font-weight: 500; font-size: 22px; margin: 0 0 8px; }
          p { margin: 0; opacity: .6; max-width: 640px; word-break: break-word; }
        </style></head><body><div>
          <h1>\(escape(title))</h1>
          <p>\(escape(detail))</p>
        </div></body></html>
        """
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
