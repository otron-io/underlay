import AppKit

@main
enum UnderlayApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Menu bar only, even when run via `swift run` without an Info.plist.
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
