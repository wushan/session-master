import SwiftUI
import AppKit

/// Timeline status dot. Actively-working sessions get a static halo ring so they stand out at a
/// glance. (No continuous animation — a repeatForever pulse made the menu-bar popover flicker.)
struct TimelineDot: View {
    let color: Color
    let pulsing: Bool   // true == actively working

    var body: some View {
        ZStack {
            if pulsing {
                Circle().stroke(color.opacity(0.4), lineWidth: 2).frame(width: 15, height: 15)
            }
            Circle().fill(color).frame(width: 9, height: 9)
        }
        .frame(width: 9, height: 9)
    }
}

/// Resolves the NSWindow hosting a SwiftUI view — used to dismiss the menu-bar popover on demand.
/// Resolves on both make and update (the view may not be in a window yet at make time), but only
/// reports an *actual* change via the Coordinator so it can't loop on @State writes.
struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { context.coordinator.update(v.window, onResolve) }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { context.coordinator.update(nsView.window, onResolve) }
    }
    final class Coordinator {
        private weak var last: NSWindow?
        func update(_ w: NSWindow?, _ cb: (NSWindow?) -> Void) {
            guard w !== last else { return }
            last = w; cb(w)
        }
    }
}

/// Shows the pointing-hand cursor on hover (SwiftUI buttons don't by default on macOS 14).
struct PointerCursor: ViewModifier {
    var active: Bool = true
    @State private var pushed = false
    func body(content: Content) -> some View {
        content.onHover { inside in
            let want = inside && active
            if want && !pushed { NSCursor.pointingHand.push(); pushed = true }
            else if !want && pushed { NSCursor.pop(); pushed = false }
        }
        // If the view goes away while hovered, pop the pushed cursor — otherwise it leaks on the
        // NSCursor stack and the pointing hand can get stuck.
        .onDisappear { if pushed { NSCursor.pop(); pushed = false } }
    }
}

extension View {
    func pointerCursor(_ active: Bool = true) -> some View { modifier(PointerCursor(active: active)) }
}

/// Compact icon button with a hover highlight + pointer cursor, used for row actions.
struct IconButton: View {
    let systemName: String
    let help: String
    var disabled = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12))
                .frame(width: 22, height: 22)
                .background(hover && !disabled ? Color.primary.opacity(0.12) : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
        .opacity(disabled ? 0.35 : 1)
        .onHover { hover = $0 }
        .pointerCursor(!disabled)
    }
}
