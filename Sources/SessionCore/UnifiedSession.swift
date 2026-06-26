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

    /// This session was started by a Claude routine, not a person.
    public var isRoutineRun: Bool { scheduledTaskId != nil }

    /// Optional enrichment (git state, PR, last prompt, context%) — filled by the aggregator.
    public var rich = SessionRich()

    public init(id: String, source: Source, pid: pid_t?, cwd: String, name: String?, title: String?,
                model: String?, effort: String?, branch: String?, worktreeName: String?,
                originator: String?, status: Status, waitingFor: String?,
                terminal: TerminalInfo, updatedAt: Date?, isAutomationRun: Bool = false,
                scheduledTaskId: String? = nil, isEnded: Bool = false) {
        self.id = id; self.source = source; self.pid = pid; self.cwd = cwd; self.name = name
        self.title = title; self.model = model; self.effort = effort; self.branch = branch
        self.worktreeName = worktreeName; self.originator = originator; self.status = status
        self.waitingFor = waitingFor; self.terminal = terminal; self.updatedAt = updatedAt
        self.isAutomationRun = isAutomationRun; self.scheduledTaskId = scheduledTaskId
        self.isEnded = isEnded
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
    /// No interaction for >48h — shown dimmed/grayscale (still recallable) to mark it as old.
    public var isStale: Bool {
        guard let u = updatedAt else { return false }
        return Date().timeIntervalSince(u) > 48 * 3600
    }
    public var displayTitle: String { rich.customTitle ?? name ?? title ?? projectName }
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
            // A live interactive Claude session sitting at the prompt = "your turn".
            // A saved Desktop session (no running process, pid == nil) is just idle.
            return (source.isClaude && pid != nil) ? .awaitingYou : .idle
        case .shell:   return .idle      // dropped to a shell inside the session
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
        if source == .codexCLI { return !canRecall }
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
        let codexRaw = filterCodex(CodexSessionCollector.recent())
        let codex = codexRaw.map(unified(from:))
        var subagents: [String: [UnifiedSession]] = [:]
        for c in codexRaw {
            let subs = CodexSubagentScanner.scan(rollout: c.url)
            if !subs.isEmpty { subagents[c.id] = subs.map { subagentSession($0, parent: c) } }
        }
        // Recently-ended Claude CLI sessions (terminal closed) — resumable, not currently shown.
        let shownIds = Set((claude + resumed + desktop).map(\.id))
        let ended = ClaudeEndedCollector.recent(excluding: shownIds).compactMap(endedSession(from:))

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
                sessions[i].rich.prNumber = pr.number
                sessions[i].rich.prURL = sessions[i].rich.prURL ?? pr.url
                sessions[i].rich.prState = pr.displayState
                sessions[i].rich.prReviewDecision = pr.reviewDecision
            }
        }
        return (sessions.sorted(by: order), subagents)
    }

    /// A recently-ended Claude CLI session, reconstructed from its transcript so it can be resumed.
    static func endedSession(from e: EndedClaudeSession) -> UnifiedSession? {
        guard let cwd = e.history.cwd, !cwd.isEmpty else { return nil }
        let h = e.history
        var u = UnifiedSession(
            id: e.sessionId, source: .claudeCLI, pid: nil, cwd: cwd, name: nil, title: h.aiTitle,
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
                scheduledTaskId: scheduledTaskId)
            u.rich.aiTitle = h?.aiTitle; u.rich.lastPrompt = h?.lastPrompt
            u.rich.prNumber = h?.prNumber; u.rich.prURL = h?.prURL
            u.rich.contextPercent = h?.contextPercent
            return u
        }
    }

    /// Live Claude CLI sessions found by reading process argv (`claude --resume <id>`), for the
    /// case where the CLI wrote no `~/.claude/sessions/{pid}.json` — e.g. a terminal resume of a
    /// Desktop-origin session. Excludes ids already surfaced from the live-state files.
    ///
    /// Status is reported as a stable `.idle` (→ "your turn" for a live interactive Claude session),
    /// NOT inferred busy/idle from the transcript mtime: a mtime heuristic would flip busy↔idle and
    /// fire a spurious "your turn" notification whenever a turn pauses (e.g. a slow tool run). The
    /// mtime is still used for `updatedAt` so the row sorts correctly and isn't shown as stale.
    static func claudeResumeSessions(excluding existing: Set<String>) -> [UnifiedSession] {
        let procs = ProcessCollector.claudeResumeProcesses().filter { !existing.contains($0.sessionId) }
        guard !procs.isEmpty else { return [] }
        let terms = ProcessCollector.correlateTerminals(pids: procs.map(\.pid))
        let desktop = ClaudeDesktopCollector.indexByCliSessionId()
        return procs.compactMap { p in
            let d = desktop[p.sessionId]
            let cwd = ProcessCollector.cwd(of: p.pid) ?? d?.cwd ?? d?.worktreePath ?? ""
            guard !cwd.isEmpty else { return nil }
            let mtime = ClaudeHistoryEnricher.transcriptMtime(sessionId: p.sessionId, cwd: cwd)
            let h = ClaudeHistoryEnricher.enrich(sessionId: p.sessionId, cwd: cwd)
            var u = UnifiedSession(
                id: p.sessionId, source: .claudeCLI, pid: p.pid, cwd: cwd,
                name: nil, title: d?.title,
                model: d?.model ?? h?.model, effort: d?.effort,
                branch: d?.branch ?? h?.branch, worktreeName: d?.worktreeName,
                originator: nil, status: .idle,
                waitingFor: nil, terminal: terms[p.pid] ?? .dead,
                updatedAt: mtime ?? d?.lastActivityAt, scheduledTaskId: d?.scheduledTaskId)
            u.rich.aiTitle = h?.aiTitle; u.rich.lastPrompt = h?.lastPrompt
            u.rich.prNumber = h?.prNumber; u.rich.prURL = h?.prURL
            u.rich.contextPercent = h?.contextPercent
            return u
        }
    }

    // MARK: Codex (recent rollouts)

    public static func codexSessions() -> [UnifiedSession] {
        filterCodex(CodexSessionCollector.recent()).map(unified(from:))
    }

    /// How long an automation run stays visible after its last activity, so you can follow up
    /// on a just-finished automation. Stale runs drop off (they live in the Automations tab).
    static let automationActiveWindow: TimeInterval = 30 * 60

    /// Drop bare sub-agent rollouts (shown nested). Keep manual sessions; keep automation runs
    /// only while recently active, deduped to the latest per project so the list stays clean.
    static func filterCodex(_ sessions: [CodexSession]) -> [CodexSession] {
        var latestAutomation: [String: CodexSession] = [:]
        var latestExec: [String: CodexSession] = [:]
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
                // Each `codex exec` invocation writes a fresh rollout, so repeated runs pile up on
                // the same worktree. Keep only the latest per (cwd, branch); SessionTree then nests
                // it under the driving Claude session.
                if c.originator == "codex_exec" {
                    let key = c.cwd + "\u{1}" + (c.branch ?? "")
                    if let prev = latestExec[key], prev.mtime >= c.mtime { continue }
                    latestExec[key] = c
                } else {
                    out.append(c)
                }
            }
        }
        return out + latestAutomation.values + latestExec.values
    }

    static func unified(from c: CodexSession) -> UnifiedSession {
        UnifiedSession(
            id: c.id,
            source: (c.originator == "Codex Desktop") ? .codexDesktop : .codexCLI,
            pid: nil, cwd: c.cwd, name: nil, title: c.title,
            model: c.model, effort: c.effort, branch: c.branch, worktreeName: nil,
            originator: c.originator,
            status: codexStatus(mtime: c.mtime),
            waitingFor: nil, terminal: .dead, updatedAt: c.mtime,
            isAutomationRun: c.threadSource == "automation")
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
