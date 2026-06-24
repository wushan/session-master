import SwiftUI
import SessionCore

/// Shown in the dashboard until Accessibility is granted — recall needs it to raise and
/// move terminal windows. Guides the user to the exact System Settings pane.
struct AccessibilityBanner: View {
    let store: SessionStore

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield.fill").font(.title2).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Enable window recall").font(.subheadline.weight(.semibold))
                Text("SessionMaster needs Accessibility access to focus and move terminal windows.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Grant…") { store.requestAccessibility() }
                .buttonStyle(.borderedProminent).pointerCursor()
            Button("Open Settings") { store.openAccessibilitySettings() }
                .buttonStyle(.bordered).pointerCursor()
        }
        .padding(12)
        .background(Color.orange.opacity(0.12))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.35)))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 10).padding(.top, 8)
    }
}
