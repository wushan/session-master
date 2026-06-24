import SwiftUI
import AppKit
import Observation
import SessionCore

/// A pinned, always-on-top, non-activating panel that mirrors the session list. Unlike the
/// menu-bar popover it does NOT dismiss when you click elsewhere — it floats over your work.
@MainActor
@Observable
final class FloatingPanel {
    let store: SessionStore
    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private var watcher: PanelCloseWatcher?
    private(set) var isShown = false

    init(store: SessionStore) { self.store = store }

    func toggle() { isShown ? hide() : show() }

    func show() {
        guard panel == nil else { return }
        let hosting = NSHostingView(rootView: PinnedView(store: store))
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 500),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.title = "SessionMaster"
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.contentView = hosting
        let w = PanelCloseWatcher { [weak self] in self?.panel = nil; self?.watcher = nil; self?.isShown = false }
        p.delegate = w
        watcher = w
        p.center()
        p.orderFrontRegardless()
        panel = p
        isShown = true
    }

    func hide() { panel?.close(); panel = nil; watcher = nil; isShown = false }
}

/// Clears the FloatingPanel's reference when the user closes the panel via its title bar.
private final class PanelCloseWatcher: NSObject, NSWindowDelegate {
    let onClose: () -> Void
    init(onClose: @escaping () -> Void) { self.onClose = onClose }
    func windowWillClose(_ notification: Notification) { onClose() }
}

/// Content of the floating panel — the same session list, sorted needs-you-first then recent.
struct PinnedView: View {
    @Bindable var store: SessionStore
    @State private var collapsed: Set<String> = []

    private var sessions: [UnifiedSession] {
        store.sessions.sorted {
            $0.attention.rank != $1.attention.rank
                ? $0.attention.rank < $1.attention.rank
                : ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Sessions").font(.headline)
                Spacer()
                if store.needsApprovalCount > 0 {
                    Label("\(store.needsApprovalCount)", systemImage: "bell.badge.fill")
                        .font(.caption).foregroundStyle(.red)
                }
                if store.awaitingYouCount > 0 {
                    Label("\(store.awaitingYouCount)", systemImage: "person.fill.questionmark")
                        .font(.caption).foregroundStyle(.yellow)
                }
                Button { store.openDashboard?(.config) } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless).pointerCursor().help("Settings")
                Button { store.openDashboard?(.sessions) } label: { Image(systemName: "macwindow.badge.plus") }
                    .buttonStyle(.borderless).pointerCursor().help("Open dashboard")
            }.padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            if !store.hasLoaded {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading…").foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(SessionTree.build(sessions, extraChildren: store.subagentChildren)) { node in
                        SessionNodeView(node: node, collapsed: $collapsed, store: store)
                    }
                }.padding(8)
            }
            }
        }
        .frame(minWidth: 340, minHeight: 260)
        .background(.background)
    }
}
