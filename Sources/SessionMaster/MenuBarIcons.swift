import AppKit

/// Custom menu-bar glyphs (drawn as template images so macOS tints them for light/dark menu
/// bars). The "rings" glyph mirrors the app icon's concentric circles.
enum MenuBarIcons {
    static let ringsID = "rings"

    static let rings: NSImage = {
        let s: CGFloat = 18
        let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setStrokeColor(NSColor.black.cgColor)
            let c = CGPoint(x: s / 2, y: s / 2)
            for (r, w): (CGFloat, CGFloat) in [(2.6, 1.5), (5.2, 1.6), (7.8, 1.6)] {
                ctx.setLineWidth(w)
                ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            }
            return true
        }
        img.isTemplate = true
        return img
    }()
}
