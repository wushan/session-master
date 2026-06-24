import SwiftUI
import SessionCore

/// Renders a session and, indented beneath it, its Codex companion children — with a
/// disclosure chevron to collapse the group. `collapsed` holds parent ids that are folded.
struct SessionNodeView: View {
    let node: SessionNode
    @Binding var collapsed: Set<String>
    let store: SessionStore

    private var isExpanded: Bool { !collapsed.contains(node.id) }

    var body: some View {
        VStack(spacing: 1) {
            HStack(spacing: 0) {
                chevron
                row(for: node.session)
            }
            if node.hasChildren, isExpanded {
                ForEach(node.children) { child in
                    HStack(spacing: 0) {
                        Rectangle().fill(.quaternary).frame(width: 1.5)
                            .padding(.leading, 13).padding(.trailing, 6).padding(.vertical, 2)
                        row(for: child, isChild: true)
                    }
                }
            }
        }
    }

    @ViewBuilder private var chevron: some View {
        if node.hasChildren {
            Button {
                if isExpanded { collapsed.insert(node.id) } else { collapsed.remove(node.id) }
            } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(width: 16, height: 16).contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointerCursor()
            .help(isExpanded ? "Collapse companions" : "Expand companions")
        } else {
            Color.clear.frame(width: 16, height: 1)
        }
    }

    private func row(for s: UnifiedSession, isChild: Bool = false) -> some View {
        SessionRowView(session: s, isChild: isChild,
                       onRecall: { store.recall(s) },
                       onVSCode: { store.openInVSCode(s) },
                       onReveal: { store.revealInFinder(s) })
    }
}
