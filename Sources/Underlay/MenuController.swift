import AppKit
import ServiceManagement
import UniformTypeIdentifiers

@MainActor
protocol MenuControllerDelegate: AnyObject {
    func menuDidChooseSource(_ url: URL)
    /// Pins `url` to one display; `nil` makes it follow the other displays again.
    func menuDidChooseSource(_ url: URL?, forDisplay uuid: String)
    func menuDidRequestReload()
    /// Called after the menu wrote a new value to `Settings`.
    func menuDidChangeSettings()
}

/// What a per-display menu item applies: `url` on the display with `uuid` (`nil` = follow).
private struct DisplayChoice {
    let uuid: String
    let url: URL?
}

/// The status item and its menu. The menu is rebuilt every time it opens so it always
/// reflects the current settings.
@MainActor
final class MenuController: NSObject, NSMenuDelegate {
    private weak var delegate: MenuControllerDelegate?
    private let settings: Settings
    private let rotation: Rotation
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

    init(settings: Settings, rotation: Rotation, delegate: MenuControllerDelegate) {
        self.settings = settings
        self.rotation = rotation
        self.delegate = delegate
        super.init()
        statusItem.button?.image = StatusIcon.make()
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let current = NSMenuItem(title: "Showing: \(sourceDescription)", action: nil, keyEquivalent: "")
        current.isEnabled = false
        menu.addItem(current)
        menu.addItem(.separator())

        menu.addItem(item("Open HTML File…", #selector(openFile), key: "o"))
        menu.addItem(item("Open URL…", #selector(openURL), key: "l"))
        menu.addItem(item("Reload", #selector(reload), key: "r"))
        menu.addItem(.separator())

        let rotationItem = NSMenuItem(title: "Rotation", action: nil, keyEquivalent: "")
        rotationItem.submenu = makeRotationMenu()
        menu.addItem(rotationItem)
        let next = item("Next Wallpaper", #selector(nextWallpaper), key: "n")
        next.isEnabled = settings.rotationURLs.count > 1
        menu.addItem(next)
        menu.addItem(.separator())

        let screens = NSScreen.screens
        if screens.count > 1, settings.displayMode == .all {
            let pinned = settings.displaySources
            for screen in screens {
                let uuid = screen.displayUUID
                let name = pinned[uuid].map(Settings.displayName(for:)) ?? "Same as Others"
                let entry = NSMenuItem(title: "\(screen.localizedName): \(name)", action: nil, keyEquivalent: "")
                entry.submenu = makeDisplayMenu(uuid: uuid, pinned: pinned[uuid])
                menu.addItem(entry)
            }
            menu.addItem(.separator())
        }

        let tint = item("Sync Menu Bar Tint", #selector(toggleTintSync))
        tint.state = settings.tintSyncEnabled ? .on : .off
        menu.addItem(tint)

        let intervalMenu = NSMenu()
        intervalMenu.autoenablesItems = false
        for seconds in Settings.tintIntervals {
            let title = seconds == 0 ? "Off" : "Every \(Int(seconds))s"
            let option = item(title, #selector(chooseTintInterval(_:)))
            option.representedObject = seconds
            option.state = settings.tintSyncInterval == seconds ? .on : .off
            intervalMenu.addItem(option)
        }
        let interval = NSMenuItem(title: "Tint Refresh Interval", action: nil, keyEquivalent: "")
        interval.submenu = intervalMenu
        interval.isEnabled = settings.tintSyncEnabled
        menu.addItem(interval)
        menu.addItem(.separator())

        let displayMenu = NSMenu()
        displayMenu.autoenablesItems = false
        for (title, mode) in [("All Displays", DisplayMode.all), ("Main Display Only", DisplayMode.main)] {
            let option = item(title, #selector(chooseDisplayMode(_:)))
            option.representedObject = mode.rawValue
            option.state = settings.displayMode == mode ? .on : .off
            displayMenu.addItem(option)
        }
        let displays = NSMenuItem(title: "Show On", action: nil, keyEquivalent: "")
        displays.submenu = displayMenu
        menu.addItem(displays)

        let login = item("Launch at Login", #selector(toggleLaunchAtLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())

        menu.addItem(item("Quit Underlay", #selector(quit), key: "q"))
    }

    private func makeDisplayMenu(uuid: String, pinned: URL?) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let follow = item("Same as Other Displays", #selector(chooseForDisplay(_:)))
        follow.representedObject = DisplayChoice(uuid: uuid, url: nil)
        follow.state = pinned == nil ? .on : .off
        menu.addItem(follow)
        menu.addItem(.separator())

        // Quick picks: the rotation set, plus the pinned wallpaper if it isn't in it.
        var picks = settings.rotationURLs
        if let pinned, !picks.contains(pinned) { picks.insert(pinned, at: 0) }
        for url in picks {
            let pick = item(Settings.displayName(for: url), #selector(chooseForDisplay(_:)))
            pick.representedObject = DisplayChoice(uuid: uuid, url: url)
            pick.state = url == pinned ? .on : .off
            pick.toolTip = url.isFileURL ? url.path : url.absoluteString
            menu.addItem(pick)
        }
        if !picks.isEmpty { menu.addItem(.separator()) }

        let file = item("Open HTML File…", #selector(openFileForDisplay(_:)))
        file.representedObject = uuid
        menu.addItem(file)
        let url = item("Open URL…", #selector(openURLForDisplay(_:)))
        url.representedObject = uuid
        menu.addItem(url)
        return menu
    }

    private func makeRotationMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let list = settings.rotationURLs
        let current = settings.sourceURL

        if list.isEmpty {
            let empty = NSMenuItem(title: "No Wallpapers in Rotation", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for url in list {
            let entry = item(Settings.displayName(for: url), #selector(showRotationItem(_:)))
            entry.representedObject = url
            entry.state = url == current ? .on : .off
            entry.toolTip = url.isFileURL ? url.path : url.absoluteString
            if url.isFileURL, !FileManager.default.fileExists(atPath: url.path) {
                entry.title += " (missing)"
                entry.isEnabled = false
            }
            menu.addItem(entry)
        }
        menu.addItem(.separator())

        menu.addItem(item("Add Files or Folders…", #selector(addToRotation)))
        let addCurrent = item("Add Current Wallpaper", #selector(addCurrentToRotation))
        addCurrent.isEnabled = current.map { !list.contains($0) } ?? false
        menu.addItem(addCurrent)
        let removeCurrent = item("Remove Current Wallpaper", #selector(removeCurrentFromRotation))
        removeCurrent.isEnabled = current.map(list.contains) ?? false
        menu.addItem(removeCurrent)
        let clear = item("Clear Rotation", #selector(clearRotation))
        clear.isEnabled = !list.isEmpty
        menu.addItem(clear)
        menu.addItem(.separator())

        let intervalMenu = NSMenu()
        intervalMenu.autoenablesItems = false
        for seconds in Settings.rotationIntervals {
            let minutes = Int(seconds / 60)
            let title = seconds == 0 ? "Off" : minutes == 60 ? "Every Hour" : minutes == 1 ? "Every Minute" : "Every \(minutes) Minutes"
            let option = item(title, #selector(chooseRotationInterval(_:)))
            option.representedObject = seconds
            option.state = settings.rotationInterval == seconds ? .on : .off
            intervalMenu.addItem(option)
        }
        let interval = NSMenuItem(title: "Rotate", action: nil, keyEquivalent: "")
        interval.submenu = intervalMenu
        menu.addItem(interval)

        let shuffle = item("Shuffle", #selector(toggleShuffle))
        shuffle.state = settings.rotationShuffle ? .on : .off
        menu.addItem(shuffle)
        return menu
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private var sourceDescription: String {
        settings.sourceURL.map(Settings.displayName(for:)) ?? "nothing"
    }

    // MARK: Actions

    @objc private func openFile() {
        if let url = chooseFile() { delegate?.menuDidChooseSource(url) }
    }

    @objc private func openURL() {
        if let url = chooseURL() { delegate?.menuDidChooseSource(url) }
    }

    @objc private func openFileForDisplay(_ sender: NSMenuItem) {
        guard let uuid = sender.representedObject as? String, let url = chooseFile() else { return }
        delegate?.menuDidChooseSource(url, forDisplay: uuid)
    }

    @objc private func openURLForDisplay(_ sender: NSMenuItem) {
        guard let uuid = sender.representedObject as? String, let url = chooseURL() else { return }
        delegate?.menuDidChooseSource(url, forDisplay: uuid)
    }

    @objc private func chooseForDisplay(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? DisplayChoice else { return }
        delegate?.menuDidChooseSource(choice.url, forDisplay: choice.uuid)
    }

    private func chooseFile() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose an HTML wallpaper"
        panel.allowedContentTypes = [.html]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if let current = settings.sourceURL, current.isFileURL {
            panel.directoryURL = current.deletingLastPathComponent()
        }
        activate()
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private func chooseURL() -> URL? {
        let alert = NSAlert()
        alert.messageText = "Open URL"
        alert.informativeText = "Enter a web address or the path to a local HTML file."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        field.placeholderString = "https://example.com"
        if let current = settings.sourceURL, !current.isFileURL {
            field.stringValue = current.absoluteString
        }
        alert.accessoryView = field
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        guard let url = Self.parseURL(field.stringValue) else {
            let error = NSAlert()
            error.messageText = "That doesn’t look like a valid URL."
            error.informativeText = field.stringValue
            error.runModal()
            return nil
        }
        return url
    }

    @objc private func nextWallpaper() {
        rotation.advance()
    }

    @objc private func showRotationItem(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        delegate?.menuDidChooseSource(url)
    }

    @objc private func addToRotation() {
        let panel = NSOpenPanel()
        panel.title = "Add wallpapers to the rotation"
        panel.message = "Choose HTML files, wallpaper folders, or a folder of wallpaper folders."
        panel.prompt = "Add"
        panel.allowedContentTypes = [.html, .folder]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        activate()
        guard panel.runModal() == .OK else { return }
        let wasEmpty = settings.rotationURLs.isEmpty
        rotation.add(panel.urls)
        // Starting a fresh rotation: show its first wallpaper right away.
        if wasEmpty, let first = settings.rotationURLs.first, first != settings.sourceURL {
            delegate?.menuDidChooseSource(first)
        }
    }

    @objc private func addCurrentToRotation() {
        guard let url = settings.sourceURL else { return }
        rotation.add([url])
    }

    @objc private func removeCurrentFromRotation() {
        guard let url = settings.sourceURL else { return }
        rotation.remove(url)
    }

    @objc private func clearRotation() {
        rotation.clear()
    }

    @objc private func chooseRotationInterval(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? TimeInterval else { return }
        settings.rotationInterval = seconds
        rotation.reschedule()
    }

    @objc private func toggleShuffle() {
        settings.rotationShuffle.toggle()
    }

    @objc private func reload() {
        delegate?.menuDidRequestReload()
    }

    @objc private func toggleTintSync() {
        settings.tintSyncEnabled.toggle()
        delegate?.menuDidChangeSettings()
    }

    @objc private func chooseTintInterval(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? TimeInterval else { return }
        settings.tintSyncInterval = seconds
        delegate?.menuDidChangeSettings()
    }

    @objc private func chooseDisplayMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = DisplayMode(rawValue: raw) else { return }
        settings.displayMode = mode
        delegate?.menuDidChangeSettings()
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
                if service.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                }
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn’t change Launch at Login"
            alert.informativeText = "\(error.localizedDescription)\n\nLaunch at Login only works when running the bundled Underlay.app."
            activate()
            alert.runModal()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func activate() {
        if #available(macOS 14, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Accepts full URLs, bare hostnames (assumes https) and local paths.
    static func parseURL(_ input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("/") || text.hasPrefix("~") {
            return URL(fileURLWithPath: (text as NSString).expandingTildeInPath)
        }
        let candidate = text.contains("://") ? text : "https://\(text)"
        guard let url = URL(string: candidate), let scheme = url.scheme?.lowercased() else { return nil }
        switch scheme {
        case "file": return url
        case "http", "https": return url.host?.isEmpty == false ? url : nil
        default: return nil
        }
    }
}
