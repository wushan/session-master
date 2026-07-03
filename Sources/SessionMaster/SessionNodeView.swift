import SwiftUI
import SessionCore

/// Renders a session and, collapsed beneath it by default, its Codex companion / sub-agent
/// children — with a disclosure chevron. `expanded` holds the parent ids the user has opened.
/// Children can't be recalled or acted on, so they show as a single dim line (no hover/actions).
struct SessionNodeView: View {
    let node: SessionNode
    @Binding var expanded: Set<String>
    let store: SessionStore
    var isFirst = false
    var isLast = false
    /// >1 == this row stands for N collapsed routine runs (see MainWindowView.collapseRoutineRuns).
    var runCount = 0
    var onToggleRuns: (() -> Void)? = nil

    private var isExpanded: Bool { expanded.contains(node.id) }

    /// Most urgent attention among the children — shown through the collapsed fold.
    private var childAttention: UnifiedSession.Attention? {
        node.children.map(\.attention).min { $0.rank < $1.rank }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                chevron
                SessionRowView(session: node.session,
                               subagentCount: node.children.count,
                               childAttention: childAttention,
                               runCount: runCount,
                               onToggleRuns: onToggleRuns,
                               isFirst: isFirst, isLast: isLast,
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

    /// A sub-agent / companion: one dim, non-interactive line — status word (when it matters),
    /// title, kind tag, and age, since you can't recall or act on it but you DO want to know
    /// whether it's still working and how fresh it is.
    private func compactChild(_ s: UnifiedSession) -> some View {
        HStack(spacing: 6) {
            Circle().fill(s.attention.color.opacity(0.85)).frame(width: 6, height: 6)
            if s.attention == .working || s.attention.needsUser {
                Text(s.attention.label.lowercased())
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(s.attention.color)
            }
            Text(s.displayTitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            Text(s.originator == "workflow" ? "workflow" : (s.source.isCodex ? "Codex" : "sub"))
                .font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
            Spacer(minLength: 0)
            if let age = relativeAge(s.updatedAt) {
                Text(age).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}
