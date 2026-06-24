import SwiftUI
import AppKit

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
