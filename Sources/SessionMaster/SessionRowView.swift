import SwiftUI
import AppKit
import SessionCore

struct SessionRowView: View {
    let session: UnifiedSession
    var isChild = false
    var subagentCount = 0
    /// Most urgent attention among (collapsed) children — tints the sub-agent chip so a working
    /// or blocked child shows through the fold.
    var childAttention: UnifiedSession.Attention? = nil
    /// >1 == this row stands for N collapsed routine runs; renders an "×N runs" toggle chip.
    var runCount = 0
    var onToggleRuns: (() -> Void)? = nil
    // Position in a continuous-rail list: trims the rail so it starts at the first dot and ends at
    // the last (no overhang above the top dot / no tail below the bottom one). Default false =
    // full-height rail (used where rows don't form one continuous timeline).
    var isFirst = false
    var isLast = false
    let onRecall: () -> Void
    let onVSCode: () -> Void
    var onReveal: (() -> Void)? = nil
    var onRename: ((String?) -> Void)? = nil
    var onResume: (() -> Void)? = nil

    @State private var hovering = false
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var titleFocused: Bool

    private var rowVPad: CGFloat { isChild ? 5 : 7 }

    /// Stale fade, except for rows that still need the user (see the modifiers below).
    private var faded: Bool { session.isStale && !session.attention.needsUser }

    /// What a click on this row will actually do — the tap handler, the tooltip, and the blue
    /// resume chip all read this one truth so the user can predict the click before making it.
    enum PrimaryAction { case recall, resume, none }
    private var primaryAction: PrimaryAction {
        // A saved Desktop row's "recall" can only foreground Claude.app without navigating to
        // this conversation — resume-in-terminal is the only action that provably lands in the
        // clicked session, so it takes the primary click (recall stays in the context menu).
        if session.source == .claudeDesktop, session.pid == nil, session.canResume { return .resume }
        if session.canRecall { return .recall }
        if session.canResume { return .resume }
        return .none
    }

    private var primaryActionHint: String {
        switch primaryAction {
        case .recall: return "Click to recall"
        case .resume:
            return "Click to resume in \(AppSettings.shared.resumeTerminal.rawValue) — opens a new terminal"
        case .none:   return ""
        }
    }

    var body: some View {
        // The whole row recalls; action buttons overlay the top-right on hover so the content
        // (title / path / subtitle) gets the full width.
        HStack(alignment: .top, spacing: 8) {
            timelineLeading
            VStack(alignment: .leading, spacing: 2) {
                // Title gets a line to ITSELF — it's the one thing the user reads to identify a
                // session, so chips must never crush it down to "S…". Only the (fixed-slot)
                // actions menu shares this line; the badges live on the row below.
                HStack(spacing: 6) {
                    if editing {
                        TextField("Title", text: $draft)
                            .textFieldStyle(.roundedBorder).font(.system(size: isChild ? 14 : 15))
                            .focused($titleFocused)
                            .onAppear { titleFocused = true }
                            .onSubmit { onRename?(draft); editing = false }
                            .onExitCommand { editing = false }
                    } else {
                        Text(session.displayTitle)
                            .font(.system(size: isChild ? 13 : 14, weight: .medium))
                            .lineLimit(1).truncationMode(.tail)
                        if session.rich.customTitle != nil {
                            Image(systemName: "pencil").font(.system(size: 9)).foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 4)
                        // One ellipsis menu, ALWAYS occupying its (small, fixed) slot and only
                        // fading in on hover: inserting views on hover reflowed the whole line,
                        // and the old overlay covered content — reserved space + opacity does
                        // neither.
                        actionsMenu.opacity(hovering ? 1 : 0)
                    }
                }
                if !editing { badgeLine }
                metaLine
                HStack(spacing: 6) {
                    if session.isWorktree { Image(systemName: "arrow.triangle.branch").font(.system(size: 10)) }
                    Text(branchOrPath).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                    gitChips
                }
                if let sub = session.subtitle, !sub.isEmpty {
                    Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(1).italic()
                }
                if session.attention == .needsApproval, let w = session.waitingFor {
                    Text("⏳ \(w)").font(.caption).foregroundStyle(.red).lineLimit(1)
                }
            }
            .padding(.vertical, rowVPad)
            Spacer(minLength: 4)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            switch primaryAction {
            case .recall: onRecall()
            case .resume: onResume?()
            case .none:   break
            }
        }
        .pointerCursor(primaryAction != .none)
        .padding(.horizontal, 8)
        // Rounded hover fill as a background (not a clip) so the timeline rail isn't cut at the
        // row edges — it runs straight into the next row. Beneath it, rows that need the user get
        // a row-level urgency treatment that survives peripheral vision (the 9pt dot alone loses
        // to brighter chips): needsApproval = red edge bar + faint tint; awaitingYou = yellow bar.
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(!isChild && session.attention == .needsApproval
                          ? Color.red.opacity(0.06) : .clear)
                RoundedRectangle(cornerRadius: 8).fill(hovering ? Color.primary.opacity(0.06) : .clear)
            }
        }
        .overlay(alignment: .leading) {
            if !isChild, session.attention.needsUser {
                Capsule().fill(session.attention.color)
                    .frame(width: 3)
                    .padding(.vertical, 4)
            }
        }
        // Old sessions (>48h idle) fade to grayscale so the live ones stand out — still clickable.
        // Rows that NEED the user are exempt: fading a red "needs approval" dot to gray would hide
        // the very signal the sort and the menu-bar badge are advertising.
        .saturation(faded && !editing ? 0 : 1)
        .opacity(faded && !hovering && !editing ? 0.5 : 1)
        .onHover { hovering = $0 }
        .help(primaryActionHint)
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

    /// A vertical timeline rail: the last-activity time sits on the left as the axis, then one
    /// full-height line runs top-to-bottom of the row with the status dot riding on it near the
    /// title. Because the line fills the whole row height and rows are stacked flush, the rails of
    /// consecutive rows join into a single continuous vertical timeline (not a per-row segment).
    @ViewBuilder private var timelineLeading: some View {
        if isChild {
            Circle().fill(session.attention.color).frame(width: 7, height: 7)
                .padding(.top, 4).help(session.attention.label)
        } else {
            HStack(alignment: .top, spacing: 5) {
                Text(relativeAge ?? "").font(.system(size: 11)).foregroundStyle(.tertiary)
                    .frame(width: 28, alignment: .trailing).padding(.top, titleCenterY - 6.5)
                ZStack(alignment: .top) {
                    railLine
                    TimelineDot(color: session.attention.color, pulsing: session.attention == .working)
                        .padding(.top, titleCenterY - 4.5).help(session.attention.label)
                }.frame(width: 12)
            }
        }
    }

    /// Vertical center of the title's first line (14pt), measured from the row's content top. The
    /// age label and the timeline dot align to this so they sit level with the title instead of
    /// floating above it.
    private var titleCenterY: CGFloat { rowVPad + 8.5 }
    /// Vertical distance from the row's top to the dot's center — where the rail starts (first row)
    /// or ends (last row). The dot rides at the title's center.
    private var dotCenterY: CGFloat { titleCenterY }

    /// The rail segment for this row, trimmed at the ends of a continuous list: from the dot down on
    /// the first row, top down to the dot on the last, full height in the middle, none for a lone row.
    @ViewBuilder private var railLine: some View {
        let bar = Rectangle().fill(.quaternary).frame(width: 1.5)
        switch (isFirst, isLast) {
        case (true, true):   Color.clear
        case (true, false):  bar.frame(maxHeight: .infinity).padding(.top, dotCenterY)
        case (false, true):  bar.frame(height: dotCenterY)
        case (false, false): bar.frame(maxHeight: .infinity)
        }
    }

    /// The source badge + state chips, on their own line beneath the title so they never squeeze
    /// it. Order is stable (source first) so the eye lands in the same place every row.
    private var badgeLine: some View {
        HStack(spacing: 6) {
            sourceBadge
            if session.fromDesktop {
                chip("app→cli", .orange)
                    .help("Started in Claude Desktop — this terminal owns the conversation now; the app window is stale")
            }
            // The chip appears whenever the primary click RESUMES (not only on ended rows) — a
            // saved Desktop row launches a terminal on click, and that side effect must be
            // visible before the click, not after.
            if primaryAction == .resume { resumeChip }
            if session.isAutomationRun { scheduleBadge("auto", .secondary) }
            else if session.isRoutineRun { scheduleBadge("routine", .teal) }
            if runCount > 1 { runCountChip }
            if subagentCount > 0 { subagentChip }
            prChip
            Spacer(minLength: 0)
        }
    }

    /// The surface glyph: where does this session actually live? A filled terminal = a live
    /// terminal window you can recall; an outline terminal = a CLI session whose terminal is
    /// gone; a macwindow = a Desktop-app conversation. The user has typed into the wrong surface
    /// before — tool color alone (Claude/Codex) doesn't answer "which window owns this?".
    private var surfaceGlyph: String {
        switch session.source {
        case .claudeDesktop, .codexDesktop:
            return "macwindow"
        case .claudeCLI, .codexCLI:
            let attached = session.terminal.terminalPID != nil || session.terminal.viaTmux
            return attached ? "terminal.fill" : "terminal"
        }
    }

    private var sourceBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: surfaceGlyph).font(.system(size: 8, weight: .bold))
            Text(session.source.isCodex ? "Codex" : "Claude")
                .font(.system(size: 10, weight: .bold))
        }
        .padding(.horizontal, 5).padding(.vertical, 1)
        .background(session.source.isCodex ? Color.purple.opacity(0.22) : Color.orange.opacity(0.22))
        .foregroundStyle(session.source.isCodex ? .purple : .orange)
        .clipShape(Capsule())
        .fixedSize()   // a badge must never compress into a vertical letter-stack
        .help(session.source.rawValue + (surfaceGlyph == "terminal.fill" ? " — terminal attached" : ""))
    }

    private func chip(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.18)).foregroundStyle(color).clipShape(Capsule())
            .fixedSize()   // chips keep their natural size; the (truncating) title flexes instead
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
            Image(systemName: "clock.arrow.2.circlepath").font(.system(size: 9))
            Text(text).font(.system(size: 10, weight: .bold))
        }
        .padding(.horizontal, 5).padding(.vertical, 1)
        .background(color.opacity(0.18)).foregroundStyle(color)
        .clipShape(Capsule())
        .fixedSize()
    }

    /// How many Codex companions / sub-agents this session spawned (children collapse by default,
    /// so this is the at-a-glance count). Tinted by the busiest child's attention so a working or
    /// blocked child shows through the fold instead of hiding behind a gray count.
    private var subagentChip: some View {
        let tint: Color = {
            switch childAttention {
            case .needsApproval, .awaitingYou, .working: return childAttention!.color
            default: return .secondary
            }
        }()
        return HStack(spacing: 2) {
            Image(systemName: "person.2.fill").font(.system(size: 9))
            Text("\(subagentCount)").font(.system(size: 10, weight: .bold))
        }
        .padding(.horizontal, 5).padding(.vertical, 1)
        .background(tint.opacity(0.18)).foregroundStyle(tint)
        .clipShape(Capsule())
        .fixedSize()
        .help(childAttention == .working ? "A sub-agent is working — expand to see"
              : "Sub-agents / companions")
    }

    /// "×N runs" — this row stands for N collapsed routine runs; click to expand them.
    private var runCountChip: some View {
        Button { onToggleRuns?() } label: {
            chip("×\(runCount) runs", .teal)
        }
        .buttonStyle(.plain).pointerCursor()
        .help("\(runCount) runs of this routine — click to show them all")
    }

    /// Marks an ended session — the terminal is gone, but click to resume it in a new Terminal.
    private var resumeChip: some View {
        HStack(spacing: 2) {
            Image(systemName: "arrow.clockwise").font(.system(size: 9, weight: .bold))
            Text("resume").font(.system(size: 10, weight: .bold))
        }
        .padding(.horizontal, 5).padding(.vertical, 1)
        .background(Color.blue.opacity(0.2)).foregroundStyle(.blue)
        .clipShape(Capsule())
        .fixedSize()
    }

    private var metaLine: some View {
        HStack(spacing: 6) {
            if let m = session.shortModel { Text(m) }
            if let e = session.effort { Text("· \(e)") }
            Text("·").foregroundStyle(.quaternary)
            Text(session.terminal.terminalApp ?? originatorText)
            if session.terminal.viaTmux { Text("· tmux") }
        }.font(.caption).foregroundStyle(.secondary).lineLimit(1)
    }

    /// Last-activity age (shared helper in UIHelpers so child lines render the same format).
    private var relativeAge: String? { SessionMaster.relativeAge(session.updatedAt) }

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

    // Recall/resume is the whole-row click; every secondary action lives in this one compact
    // menu (mirrors the context menu). A single 22pt slot is cheap enough to reserve permanently,
    // which is what keeps the row from reflowing on hover.
    private var actionsMenu: some View {
        Menu {
            if onRename != nil {
                Button("Rename…") { draft = session.displayTitle; editing = true }
            }
            if session.canRecall { Button("Recall window") { onRecall() } }
            if session.canResume, let onResume {
                Button("Resume in \(AppSettings.shared.resumeTerminal.rawValue)") { onResume() }
            }
            Button("Open in editor") { onVSCode() }
            if let onReveal { Button("Reveal in Finder") { onReveal() } }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 13))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .foregroundStyle(.secondary)
        .help("Actions")
        .pointerCursor()
    }

    private func prettyPath(_ p: String) -> String {
        let home = NSHomeDirectory()
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }
}
