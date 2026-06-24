import SwiftUI
import SessionCore

struct SessionRowView: View {
    let session: UnifiedSession
    var isChild = false
    let onRecall: () -> Void
    let onVSCode: () -> Void
    var onReveal: (() -> Void)? = nil

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            statusDot
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.displayTitle)
                        .font(.system(size: isChild ? 12 : 13, weight: .medium)).lineLimit(1)
                    sourceBadge
                }
                metaLine
                if !isChild || session.branch != nil {
                    HStack(spacing: 6) {
                        if session.isWorktree { Image(systemName: "arrow.triangle.branch").font(.system(size: 9)) }
                        Text(branchOrPath).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                if session.attention == .needsApproval, let w = session.waitingFor {
                    Text("⏳ \(w)").font(.caption2).foregroundStyle(.red).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            actions
        }
        .padding(.vertical, isChild ? 5 : 8).padding(.horizontal, 8)
        .background(hovering ? Color.primary.opacity(0.06) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onHover { hovering = $0 }
    }

    private var statusDot: some View {
        Circle().fill(session.attention.color).frame(width: 8, height: 8)
            .padding(.top, 4).help(session.attention.label)
    }

    private var sourceBadge: some View {
        Text(session.source.isCodex ? "Codex" : "Claude")
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(session.source.isCodex ? Color.purple.opacity(0.22) : Color.orange.opacity(0.22))
            .foregroundStyle(session.source.isCodex ? .purple : .orange)
            .clipShape(Capsule())
    }

    private var metaLine: some View {
        HStack(spacing: 6) {
            if let m = session.shortModel { Text(m) }
            if let e = session.effort { Text("· \(e)") }
            Text("·").foregroundStyle(.quaternary)
            Text(session.terminal.terminalApp ?? originatorText)
            if session.terminal.viaTmux { Text("· tmux") }
        }.font(.caption2).foregroundStyle(.secondary).lineLimit(1)
    }

    private var originatorText: String {
        switch session.originator {
        case "Claude Code": return "via Claude Code"
        case "subagent":    return "sub-agent"
        case .some(let o):  return o
        case .none:         return session.source.rawValue
        }
    }

    private var branchOrPath: String {
        if let b = session.branch, !b.isEmpty { return b }
        return prettyPath(session.cwd)
    }

    private var actions: some View {
        HStack(spacing: 2) {
            IconButton(systemName: "arrow.uturn.backward.circle", help: "Recall this session's window",
                       disabled: !session.canRecall, action: onRecall)
            IconButton(systemName: "chevron.left.forwardslash.chevron.right",
                       help: "Open worktree in VS Code", action: onVSCode)
            if let onReveal {
                IconButton(systemName: "folder", help: "Reveal worktree in Finder", action: onReveal)
            }
        }
        .opacity(hovering ? 1 : 0.5)
    }

    private func prettyPath(_ p: String) -> String {
        let home = NSHomeDirectory()
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }
}
