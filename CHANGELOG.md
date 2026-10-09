# Changelog

All notable changes to Underlay are documented here. Versions follow [Semantic Versioning](https://semver.org).

## [1.0.0] - 2026-10-09

The first release.

### Features

- **Live HTML wallpapers.** Show any local HTML file or URL as your desktop wallpaper, on every
  display, extending under the menu bar and notch. Relative assets (CSS, JS, images) work.
- **Live reload.** Save the HTML file and the wallpaper updates within a moment.
- **Menu bar tint sync.** Mirrors the wallpaper into the real desktop picture so the translucent
  menu bar matches it. Refreshes on load, on display and Space changes, and on an interval.
- **Rotation.** Build a set of wallpapers (add files, or whole folders of them) and cycle through
  them every 1–60 minutes, in order or shuffled.
- **Per-display wallpapers.** Pin a different wallpaper to each display, remembered per display.
- **Sharp on non-Retina displays.** Pages render at 2× and are downsampled, so layouts scaled with
  CSS transforms stay crisp.
- **Safe restore.** Your original wallpapers come back on quit, and on next launch after a crash.
- Launch at Login, Main Display Only mode, and a page fallback when a file is missing.

Pages receive `?screen=<index>&width=<w>&height=<h>` so they can vary per display.
