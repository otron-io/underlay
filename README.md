# Underlay

Underlay is a tiny macOS menu bar app that turns any local HTML file or URL into a live desktop
wallpaper on every connected display — and keeps the menu bar's tint in sync with it.

![Underlay screenshot](docs/screenshot.png)
<!-- TODO: add a screenshot / screen recording -->

- Native Swift + AppKit + WKWebView, no dependencies, ~1 MB
- One wallpaper window per display, extending under the menu bar and notch
- Live reload: save the HTML file and the wallpaper updates instantly
- Rotation: cycle through a set of wallpapers every few minutes
- Different wallpapers on different displays
- Pages get `?screen=<index>&width=<w>&height=<h>` so they can vary per display
- Menu bar tint sync (see below)
- Restores your original wallpapers on quit, and after a crash on next launch

Requires macOS 13 Ventura or later.

## Build

```sh
git clone https://github.com/otron-io/underlay.git
cd underlay
scripts/build-app.sh            # → build/Underlay.app
open build/Underlay.app
```

`scripts/build-app.sh` builds in release mode, assembles `Underlay.app` (with `LSUIElement`, so
there's no Dock icon), bundles the `examples/` folder and ad-hoc signs it. Set `UNIVERSAL=1` to
build for both arm64 and x86_64 (needs full Xcode). Copy the app to `/Applications` before
enabling **Launch at Login**.

The app icon is drawn in HTML (`design/icon/icon.html`) and rendered with WebKit; after
editing it, run `scripts/make-icon.sh` to regenerate `Resources/AppIcon.icns`. The menu bar
icon is a flat template version drawn in code (`Sources/Underlay/StatusIcon.swift`).

For development, `swift run` works too; it finds `examples/gradient.html` in the checkout.

Because the app is ad-hoc signed, Gatekeeper will complain if you download a build from
somewhere else. Building locally avoids that; otherwise right-click → Open the first time.

## Usage

Click the menu bar icon:

| Item | |
| --- | --- |
| Open HTML File… | Pick a local `.html`/`.htm` file. Relative assets (CSS, JS, images) work. |
| Open URL… | Any `https://` URL, or a local path. |
| Reload | Reload every display. |
| Rotation | A playlist of wallpapers. Add HTML files or folders (a folder of wallpaper folders adds each one's `index.html`), click an entry to show it, choose how often to rotate (Off, 1, 5, **10**, 30 or 60 minutes) and toggle Shuffle. |
| Next Wallpaper | Skip to the next wallpaper in the rotation. |
| *Display name* | With several displays, each gets its own submenu: **Same as Other Displays** (follows the main wallpaper and rotation), or pin a wallpaper to that display — from your rotation set, a file or a URL. Pinned displays don't rotate. Remembered per display by its hardware UUID. |
| Sync Menu Bar Tint | Mirror the wallpaper into the real desktop picture (on by default). |
| Tint Refresh Interval | Off, 2s, 5s (default), 15s or 60s. |
| Show On | All Displays, or Main Display Only. |
| Launch at Login | Uses `SMAppService`. |
| Quit Underlay | Restores your original wallpapers. |

All settings persist in `UserDefaults` (`dev.underlay.Underlay`).

### Writing a wallpaper

Any web page works. A few tips:

- Read the display info from the query string:
  ```js
  const params = new URLSearchParams(location.search);
  const screen = Number(params.get("screen")); // 0 = display with the menu bar
  ```
- Wallpapers run all day, so prefer CSS transforms/opacity animations over heavy canvas or
  `filter: blur()` work, and respect `prefers-reduced-motion`.
- Mouse events are ignored — the wallpaper is purely visual.
- Local pages can `fetch()` sibling files in the same folder.

See [`examples/gradient.html`](examples/gradient.html).

## How it works

**Windows.** For each `NSScreen` Underlay creates a borderless `NSWindow` sized to
`screen.frame` (not `visibleFrame`, so it covers the menu bar and notch area) at
`kCGDesktopWindowLevel`. That's below Finder's desktop icons and every app window. The window
ignores mouse events, joins all Spaces, is stationary in Mission Control and hosts a
`WKWebView`. Local files load with `loadFileURL(_:allowingReadAccessTo:)`, granting access to
the file's folder. Windows are rebuilt when `didChangeScreenParametersNotification` reports a
real change in displays.

**Live reload.** A `DispatchSource` watches both the HTML file (in-place writes) and its folder
(atomic saves, which replace the file), debounced to 300 ms.

**Menu bar tint.** The translucent menu bar is tinted from the *desktop picture*, not from
windows behind it, so a window-based wallpaper would leave the menu bar showing your old
wallpaper's colours. To fix that, Underlay periodically:

1. snapshots each web view with `WKWebView.takeSnapshot`,
2. renders it at the screen's backing scale and hashes the pixels — unchanged frames stop here,
3. writes a PNG to `~/Library/Application Support/Underlay/Tint/` under a fresh, timestamped
   name (macOS caches desktop pictures by URL) and deletes the previous one,
4. sets it with `NSWorkspace.setDesktopImageURL(_:for:options:)`.

This happens after every page load, on display changes, on Space changes (the setter only
affects the current Space) and on the refresh interval. The timer pauses while displays sleep.

**Restoring.** Before the first snapshot is applied, each display's original desktop picture
(and its scaling options) is saved in `UserDefaults`, keyed by `NSScreenNumber`. On quit —
including `SIGTERM`/`SIGINT` — those are put back. A `sessionRunning` flag left set by a crash
or force-quit triggers the same restore on next launch. A display is only restored if it still
shows an Underlay snapshot, so a wallpaper you changed in System Settings meanwhile is left alone.

## Limitations

- Desktop pictures are per Space, and macOS only lets apps set the current one. On quit,
  only the current Space is restored; other Spaces you visited keep Underlay's last snapshot
  until you change them.
- Dynamic and Aerial (video) wallpapers may not restore exactly; restoring sets the image URL
  macOS reported.
- With a short refresh interval and a constantly animating page, Underlay writes a full-resolution
  PNG per display on every tick. Use a longer interval (or Off) for heavy animations.
- Not sandboxed, so not eligible for the Mac App Store as-is.

## License

[MIT](LICENSE)
