import AppKit

/// The menu bar icon: a flat version of the app icon — an outlined glass layer floating above a
/// solid one (the live wallpaper underneath). Drawn as vectors so it's crisp at any scale, and marked
/// as a template so macOS tints it for light/dark menu bars.
enum StatusIcon {
    static func make(size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            draw(in: rect)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Underlay"
        return image
    }

    private static func draw(in rect: NSRect) {
        let unit = rect.width / 18
        let stroke = 1.5 * unit
        let gap = 1.4 * unit
        let width = 15 * unit
        let height = 8.6 * unit
        let step = 4.6 * unit
        let centerX = rect.midX
        let bottomY = rect.minY + 6.6 * unit

        func layer(_ index: Int) -> NSBezierPath {
            let cy = bottomY + CGFloat(index) * step
            let path = NSBezierPath()
            path.move(to: NSPoint(x: centerX, y: cy + height / 2))
            path.line(to: NSPoint(x: centerX + width / 2, y: cy))
            path.line(to: NSPoint(x: centerX, y: cy - height / 2))
            path.line(to: NSPoint(x: centerX - width / 2, y: cy))
            path.close()
            path.lineJoinStyle = .round
            return path
        }

        guard let context = NSGraphicsContext.current else { return }
        NSColor.black.set()

        for index in 0..<2 {
            let path = layer(index)
            if index > 0 {
                // Knock out what's beneath this layer (plus a gap) so the stack reads as opaque plates.
                context.compositingOperation = .clear
                path.lineWidth = stroke + gap * 2
                path.fill()
                path.stroke()
                context.compositingOperation = .sourceOver
            }
            path.lineWidth = stroke
            if index == 0 {
                path.fill()
            }
            path.stroke()
        }
    }
}
