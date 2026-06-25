import SwiftUI
import SessionCore

/// Renders a session and, collapsed beneath it by default, its Codex companion / sub-agent
/// children — with a disclosure chevron. `expanded` holds the parent ids the user has opened.
/// Children can't be recalled or acted on, so they show as a single dim line (no hover/actions).
struct SessionNodeView: View {
    let node: SessionNode
    @Binding var expanded: Set<String>
    let store: SessionStore

    private var isExpanded: Bool { expanded.contains(node.id) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                chevron
                SessionRowView(session: node.session,
                               subagentCount: node.children.count,
                               onRecall: { store.recall(node.session) },
                               onVSCode: { store.openInVSCode(node.session) },
                               onReveal: { store.revealInFinder(node.session) },
                               onRename: { store.setTitle($0, for: node.session) },
                               onResume: { store.resume(node.session) })
            }
            if node.hasChildren, isExpanded {
                ForEach(node.children) { child in
                    HStack(spacing: 6) {
                        Rectangle().fill(.quaternary).frame(width: 1.5).padding(.vertical, 1)
                        compactChild(child)
                    }
                    // Indent the connector under the parent's timeline dot so children nest to the
                    // right of the parent content.
                    .padding(.leading, 62)
                }
            }
        }
    }

    @ViewBuilder private var chevron: some View {
        if node.hasChildren {
            Button {
                if isExpanded { expanded.remove(node.id) } else { expanded.insert(node.id) }
            } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(width: 16, height: 16).contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointerCursor()
            .help(isExpanded ? "Hide sub-agents" : "Show \(node.children.count) sub-agent(s)")
        } else {
            Color.clear.frame(width: 16, height: 1)
        }
    }

    /// A sub-agent / companion: one dim, non-interactive line — just its status, title and source,
    /// since you can't recall or act on it.
    private func compactChild(_ s: UnifiedSession) -> some View {
        HStack(spacing: 6) {
            Circle().fill(s.attention.color.opacity(0.7)).frame(width: 5, height: 5)
            Text(s.displayTitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            Text(s.source.isCodex ? "Codex" : "sub").font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}
