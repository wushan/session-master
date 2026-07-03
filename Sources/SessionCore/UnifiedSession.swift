import Foundation

/// A single AI session, unified across Claude/Codex and CLI/Desktop for display and actions.
public struct UnifiedSession: Identifiable, Sendable {
    public enum Source: String, Sendable {
        case claudeCLI = "Claude CLI"
        case claudeDesktop = "Claude Desktop"
        case codexCLI = "Codex CLI"
        case codexDesktop = "Codex Desktop"
        public var isClaude: Bool { self == .claudeCLI || self == .claudeDesktop }
        public var isCodex: Bool { self == .codexCLI || self == .codexDesktop }
    }
    public enum Status: String, Sendable { case busy, waiting, idle, shell, unknown }

    /// What the session needs from the user — the semantic that drives color & ordering.
    /// Claude's `idle` means "turn ended, sitting at the prompt" → it's the user's turn.
    public enum Attention: String, Sendable {
        case needsApproval   // waiting on a permission prompt
        case awaitingYou     // assistant finished; your turn to respond
        case working         // actively processing
        case idle            // background/codex not recently active
        case ended           // CLI session whose process is gone — resumable, not recallable
        case unknown

        public var label: String {
            switch self {
            case .needsApproval: return "Needs approval"
            case .awaitingYou:   return "Your turn"
            case .working:       return "Working"
            case .idle:          return "Idle"
            case .ended:         return "Ended — resume"
            case .unknown:       return "—"
            }
        }
        public var rank: Int {
            switch self {
            case .needsApproval: return 0; case .awaitingYou: return 1
            case .working: return 2; case .idle: return 3; case .ended: return 4; case .unknown: return 5
            }
        }
        public var needsUser: Bool { self == .needsApproval || self == .awaitingYou }
    }

    public let id: String
    public let source: Source
    public let pid: pid_t?
    public let cwd: String
    public let name: String?            // Claude session name (== terminal window title)
    public let nameSource: String?      // "derived" → name is an auto-generated worktree slug
    public let title: String?           // human title (Desktop / Codex thread)
    public let model: String?
    public let effort: String?
    public let branch: String?
    public let worktreeName: String?
    public let originator: String?      // Codex launch source
    public let status: Status
    public let waitingFor: String?
    public let terminal: TerminalInfo
    public let updatedAt: Date?
    public let isAutomationRun: Bool     // a Codex automation execution (vs a manual session)
    public let scheduledTaskId: String?  // set when a Claude routine (scheduled task) spawned this
    public let isEnded: Bool             // CLI process is gone — show "Resume" instead of "Recall"
    public let kind: String?             // Claude session kind: "interactive" | "bg" | "daemon" | …
    /// True when `status` wasn't reported by the tool but assumed (e.g. an argv-detected resume
    /// writes no live-state file; its busy/idle is inferred from the transcript mtime). Assumed
    /// idle must not be promoted to "your turn".
    public let statusAssumed: Bool

    /// This session was started by a Claude routine, not a person.
    public var isRoutineRun: Bool { scheduledTaskId != nil }

    /// Optional enrichment (git state, PR, last prompt, context%) — filled by the aggregator.
    public var rich = SessionRich()

    public init(id: String, source: Source, pid: pid_t?, cwd: String, name: String?, title: String?,
                model: String?, effort: String?, branch: String?, worktreeName: String?,
                originator: String?, status: Status, waitingFor: String?,
                terminal: TerminalInfo, updatedAt: Date?, isAutomationRun: Bool = false,
                scheduledTaskId: String? = nil, isEnded: Bool = false, nameSource: String? = nil,
                kind: String? = nil, statusAssumed: Bool = false) {
        self.id = id; self.source = source; self.pid = pid; self.cwd = cwd; self.name = name
        self.nameSource = nameSource
        self.title = title; self.model = model; self.effort = effort; self.branch = branch
        self.worktreeName = worktreeName; self.originator = originator; self.status = status
        self.waitingFor = waitingFor; self.terminal = terminal; self.updatedAt = updatedAt
        self.isAutomationRun = isAutomationRun; self.scheduledTaskId = scheduledTaskId
        self.isEnded = isEnded
        self.kind = kind; self.statusAssumed = statusAssumed
    }

    /// Project name, stripping the worktree suffix so sessions group by repo.
    public var projectName: String {
        for marker in ["/.claude/worktrees/", "/.codex/worktrees/"] {
            if let r = cwd.range(of: marker) {
                return (String(cwd[..<r.lowerBound]) as NSString).lastPathComponent
            }
        }
        return (cwd as NSString).lastPathComponent
    }
    /// Full path to the project root (worktree suffix stripped). Unlike `projectName` (a basename
    /// for display grouping), this is collision-free across repos that share a folder name.
    public var projectRoot: String {
        for marker in ["/.claude/worktrees/", "/.codex/worktrees/"] {
            if let r = cwd.range(of: marker) { return String(cwd[..<r.lowerBound]) }
        }
        return cwd
    }
    public var isWorktree: Bool {
        worktreeName != nil || cwd.contains("/.claude/worktrees/") || cwd.contains("/.codex/worktrees/")
    }
    /// The worktree directory name from the cwd — the segment right after `.claude/worktrees/`
    /// (or `.codex/worktrees/`), if the session is running inside a worktree.
    public var cwdWorktreeName: String? {
        for marker in ["/.claude/worktrees/", "/.codex/worktrees/"] {
            if let r = cwd.range(of: marker) {
                let seg = cwd[r.upperBound...].split(separator: "/").first
                if let seg, !seg.isEmpty { return String(seg) }
            }
        }
        return nil
    }
    /// A key identifying the worktree this session belongs to: its cwd worktree name, else the
    /// metadata worktree name, else its (often worktree-derived) session name. Lets a Codex
    /// companion spawned into a worktree link back to the Claude session that owns it even when
    /// their git branches differ — e.g. the Claude session was launched from the repo root.
    public var worktreeKey: String? {
        if let w = cwdWorktreeName { return w }
        if let w = worktreeName, !w.isEmpty { return w }
        // The session name only counts as a worktree link when a worktree of that name actually
        // exists in this repo — names drift to whatever the user/AI called the task, and a bare
        // name fallback would let a same-named repo-root session hijack byWorktree matches.
        if let n = name, !n.isEmpty,
           FileManager.default.fileExists(atPath: projectRoot + "/.claude/worktrees/" + n) {
            return n
        }
        return nil
    }
    /// No interaction for >48h — shown dimmed/grayscale (still recallable) to mark it as old.
    public var isStale: Bool {
        guard let u = updatedAt else { return false }
        return Date().timeIntervalSince(u) > 48 * 3600
    }
    /// Label shown on the row. A user override always wins. Otherwise a live CLI session's `name`
    /// is normally the right thing — except when Claude *derived* it from the worktree (an ugly slug
    /// like "dazzling-williamson-d051b8-6e"): then we prefer the human/AI title so the label stays
    /// readable and doesn't flip as the session toggles live↔saved (live uses `name`, saved uses
    /// `title`). A non-derived name keeps priority.
    public var displayTitle: String {
        if let c = rich.customTitle, !c.isEmpty { return c }
        if let n = name, !n.isEmpty, nameSource != "derived" { return n }
        return title ?? rich.aiTitle ?? name ?? projectName
    }
    /// One-line "what is this session doing" — the last user ask or the AI-generated title.
    public var subtitle: String? { rich.lastPrompt ?? rich.aiTitle }

    /// Derived attention state. For interactive Claude sessions, `idle` is "your turn";
    /// for Codex background/automation rollouts, `idle` is just "not recently active".
    public var attention: Attention {
        if isEnded { return .ended }
        switch status {
        case .waiting: return .needsApproval
        case .busy:    return .working
        case .idle:
            // A live interactive Claude session sitting at the prompt = "your turn". Only when
            // the CLI actually *reported* idle, though: an assumed status (argv-detected resume)
            // and non-interactive kinds (bg/daemon — no prompt awaits anyone) stay plain idle.
            // A saved Desktop session (no running process, pid == nil) is just idle too.
            if source.isClaude, pid != nil, !statusAssumed,
               (kind ?? "interactive") == "interactive" { return .awaitingYou }
            return .idle
        case .shell:   return .working   // running a shell command (e.g. a long subprocess like a
                                         // `codex` review) — the session is busy, not idle
        case .unknown: return .unknown
        }
    }
    public var shortModel: String? { model?.replacingOccurrences(of: "claude-", with: "") }
    public var recallTarget: RecallTarget { RecallTarget(cwd: cwd, windowTitleHint: name, terminal: terminal) }

    public var canRecall: Bool {
        if isEnded { return false }
        switch source {
        case .claudeCLI, .codexCLI: return terminal.terminalPID != nil || originator == "VSCode"
        case .claudeDesktop, .codexDesktop: return true
        }
    }

    /// Can be reopened in a terminal with the tool's own resume command: a closed CLI session, a
    /// saved (non-live) Claude session, or a Codex CLI thread.
    public var canResume: Bool {
        if isEnded { return true }
        if source == .claudeDesktop, pid == nil { return true }   // saved → resume in a terminal
        // A Codex CLI thread is resumable only once its terminal is gone — while it's live, recall
        // it instead (resuming a running thread would attach a second TUI to the same rollout).
        // The busy guard covers the correlation gaps: an actively-written rollout always has a
        // writer attached, even when no TUI process could be matched to it.
        if source == .codexCLI { return !canRecall && status != .busy }
        return false
    }

    /// The command that resumes this session, run in its cwd by a new terminal — exactly what the
    /// tool itself prints ("Resume this session with: claude --resume <id>"). The by-id form targets
    /// the right session directly. (A session whose history contains a malformed diff can still
    /// crash Claude's interactive renderer — a Claude bug, independent of this command.)
    public var resumeCommand: String? {
        guard canResume else { return nil }
        switch source {
        case .claudeCLI, .claudeDesktop: return "claude --resume \(id)"
        case .codexCLI, .codexDesktop:   return "codex resume \(id)"
        }
    }
}

/// Builds and enriches unified sessions from every collector.
public enum SessionAggregator {

    public static func all() -> [UnifiedSession] { snapshot().sessions }

    /// Top-level sessions plus a map of parent id → sub-agent children (Codex sub-agents).
    public static func snapshot() -> (sessions: [UnifiedSession], subagents: [String: [UnifiedSession]]) {
        let claude = claudeSessions()
        let jsonLiveIds = Set(claude.map(\.id))
        // Live CLI sessions the live-state files miss (a terminal resume of a Desktop-origin
        // session writes no ~/.claude/sessions/{pid}.json) — recovered from process argv.
        let resumed = claudeResumeSessions(excluding: jsonLiveIds)
        let liveIds = jsonLiveIds.union(resumed.map(\.id))
        let desktop = desktopStandalone(excluding: liveIds)
        let codexAll = CodexSessionCollector.recent()
        var codexRaw = filterCodex(codexAll)
        let (codexLive, codexExtra) = correlateCodexProcesses(rollouts: codexRaw)
        codexRaw += codexExtra   // open TUIs whose rollout aged out of the window
        let codex = codexRaw.map { unified(from: $0, live: codexLive[$0.id]) }
        var subagents: [String: [UnifiedSession]] = [:]
        for c in codexRaw {
            let subs = CodexSubagentScanner.scan(rollout: c.url)
            if !subs.isEmpty { subagents[c.id] = subs.map { subagentSession($0, parent: c) } }
        }
        // New-format Codex sub-agents: the CHILD rollout carries parent_thread_id (its parent
        // contains no spawn_agent record at all) — surface the recently-active ones as children.
        for c in codexAll where c.threadSource == "subagent" {
            guard let parent = c.parentThreadId,
                  Date().timeIntervalSince(c.mtime) < codexSubagentWindow,
                  !(subagents[parent]?.contains { $0.id == c.id } ?? false) else { continue }
            subagents[parent, default: []].append(codexSubagentChild(c))
        }
        // Under each live Claude session (json-live + argv-resumed): nest its currently-running
        // dynamic Workflow runs and standalone Task sub-agents (finished ones are omitted).
        for p in (claude + resumed) {
            var kids = ClaudeWorkflowScanner.scan(sessionId: p.id, cwd: p.cwd).map { workflowSession($0, parent: p) }
            kids += ClaudeSubagentScanner.scan(sessionId: p.id, cwd: p.cwd).map { subagentSession($0, parent: p) }
            if !kids.isEmpty { subagents[p.id, default: []] = kids + (subagents[p.id] ?? []) }
        }
        // Recently-ended Claude CLI sessions (terminal closed) — resumable, not currently shown.
        // Sessions the user archived in Desktop stay hidden: resurfacing one as an "Ended — resume"
        // row (under its AI title, no less) would undo the archiving.
        let archived = ClaudeDesktopCollector.archivedCliIds()
        let shownIds = Set((claude + resumed + desktop).map(\.id))
        let ended = ClaudeEndedCollector.recent(excluding: shownIds.union(archived))
            .compactMap(endedSession(from:))

        var sessions = claude + resumed + codex + desktop + ended
        // Belt-and-suspenders: never emit two sessions sharing an id (SwiftUI Identifiable).
        var seenIds = Set<String>()
        sessions = sessions.filter { seenIds.insert($0.id).inserted }
        for i in sessions.indices {
            let s = sessions[i]
            sessions[i].rich.customTitle = CustomTitles.get(s.id)
            let dir = GitWorktree.effectivePath(branch: s.branch, cwd: s.cwd, isWorktree: s.isWorktree)
            sessions[i].rich.git = GitStatusCollector.status(dir: dir)
            if let b = s.branch, !b.isEmpty, b != "HEAD", let pr = PRStatus.forBranch(b, repoDir: dir) {
                // Keep the chip and its click target consistent: when gh's PR differs from the
                // transcript's pr-link marker, gh's URL replaces the stale one alongside its number.
                if sessions[i].rich.prNumber != pr.number { sessions[i].rich.prURL = pr.url }
                sessions[i].rich.prNumber = pr.number
                sessions[i].rich.prURL = sessions[i].rich.prURL ?? pr.url
                sessions[i].rich.prState = pr.displayState
                sessions[i].rich.prReviewDecision = pr.reviewDecision
            }
        }
        return (sessions.sorted(by: order), subagents)
    }

    /// Ended sessions (beyond the default recency window) whose record matches the search query —
    /// for finding/resuming an older closed session by typing in the dashboard. Covers Claude
    /// transcripts and Codex rollouts; Desktop-archived conversations stay hidden here too.
    public static func searchEndedSessions(query: String, excluding: Set<String>) -> [UnifiedSession] {
        let excl = excluding.union(ClaudeDesktopCollector.archivedCliIds())
        return ClaudeEndedCollector.matching(query: query, excluding: excl).compactMap(endedSession(from:))
            + codexMatching(query: query, excluding: excl)
    }

    /// Codex rollouts across the 14-day scan window whose title / cwd / branch matches `query` —
    /// the Codex counterpart of ClaudeEndedCollector.matching. Only user threads (no automations,
    /// sub-agents, or claude-driven companions), newest first, capped.
    static func codexMatching(query: String, excluding: Set<String>, limit: Int = 20) -> [UnifiedSession] {
        let q = query.lowercased()
        guard q.count >= 2 else { return [] }
        let titles = CodexSessionCollector.threadTitles()
        var out: [UnifiedSession] = []
        var scanned = 0
        for (url, m) in CodexSessionCollector.candidates() {
            scanned += 1
            if scanned > 200 || out.count >= limit { break }
            guard let c = CodexSessionCollector.parse(url, mtime: m, titles: titles),
                  !excluding.contains(c.id),
                  c.threadSource == nil || c.threadSource == "user",
                  !SessionTree.claudeDriven.contains(c.originator ?? "") else { continue }
            let hay = [c.title, c.cwd, c.branch].compactMap { $0 }.joined(separator: "\u{1}").lowercased()
            if hay.contains(q) { out.append(unified(from: c, live: nil)) }
        }
        return out
    }

    /// Match live interactive `codex` TUI processes to their rollouts: an explicit
    /// `codex resume <id>` names its rollout directly; a plain `codex` TUI is matched to the
    /// newest user-thread rollout in its cwd. This is what lets a Codex row be *recalled* (it has
    /// a real terminal) instead of wrongly offered a second-TUI "resume".
    ///
    /// A process whose rollout fell outside the recency window (a TUI left open but idle for
    /// days) PULLS its rollout back in via `extra` — an open terminal must never be invisible.
    static func correlateCodexProcesses(rollouts: [CodexSession])
        -> (live: [String: (pid: pid_t, terminal: TerminalInfo)], extra: [CodexSession]) {
        let procs = ProcessCollector.codexTUIProcesses()
        guard !procs.isEmpty else { return ([:], []) }
        let terms = ProcessCollector.correlateTerminals(pids: procs.map(\.pid))
        let byId = Dictionary(rollouts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [String: (pid: pid_t, terminal: TerminalInfo)] = [:]
        var extra: [CodexSession] = []
        func tuiEligible(_ c: CodexSession) -> Bool {
            c.originator != "Codex Desktop"
                && !SessionTree.claudeDriven.contains(c.originator ?? "")
                && (c.threadSource == nil || c.threadSource == "user")
        }
        for p in procs {
            var target: CodexSession?
            if let rid = p.resumeId { target = byId[rid] }
            if target == nil {
                // Newest TUI-eligible rollout in the process's cwd (companions/automations are
                // driven by something else; Desktop threads live inside Codex.app).
                target = rollouts.filter { $0.cwd == p.cwd && tuiEligible($0) }
                    .max { $0.mtime < $1.mtime }
            }
            if target == nil {
                // Not in the window — walk the full 14-day candidate list (newest first; parses
                // are mtime-cached, so this costs one pass ever, not one per poll).
                let titles = CodexSessionCollector.threadTitles()
                for (url, m) in CodexSessionCollector.candidates() {
                    guard let c = CodexSessionCollector.parse(url, mtime: m, titles: titles)
                    else { continue }
                    if let rid = p.resumeId { if c.id == rid { target = c; break } }
                    else if c.cwd == p.cwd, tuiEligible(c) { target = c; break }
                }
                if let t = target { extra.append(t) }
            }
            guard let target, out[target.id] == nil else { continue }
            out[target.id] = (p.pid, terms[p.pid] ?? .dead)
        }
        return (out, extra)
    }

    /// A recently-ended Claude CLI session, reconstructed from its transcript so it can be resumed.
    static func endedSession(from e: EndedClaudeSession) -> UnifiedSession? {
        guard let cwd = e.history.cwd, !cwd.isEmpty else { return nil }
        let h = e.history
        var u = UnifiedSession(
            id: e.sessionId, source: .claudeCLI, pid: nil, cwd: cwd, name: nil,
            title: h.customTitle ?? h.aiTitle,   // the user's explicit rename outranks the AI title
            model: h.model, effort: nil, branch: h.branch, worktreeName: nil, originator: nil,
            status: .idle, waitingFor: nil, terminal: .dead, updatedAt: e.updatedAt, isEnded: true)
        u.rich.aiTitle = h.aiTitle; u.rich.lastPrompt = h.lastPrompt
        u.rich.prNumber = h.prNumber; u.rich.prURL = h.prURL; u.rich.contextPercent = h.contextPercent
        return u
    }

    /// Saved Claude Desktop sessions that aren't currently live (those show as live instead).
    static func desktopStandalone(excluding liveIds: Set<String>) -> [UnifiedSession] {
        var seen = liveIds
        var out: [UnifiedSession] = []
        for d in ClaudeDesktopCollector.sessions() {
            // Skip live sessions and any duplicate cliSessionId — two sessions with the same id
            // crash SwiftUI's ForEach (Identifiable must be unique).
            guard let cli = d.cliSessionId, seen.insert(cli).inserted else { continue }
            guard let cwd = d.cwd ?? d.worktreePath, !cwd.isEmpty else { continue }
            // A terminal resume appends to the transcript but never touches the Desktop store's
            // lastActivityAt, leaving it frozen (the session looks days old). Prefer the
            // transcript's mtime when newer so a recently-used session sorts correctly.
            let updated = [d.lastActivityAt,
                           ClaudeHistoryEnricher.transcriptMtime(sessionId: cli, cwd: cwd)]
                .compactMap { $0 }.max()
            out.append(UnifiedSession(
                id: cli, source: .claudeDesktop, pid: nil, cwd: cwd, name: nil, title: d.title,
                model: d.model, effort: d.effort, branch: d.branch, worktreeName: d.worktreeName,
                originator: nil, status: .idle, waitingFor: nil, terminal: .dead,
                updatedAt: updated, scheduledTaskId: d.scheduledTaskId))
        }
        return out
    }

    /// Convenience: the full parent→child tree (companions + sub-agents).
    public static func tree() -> [SessionNode] {
        let snap = snapshot()
        return SessionTree.build(snap.sessions, extraChildren: snap.subagents)
    }

    // MARK: Claude (live + enrichment)

    public static func claudeSessions() -> [UnifiedSession] {
        let live = ClaudeLiveCollector.sessions()
        let terms = ProcessCollector.correlateTerminals(pids: live.map(\.pid))
        let desktop = ClaudeDesktopCollector.indexByCliSessionId()

        return live.map { s in
            let t = terms[s.pid] ?? .dead
            // A live session with a controlling tty (or tmux, or a recognized terminal) is a CLI
            // session — Claude Desktop's claude-code subprocess has no controlling tty. This stops
            // tmux / SSH / unrecognized-terminal CLI sessions being mislabeled Desktop (which sent
            // recall down the useless "bring Claude.app to front" path instead of tmux/AX).
            let isCLI = t.terminalApp != nil || t.viaTmux || t.tty != nil
            var model: String?, effort: String?, branch: String?, title: String?, worktree: String?
            var scheduledTaskId: String?

            if let d = desktop[s.sessionId] {          // Desktop session metadata
                model = d.model; effort = d.effort; title = d.title
                branch = d.branch; worktree = d.worktreeName
                scheduledTaskId = d.scheduledTaskId
            }
            let h = ClaudeHistoryEnricher.enrich(sessionId: s.sessionId, cwd: s.cwd)
            model = model ?? h?.model; branch = branch ?? h?.branch
            var u = UnifiedSession(
                id: s.sessionId,
                source: isCLI ? .claudeCLI : .claudeDesktop,
                pid: s.pid, cwd: s.cwd, name: s.name, title: title,
                model: model, effort: effort, branch: branch, worktreeName: worktree,
                originator: nil,
                status: UnifiedSession.Status(rawValue: s.status) ?? .unknown,
                waitingFor: s.waitingFor, terminal: t, updatedAt: s.updatedAt,
                scheduledTaskId: scheduledTaskId, nameSource: s.nameSource, kind: s.kind)
            u.rich.aiTitle = h?.aiTitle; u.rich.lastPrompt = h?.lastPrompt
            u.rich.prNumber = h?.prNumber; u.rich.prURL = h?.prURL
            // The merged model may carry the "[1m]" marker (Desktop store) that the transcript
            // never has — recompute the % against the true window when it does.
            u.rich.contextPercent = ClaudeHistoryEnricher.contextPercent(history: h, model: model)
            return u
        }
    }

    /// Live Claude CLI sessions found by reading process argv, for the case where the CLI wrote
    /// no `~/.claude/sessions/{pid}.json` — e.g. a terminal resume of a Desktop-origin session.
    /// `claude --resume <id>` names its session directly; the id-less takeover forms
    /// (`--continue`, `-c`, the `-r` picker) are resolved to the transcript the process has been
    /// appending to since it started. Excludes ids already surfaced from the live-state files.
    ///
    /// Status is *assumed* from the transcript mtime (recent writes → working, else idle) and
    /// flagged `statusAssumed`, so an assumed idle renders as plain "Idle" — never a false
    /// "Your turn" — and can't fire turn-completion notifications.
    static func claudeResumeSessions(excluding existing: Set<String>) -> [UnifiedSession] {
        var procs: [(pid: pid_t, sessionId: String)] = []
        for p in ProcessCollector.claudeResumeProcesses() {
            guard let sid = p.sessionId ?? resolveTakenOverSession(pid: p.pid),
                  !existing.contains(sid) else { continue }
            procs.append((p.pid, sid))
        }
        guard !procs.isEmpty else { return [] }
        let terms = ProcessCollector.correlateTerminals(pids: procs.map(\.pid))
        let desktop = ClaudeDesktopCollector.indexByCliSessionId()
        return procs.compactMap { p in
            let d = desktop[p.sessionId]
            let cwd = ProcessCollector.cwd(of: p.pid) ?? d?.cwd ?? d?.worktreePath ?? ""
            guard !cwd.isEmpty else { return nil }
            let mtime = ClaudeHistoryEnricher.transcriptMtime(sessionId: p.sessionId, cwd: cwd)
            let h = ClaudeHistoryEnricher.enrich(sessionId: p.sessionId, cwd: cwd)
            let model = d?.model ?? h?.model
            let busy = mtime.map { Date().timeIntervalSince($0) < 90 } ?? false
            var u = UnifiedSession(
                id: p.sessionId, source: .claudeCLI, pid: p.pid, cwd: cwd,
                name: nil, title: d?.title,
                model: model, effort: d?.effort,
                branch: d?.branch ?? h?.branch, worktreeName: d?.worktreeName,
                originator: nil, status: busy ? .busy : .idle,
                waitingFor: nil, terminal: terms[p.pid] ?? .dead,
                updatedAt: mtime ?? d?.lastActivityAt, scheduledTaskId: d?.scheduledTaskId,
                statusAssumed: true)
            u.rich.aiTitle = h?.aiTitle; u.rich.lastPrompt = h?.lastPrompt
            u.rich.prNumber = h?.prNumber; u.rich.prURL = h?.prURL
            u.rich.contextPercent = ClaudeHistoryEnricher.contextPercent(history: h, model: model)
            return u
        }
    }

    /// The session an id-less takeover (`claude --continue` / `-c` / `-r` picker) is attached to:
    /// the newest transcript in the process's cwd that has been written since the process started
    /// (the CLI appends to its transcript as soon as it loads one).
    static func resolveTakenOverSession(pid: pid_t) -> String? {
        guard let cwd = ProcessCollector.cwd(of: pid),
              let started = ProcessCollector.startTime(of: pid) else { return nil }
        let dir = ClaudeHistoryEnricher.projectsDir
            .appendingPathComponent(ClaudeHistoryEnricher.encode(cwd: cwd))
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        return files
            .filter { $0.pathExtension == "jsonl"
                && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
            .compactMap { u -> (String, Date)? in
                guard let m = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate, m >= started else { return nil }
                return (u.deletingPathExtension().lastPathComponent, m)
            }
            .max { $0.1 < $1.1 }?.0
    }

    // MARK: Codex (recent rollouts)

    public static func codexSessions() -> [UnifiedSession] {
        var rollouts = filterCodex(CodexSessionCollector.recent())
        let (live, extra) = correlateCodexProcesses(rollouts: rollouts)
        rollouts += extra
        return rollouts.map { unified(from: $0, live: live[$0.id]) }
    }

    /// How long an automation run stays visible after its last activity, so you can follow up
    /// on a just-finished automation. Stale runs drop off (they live in the Automations tab).
    static let automationActiveWindow: TimeInterval = 30 * 60
    /// Claude-driven companions render as children of their driving session — after this long
    /// without activity they're finished context, not worth a child row.
    static let companionActiveWindow: TimeInterval = 3 * 3600
    /// A CLI rollout with no attached TUI process and no recent writes is a closed thread —
    /// shown as "Ended — resume" (like Claude's ended sessions) rather than a live row.
    static let codexEndedAfter: TimeInterval = 30 * 60
    /// New-format sub-agent rollouts (parent_thread_id) count as running children this long.
    static let codexSubagentWindow: TimeInterval = 30 * 60

    /// Drop bare sub-agent rollouts (shown nested). Keep manual sessions; keep automation runs
    /// only while recently active, and claude-driven companion runs (codex exec / the Claude Code
    /// plugin) deduped to the latest per worktree so repeated runs don't pile up as child rows.
    static func filterCodex(_ sessions: [CodexSession]) -> [CodexSession] {
        var latestAutomation: [String: CodexSession] = [:]
        var latestCompanion: [String: CodexSession] = [:]
        var out: [CodexSession] = []
        for c in sessions {
            switch c.threadSource {
            case "subagent": continue
            case "automation":
                guard Date().timeIntervalSince(c.mtime) < automationActiveWindow else { continue }
                let key = (c.title ?? "") + "\u{1}" + c.cwd
                if let prev = latestAutomation[key], prev.mtime >= c.mtime { continue }
                latestAutomation[key] = c
            default:
                if SessionTree.claudeDriven.contains(c.originator ?? "") {
                    guard Date().timeIntervalSince(c.mtime) < companionActiveWindow else { continue }
                    let key = c.cwd + "\u{1}" + (c.branch ?? "")
                    if let prev = latestCompanion[key], prev.mtime >= c.mtime { continue }
                    latestCompanion[key] = c
                } else {
                    out.append(c)
                }
            }
        }
        return out + latestAutomation.values + latestCompanion.values
    }

    static func unified(from c: CodexSession,
                        live: (pid: pid_t, terminal: TerminalInfo)?) -> UnifiedSession {
        let isDesktop = c.originator == "Codex Desktop"
        // Companions/automations are transient by nature; user CLI threads with no attached TUI
        // and no recent writes are closed → resumable, mirroring Claude's ended sessions.
        let ended = !isDesktop && live == nil
            && !SessionTree.claudeDriven.contains(c.originator ?? "")
            && c.threadSource != "automation"
            && Date().timeIntervalSince(c.mtime) > codexEndedAfter
        return UnifiedSession(
            id: c.id,
            source: isDesktop ? .codexDesktop : .codexCLI,
            pid: live?.pid, cwd: c.cwd, name: nil, title: c.title,
            model: c.model, effort: c.effort, branch: c.branch, worktreeName: nil,
            originator: c.originator,
            status: codexStatus(mtime: c.mtime),
            waitingFor: nil, terminal: live?.terminal ?? .dead, updatedAt: c.mtime,
            isAutomationRun: c.threadSource == "automation",
            isEnded: ended)
    }

    /// A new-format Codex sub-agent (its rollout carries parent_thread_id) as a child row.
    static func codexSubagentChild(_ c: CodexSession) -> UnifiedSession {
        UnifiedSession(
            id: c.id, source: .codexCLI, pid: nil, cwd: c.cwd, name: nil,
            title: c.title ?? c.subagentRole.map { "codex \($0)" },
            model: c.model, effort: c.effort, branch: c.branch, worktreeName: nil,
            originator: "subagent",
            status: codexStatus(mtime: c.mtime),
            waitingFor: nil, terminal: .dead, updatedAt: c.mtime)
    }

    /// A Codex sub-agent shown as a child row (not a recallable window of its own).
    static func subagentSession(_ s: CodexSubagent, parent c: CodexSession) -> UnifiedSession {
        UnifiedSession(
            id: s.id,
            source: .codexCLI,
            pid: nil, cwd: c.cwd, name: nil, title: s.nickname,
            model: nil, effort: nil, branch: c.branch, worktreeName: nil,
            originator: "subagent",
            status: .idle, waitingFor: nil, terminal: .dead, updatedAt: nil)
    }

    /// A running dynamic Workflow shown as a child row under its parent session.
    static func workflowSession(_ w: ClaudeWorkflow, parent p: UnifiedSession) -> UnifiedSession {
        UnifiedSession(
            id: w.id,
            source: .claudeCLI,
            pid: nil, cwd: p.cwd, name: w.name, title: nil, model: nil, effort: nil,
            branch: p.branch, worktreeName: p.worktreeName,
            originator: "workflow",
            status: .busy, waitingFor: nil, terminal: .dead, updatedAt: w.startedAt)
    }

    /// A Claude sub-agent (Task tool) shown as a child row under its parent session. The scanner's
    /// liveness window already guarantees these are running, so they show as working (a gray
    /// "idle" dot on a by-definition-active agent reads as stuck).
    static func subagentSession(_ s: ClaudeSubagent, parent p: UnifiedSession) -> UnifiedSession {
        UnifiedSession(
            id: s.id,
            source: .claudeCLI,
            pid: nil, cwd: p.cwd, name: s.description.isEmpty ? s.agentType : s.description,
            title: nil, model: nil, effort: nil, branch: p.branch, worktreeName: p.worktreeName,
            originator: "subagent",
            status: .busy, waitingFor: nil, terminal: .dead, updatedAt: s.updatedAt)
    }

    /// Codex has no status field; approximate from how recently the rollout was written.
    static func codexStatus(mtime: Date) -> UnifiedSession.Status {
        Date().timeIntervalSince(mtime) < 90 ? .busy : .idle
    }

    // MARK: Ordering

    static func order(_ a: UnifiedSession, _ b: UnifiedSession) -> Bool {
        if a.attention != b.attention { return a.attention.rank < b.attention.rank }
        let pa = a.projectName, pb = b.projectName
        if pa != pb { return pa.localizedCaseInsensitiveCompare(pb) == .orderedAscending }
        return (a.updatedAt ?? .distantPast) > (b.updatedAt ?? .distantPast)
    }
}
