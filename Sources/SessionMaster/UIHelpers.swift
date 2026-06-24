import SwiftUI
import AppKit

/// Timeline status dot. When the session is actively working it emits a radar-style pulse so
/// you can see at a glance which sessions are running right now.
struct TimelineDot: View {
    let color: Color
    let pulsing: Bool
    @State private var animate = false

    var body: some View {
        ZStack {
            if pulsing {
                Circle().fill(color.opacity(0.45))
                    .frame(width: 9, height: 9)
                    .scaleEffect(animate ? 2.4 : 1)
                    .opacity(animate ? 0 : 0.7)
            }
            Circle().fill(color).frame(width: 9, height: 9)
        }
        .frame(width: 9, height: 9)
        .onAppear {
            guard pulsing else { return }
            withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) { animate = true }
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
