import SwiftUI
import AppKit
import SessionCore

/// A session as an accordion card. Collapsed it is title-first and near-silent — the one glance you
/// take scanning fifty rows. Single-click expands it (the list keeps one open at a time) into an
/// instrument readout: telemetry, the last prompt, the actions inline, and the CHILDREN it spawned.
/// Double-click (or the expanded Recall button) is the fast path back to its terminal.
struct SessionRowView: View {
    let session: UnifiedSession
    var children: [UnifiedSession] = []
    var isOpen: Bool = false
    var onToggle: () -> Void = {}
    /// >1 == this row stands for N collapsed routine runs; shows an "×N runs" toggle chip.
    var runCount = 0
    var onToggleRuns: (() -> Void)? = nil

    /// Title editing is owned by the list (one row at a time), so it's driven from outside.
    var isEditing = false
    var onBeginEdit: () -> Void = {}
    var onEndEdit: () -> Void = {}

    let onRecall: () -> Void
    let onVSCode: () -> Void
    var onReveal: (() -> Void)? = nil
    var onRename: ((String?) -> Void)? = nil
    var onResume: (() -> Void)? = nil

    @State private var hovering = false
    @State private var draft = ""
    @FocusState private var titleFocused: Bool

    private func commitEdit() { onRename?(draft); onEndEdit() }

    private var c: Color { session.attention.color }
    private var faded: Bool { session.isStale && !session.attention.needsUser }
    private var isDim: Bool { session.isEnded || (session.source == .claudeDesktop && session.pid == nil) }
    /// A real (non-empty) approval prompt is shown as the red waiting line — which also owns the
    /// space the subtitle would use. Both are keyed off this so an empty waitingFor can't hide both.
    private var hasWaitingLine: Bool {
        session.attention == .needsApproval && (session.waitingFor?.isEmpty == false)
    }

    enum PrimaryAction { case recall, resume, none }
    private var primaryAction: PrimaryAction {
        if session.source == .claudeDesktop, session.pid == nil, session.canResume { return .resume }
        if session.canRecall { return .recall }
        if session.canResume { return .resume }
        return .none
    }
    private func performPrimary() {
        switch primaryAction { case .recall: onRecall(); case .resume: onResume?(); case .none: break }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if session.attention == .needsApproval, let w = session.waitingFor, !w.isEmpty {
                waitingLine(w)
            }
            if isOpen { body_ }
        }
        .padding(.leading, 3)                       // room for the edge accent
        .background(alignment: .leading) { edgeAccent }
        .background(RoundedRectangle(cornerRadius: 13)
            .fill(isOpen ? Color.primary.opacity(0.05) : (hovering ? Color.primary.opacity(0.035) : .clear)))
        .overlay(RoundedRectangle(cornerRadius: 13)
            .strokeBorder(isOpen ? Color.primary.opacity(0.10) : .clear, lineWidth: 1))
        .contentShape(Rectangle())
        // Single click expands — instantly. (No double-click gesture: it would force every single
        // click to wait ~0.25s to disambiguate, which is the expand "lag".) Recall is the expanded
        // card's primary button + the context menu.
        .onTapGesture { if !isEditing { onToggle() } }
        .pointerCursor()
        // Stale fade, but an expanded card shows its full color detail (a red ctx ring, git/PR
        // hues, the sage button) — desaturating those would hide the very signals it exists for.
        .saturation(faded && !isEditing && !isOpen ? 0 : 1)
        .opacity(faded && !hovering && !isOpen && !isEditing ? 0.5 : 1)
        .onHover { hovering = $0 }
        .help(isOpen || isEditing ? "" : "Click to expand")
        .contextMenu { menu }
        .onChange(of: isEditing) { if isEditing { draft = session.displayTitle; titleFocused = true } }
        .animation(.easeOut(duration: 0.14), value: isOpen)
    }

    private var edgeAccent: some View {
        RoundedRectangle(cornerRadius: 3).fill(c)
            .frame(width: 3).opacity(isDim ? 0.4 : 0.9)
            .padding(.vertical, 10)
    }

    // MARK: Collapsed header

    private var header: some View {
        HStack(spacing: 9) {
            Circle().fill(isDim ? Color.secondary.opacity(0.5) : c).frame(width: 8, height: 8)
                .shadow(color: session.attention == .working ? c.opacity(0.9) : .clear, radius: 3)
            if isEditing {
                TextField("Title", text: $draft)
                    .textFieldStyle(.roundedBorder).font(.system(size: 15))
                    .focused($titleFocused)
                    .onSubmit { commitEdit() }
                    .onExitCommand { onEndEdit() }
                Button { commitEdit() } label: {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 15)).foregroundStyle(Color.sage)
                }.buttonStyle(.plain).pointerCursor().help("Save (Return)")
                Button { onEndEdit() } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 15)).foregroundStyle(.tertiary)
                }.buttonStyle(.plain).pointerCursor().help("Cancel (Esc)")
            } else {
                Text(session.displayTitle)
                    .font(.system(size: 15.5, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                // Hover the row → an edit affordance appears right on the title (WordPress-block
                // style); click it to rename inline. A renamed session keeps a quiet pencil at rest.
                if hovering {
                    Button { onBeginEdit() } label: {
                        Image(systemName: "square.and.pencil").font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }.buttonStyle(.plain).pointerCursor().help("Edit title")
                } else if session.rich.customTitle != nil {
                    Image(systemName: "pencil").font(.system(size: 9)).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 6)
                if let ctx = session.rich.contextPercent, ctx >= 70 {
                    ContextRing(percent: ctx, size: 16, showLabel: false)
                }
                BroodPips(children: children)
                if runCount > 1 { runChip }
                if session.isAutomationRun || session.isRoutineRun {
                    Image(systemName: "clock.arrow.2.circlepath").font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                // A conversation taken over from Claude Desktop: the app window is now stale, this
                // terminal owns it. Flag it so the user never types into the wrong surface again.
                if session.fromDesktop {
                    Chip(text: "app→cli", color: .orange)
                        .help("Started in Claude Desktop — this terminal owns the conversation now; the app window is stale")
                }
                // Two channels: the colored tool mark says Claude vs Codex, the monochrome glyph
                // says terminal vs Desktop-app — so neither has to carry both at once.
                ToolMark(session: session, size: 13)
                Image(systemName: surfaceGlyph(session)).font(.system(size: 10.5))
                    .foregroundStyle(.secondary).help(surfaceHelp(session))
                Text(relativeAge(session.updatedAt) ?? "").font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
    }

    private var runChip: some View {
        Button { onToggleRuns?() } label: { Chip(text: "×\(runCount) runs", color: .teal) }
            .buttonStyle(.plain).pointerCursor()
            .help("\(runCount) runs of this routine — show them all")
    }

    private func waitingLine(_ w: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "bolt.fill").font(.system(size: 9))
            Text(w).font(.system(size: 11, design: .monospaced)).lineLimit(1)
        }
        .foregroundStyle(.red).padding(.leading, 14).padding(.trailing, 12).padding(.bottom, 9)
    }

    // MARK: Expanded body

    private var body_: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1).padding(.bottom, 11)
            telemetry
            if let sub = session.subtitle, !sub.isEmpty, !hasWaitingLine {
                Text("“\(sub)”").font(.system(size: 12)).italic().foregroundStyle(.secondary)
                    .lineLimit(2).padding(.top, 11)
            }
            actions.padding(.top, 13)
            if !children.isEmpty { childrenSection.padding(.top, 13) }
        }
        .padding(.horizontal, 14).padding(.bottom, 13)
    }

    private var telemetry: some View {
        VStack(spacing: 10) {
            telemetryRow(cap: "Model", value: modelText, icon: "cpu") {
                if let ctx = session.rich.contextPercent { ContextRing(percent: ctx, size: 34) }
                else { Text("no ctx").font(caption).foregroundStyle(.tertiary) }
            }
            telemetryRow(cap: "Branch", value: branchOrPath, icon: "arrow.triangle.branch") { gitCell }
            telemetryRow(cap: "Where", value: whereText, icon: surfaceGlyph(session)) { prCell }
        }
    }

    private func telemetryRow<Right: View>(cap: String, value: String, icon: String,
                                           @ViewBuilder right: () -> Right) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 1) {
                Text(cap.uppercased()).font(.system(size: 9.5, weight: .semibold))
                    .tracking(0.9).foregroundStyle(.tertiary)
                HStack(spacing: 5) {
                    Image(systemName: icon).font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(value).font(mono).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 10)
            right()
        }
    }

    @ViewBuilder private var gitCell: some View {
        // Only when there IS a repo. A nil git means "not a git dir" — asserting "clean" there
        // would be a false claim about a working tree that doesn't exist.
        if let g = session.rich.git {
            if g.trackLabel != nil || g.dirtyCount > 0 {
                HStack(spacing: 6) {
                    if let label = g.trackLabel { Text(label).font(mono).foregroundStyle(trackColor(g.track)) }
                    if g.dirtyCount > 0 { Text("\(g.dirtyCount)Δ").font(mono).foregroundStyle(.yellow) }
                }
            } else {
                Text("clean").font(mono).foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder private var prCell: some View {
        if let n = session.rich.prNumber {
            let state = session.rich.prState
            let color: Color = state == "MERGED" ? .purple : (state == "CLOSED" ? .red
                : (state == "DRAFT" ? .secondary : .green))
            Button {
                if let s = session.rich.prURL, let url = URL(string: s) { NSWorkspace.shared.open(url) }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.pull").font(.system(size: 10))
                    Text("#\(n)" + (state == "DRAFT" ? " draft" : "")).font(mono)
                }.foregroundStyle(color)
            }.buttonStyle(.plain).pointerCursor().help(session.rich.prURL ?? "Open pull request")
        }
    }

    private var actions: some View {
        HStack(spacing: 7) {
            if primaryAction != .none {
                Button(action: performPrimary) {
                    Text(primaryVerb).font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 11).padding(.vertical, 5)
                }
                .buttonStyle(.plain).foregroundStyle(Color(nsColor: .windowBackgroundColor))
                .background(Color.sage, in: RoundedRectangle(cornerRadius: 8)).pointerCursor()
            }
            ghostButton("chevron.left.forwardslash.chevron.right", "Editor", onVSCode)
            if let onReveal { ghostButton("folder", "Finder", onReveal) }
            if onRename != nil { ghostButton("pencil", "Rename") { onBeginEdit() } }
        }
    }

    private func ghostButton(_ icon: String, _ label: String?, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11))
                if let label { Text(label).font(.system(size: 12)) }
            }
            .padding(.horizontal, label == nil ? 7 : 9).padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(.secondary).pointerCursor()
        .help(label ?? "Rename")
    }

    // MARK: Children

    private var childrenSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text("CHILDREN").font(.system(size: 9.5, weight: .semibold)).tracking(0.9)
                    .foregroundStyle(.tertiary)
                Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1)
            }
            ForEach(childrenSorted) { kid in childRow(kid) }
        }
    }

    private var childrenSorted: [UnifiedSession] {
        // Recency tiebreak: quiet states share one rank, and Swift's sort isn't stable — without
        // it, quiet children could reshuffle on every refresh.
        children.sorted {
            $0.attention.rank != $1.attention.rank
                ? $0.attention.rank < $1.attention.rank
                : ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast)
        }
    }

    private func childRow(_ k: UnifiedSession) -> some View {
        HStack(spacing: 8) {
            Circle().fill(k.attention == .idle || k.attention == .ended
                          ? Color.secondary.opacity(0.5) : k.attention.color)
                .frame(width: 6, height: 6)
            Image(systemName: childGlyph(k)).font(.system(size: 10)).foregroundStyle(.tertiary)
            Text("\(childType(k)) · \(k.displayTitle)").font(.system(size: 12))
                .foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 6)
            if k.attention == .needsApproval {
                Text("NEEDS APPROVAL").font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(0.5).foregroundStyle(.red)
            } else {
                // Surface a working / your-turn child in words + color, not just a bare timestamp,
                // so an active or waiting sub-agent reads without decoding the dot.
                if k.attention == .working || k.attention == .awaitingYou {
                    Text(k.attention.label.lowercased())
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(k.attention.color)
                }
                if let age = relativeAge(k.updatedAt) {
                    Text(age).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func childType(_ k: UnifiedSession) -> String {
        switch k.originator {
        case "workflow": return "workflow"
        case "subagent": return k.source.isCodex ? "sub-agent" : "sub-agent"
        default: return k.source.isCodex ? "companion" : "agent"
        }
    }
    private func childGlyph(_ k: UnifiedSession) -> String {
        switch k.originator {
        case "workflow": return "gearshape.2"
        case "subagent": return "person.2"
        default: return "cpu"
        }
    }

    // MARK: Context menu

    @ViewBuilder private var menu: some View {
        Button("Rename…") { onBeginEdit() }
        if session.rich.customTitle != nil { Button("Reset to default title") { onRename?(nil) } }
        Divider()
        if session.canRecall { Button("Recall window") { onRecall() } }
        if session.canResume { Button("Resume in Terminal") { onResume?() } }
        Button("Open in editor") { onVSCode() }
        if let onReveal { Button("Reveal in Finder") { onReveal() } }
    }

    // MARK: Text bits

    private let caption = Font.system(size: 11)
    private let mono = Font.system(size: 12.5, design: .monospaced)
    private var primaryVerb: String {
        switch primaryAction {
        case .recall: return "Recall"
        case .resume: return session.isEnded || session.source.isClaude
            ? "Resume in \(AppSettings.shared.resumeTerminal.rawValue)" : "Resume"
        case .none: return ""
        }
    }
    private var modelText: String {
        [session.shortModel, session.effort].compactMap { $0 }.joined(separator: " · ")
    }
    private var branchOrPath: String {
        if let b = session.branch, !b.isEmpty { return b }
        let home = NSHomeDirectory()
        return session.cwd.hasPrefix(home) ? "~" + session.cwd.dropFirst(home.count) : session.cwd
    }
    private var whereText: String {
        var s = session.terminal.terminalApp ?? (session.source.isCodex ? "Codex" : "Claude")
        if session.source == .claudeDesktop || session.source == .codexDesktop { s += " app" }
        if session.terminal.viaTmux { s += " · tmux" }
        return s
    }
    private func trackColor(_ t: GitStatus.Track) -> Color {
        switch t {
        case .gone: return .blue
        case .ahead: return .orange
        case .behind, .diverged: return .red
        default: return .secondary
        }
    }
}
