import SwiftUI
import AppKit
import SessionCore

struct SessionRowView: View {
    let session: UnifiedSession
    var isChild = false
    var subagentCount = 0
    let onRecall: () -> Void
    let onVSCode: () -> Void
    var onReveal: (() -> Void)? = nil
    var onRename: ((String?) -> Void)? = nil
    var onResume: (() -> Void)? = nil

    @State private var hovering = false
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var titleFocused: Bool

    var body: some View {
        // The whole row recalls; action buttons overlay the top-right on hover so the content
        // (title / path / subtitle) gets the full width.
        HStack(alignment: .top, spacing: 8) {
            timelineLeading
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if editing {
                        TextField("Title", text: $draft)
                            .textFieldStyle(.roundedBorder).font(.system(size: isChild ? 12 : 13))
                            .frame(maxWidth: 220).focused($titleFocused)
                            .onAppear { titleFocused = true }
                            .onSubmit { onRename?(draft); editing = false }
                            .onExitCommand { editing = false }
                    } else {
                        Text(session.displayTitle)
                            .font(.system(size: isChild ? 12 : 13, weight: .medium)).lineLimit(1)
                        if session.rich.customTitle != nil {
                            Image(systemName: "pencil").font(.system(size: 8)).foregroundStyle(.tertiary)
                        }
                        sourceBadge
                        if session.isEnded { resumeChip }
                        if session.isAutomationRun { scheduleBadge("auto", .secondary) }
                        else if session.isRoutineRun { scheduleBadge("routine", .teal) }
                        if subagentCount > 0 { subagentChip }
                        prChip
                    }
                }
                metaLine
                HStack(spacing: 6) {
                    if session.isWorktree { Image(systemName: "arrow.triangle.branch").font(.system(size: 9)) }
                    Text(branchOrPath).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    gitChips
                }
                if let sub = session.subtitle, !sub.isEmpty {
                    Text(sub).font(.caption2).foregroundStyle(.secondary).lineLimit(1).italic()
                }
                if session.attention == .needsApproval, let w = session.waitingFor {
                    Text("⏳ \(w)").font(.caption2).foregroundStyle(.red).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if session.canRecall { onRecall() }
            else if session.canResume { onResume?() }
        }
        .pointerCursor(session.canRecall || session.canResume)
        .padding(.vertical, isChild ? 5 : 8).padding(.horizontal, 8)
        .background(hovering ? Color.primary.opacity(0.06) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .topTrailing) { if hovering { actions.padding(.top, 6).padding(.trailing, 8) } }
        // Old sessions (>48h idle) fade to grayscale so the live ones stand out — still clickable.
        .saturation(session.isStale && !editing ? 0 : 1)
        .opacity(session.isStale && !hovering && !editing ? 0.5 : 1)
        .onHover { hovering = $0 }
        .help(session.canRecall ? "Click to recall" : (session.canResume ? "Click to resume in Terminal" : ""))
        .contextMenu {
            Button("Rename…") { draft = session.displayTitle; editing = true }
            if session.rich.customTitle != nil {
                Button("Reset to default title") { onRename?(nil) }
            }
            Divider()
            if session.canRecall { Button("Recall window") { onRecall() } }
            if session.canResume { Button("Resume in Terminal") { onResume?() } }
            Button("Open in editor") { onVSCode() }
            if let onReveal { Button("Reveal in Finder") { onReveal() } }
        }
    }

    /// A vertical timeline rail with the last-activity time on the left as the time axis: the
    /// status dot sits at the top (pulsing when working), a connector line runs down the row.
    @ViewBuilder private var timelineLeading: some View {
        if isChild {
            Circle().fill(session.attention.color).frame(width: 7, height: 7)
                .padding(.top, 4).help(session.attention.label)
        } else {
            HStack(alignment: .top, spacing: 5) {
                Text(relativeAge ?? "").font(.system(size: 10)).foregroundStyle(.tertiary)
                    .frame(width: 30, alignment: .trailing).padding(.top, 1)
                VStack(spacing: 0) {
                    TimelineDot(color: session.attention.color, pulsing: session.attention == .working)
                        .padding(.top, 2).help(session.attention.label)
                    Rectangle().fill(.quaternary).frame(width: 1.5)
                        .frame(maxHeight: .infinity).padding(.top, 2)
                }.frame(width: 10)
            }
        }
    }

    private var sourceBadge: some View {
        Text(session.source.isCodex ? "Codex" : "Claude")
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(session.source.isCodex ? Color.purple.opacity(0.22) : Color.orange.opacity(0.22))
            .foregroundStyle(session.source.isCodex ? .purple : .orange)
            .clipShape(Capsule())
    }

    private func chip(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.18)).foregroundStyle(color).clipShape(Capsule())
    }

    @ViewBuilder private var gitChips: some View {
        if let g = session.rich.git {
            switch g.track {
            case .gone:               chip("merged", .blue)
            case .ahead(let n):       chip("↑\(n)", .orange)
            case .behind(let n):      chip("↓\(n)", .red)
            case .diverged(let a, let b): chip("↑\(a) ↓\(b)", .red)
            case .noUpstream:         chip("local", .secondary)
            case .inSync, .unknown:   EmptyView()
            }
            if g.dirtyCount > 0 { chip("\(g.dirtyCount)Δ", .yellow) }
        }
        if let c = session.rich.contextPercent { chip("\(c)% ctx", c >= 80 ? .red : .secondary) }
    }

    @ViewBuilder private var prChip: some View {
        if let n = session.rich.prNumber {
            let state = session.rich.prState
            let color: Color = state == "MERGED" ? .purple : (state == "CLOSED" ? .red
                : (state == "DRAFT" ? .secondary : .green))
            Button {
                if let s = session.rich.prURL, let url = URL(string: s) { NSWorkspace.shared.open(url) }
            } label: {
                chip("PR#\(n)" + (state == "DRAFT" ? " draft" : ""), color)
            }
            .buttonStyle(.plain).pointerCursor()
            .help(session.rich.prURL ?? "Open pull request")
        }
    }

    /// Marks a session that a schedule started rather than a person — a Codex automation ("auto")
    /// or a Claude routine ("routine"). Same clock glyph as the Automations tab.
    private func scheduleBadge(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 2) {
            Image(systemName: "clock.arrow.2.circlepath").font(.system(size: 8))
            Text(text).font(.system(size: 9, weight: .bold))
        }
        .padding(.horizontal, 5).padding(.vertical, 1)
        .background(color.opacity(0.18)).foregroundStyle(color)
        .clipShape(Capsule())
    }

    /// How many Codex companions / sub-agents this session spawned (children collapse by default,
    /// so this is the at-a-glance count).
    private var subagentChip: some View {
        HStack(spacing: 2) {
            Image(systemName: "person.2.fill").font(.system(size: 8))
            Text("\(subagentCount)").font(.system(size: 9, weight: .bold))
        }
        .padding(.horizontal, 5).padding(.vertical, 1)
        .background(Color.secondary.opacity(0.18)).foregroundStyle(.secondary)
        .clipShape(Capsule())
    }

    /// Marks an ended session — the terminal is gone, but click to resume it in a new Terminal.
    private var resumeChip: some View {
        HStack(spacing: 2) {
            Image(systemName: "arrow.clockwise").font(.system(size: 8, weight: .bold))
            Text("resume").font(.system(size: 9, weight: .bold))
        }
        .padding(.horizontal, 5).padding(.vertical, 1)
        .background(Color.blue.opacity(0.2)).foregroundStyle(.blue)
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

    /// Last-activity age, e.g. "2m" / "3h" — the freshness signal for active vs stale.
    private var relativeAge: String? {
        guard let d = session.updatedAt else { return nil }
        let s = -d.timeIntervalSinceNow
        if s < 0 { return nil }
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86_400 { return "\(Int(s / 3600))h" }
        return "\(Int(s / 86_400))d"
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

    // Recall is the whole-row click, so the row only needs the secondary actions here.
    private var actions: some View {
        HStack(spacing: 2) {
            if onRename != nil {
                IconButton(systemName: "pencil", help: "Rename") {
                    draft = session.displayTitle; editing = true
                }
            }
            if session.canResume, let onResume {
                IconButton(systemName: "arrow.clockwise", help: "Resume in Terminal", action: onResume)
            }
            IconButton(systemName: "chevron.left.forwardslash.chevron.right",
                       help: "Open worktree in editor", action: onVSCode)
            if let onReveal {
                IconButton(systemName: "folder", help: "Reveal worktree in Finder", action: onReveal)
            }
        }
        .padding(.horizontal, 3).padding(.vertical, 1)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.92),
                    in: RoundedRectangle(cornerRadius: 7))
    }

    private func prettyPath(_ p: String) -> String {
        let home = NSHomeDirectory()
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }
}
