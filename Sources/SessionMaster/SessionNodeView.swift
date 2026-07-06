import SwiftUI
import SessionCore

/// Wires a session node to its accordion card. The open state lives in the list (one card open at
/// a time), so this only forwards `isOpen` + a toggle. A node's children (Codex companions, Task
/// sub-agents, workflow runs) render *inside* the card now — as brood pips when collapsed and a
/// CHILDREN list when open — so there is no separate nested-row rendering here anymore.
struct SessionNodeView: View {
    let node: SessionNode
    @Binding var openId: String?
    /// The single row currently editing its title — one at a time across the whole list.
    @Binding var editingId: String?
    let store: SessionStore
    var runCount = 0
    var onToggleRuns: (() -> Void)? = nil

    var body: some View {
        SessionRowView(
            session: node.session,
            children: node.children,
            isOpen: openId == node.id,
            onToggle: { openId = (openId == node.id) ? nil : node.id },
            runCount: runCount,
            onToggleRuns: onToggleRuns,
            isEditing: editingId == node.id,
            onBeginEdit: { editingId = node.id },
            onEndEdit: { if editingId == node.id { editingId = nil } },
            onRecall: { store.recall(node.session) },
            onVSCode: { store.openInVSCode(node.session) },
            onReveal: { store.revealInFinder(node.session) },
            onRename: { store.setTitle($0, for: node.session) },
            onResume: { store.resume(node.session) })
    }
}
