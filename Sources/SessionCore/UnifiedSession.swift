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
        case unknown

        public var label: String {
            switch self {
            case .needsApproval: return "Needs approval"
            case .awaitingYou:   return "Your turn"
            case .working:       return "Working"
            case .idle:          return "Idle"
            case .unknown:       return "—"
            }
        }
        public var rank: Int {
            switch self {
            case .needsApproval: return 0; case .awaitingYou: return 1
            case .working: return 2; case .idle: return 3; case .unknown: return 4
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

    public init(id: String, source: Source, pid: pid_t?, cwd: String, name: String?, title: String?,
                model: String?, effort: String?, branch: String?, worktreeName: String?,
                originator: String?, status: Status, waitingFor: String?,
                terminal: TerminalInfo, updatedAt: Date?, isAutomationRun: Bool = false) {
        self.id = id; self.source = source; self.pid = pid; self.cwd = cwd; self.name = name
        self.title = title; self.model = model; self.effort = effort; self.branch = branch
        self.worktreeName = worktreeName; self.originator = originator; self.status = status
        self.waitingFor = waitingFor; self.terminal = terminal; self.updatedAt = updatedAt
        self.isAutomationRun = isAutomationRun
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
    public var isWorktree: Bool {
        worktreeName != nil || cwd.contains("/.claude/worktrees/") || cwd.contains("/.codex/worktrees/")
    }
    public var displayTitle: String { name ?? title ?? projectName }

    /// Derived attention state. For interactive Claude sessions, `idle` is "your turn";
    /// for Codex background/automation rollouts, `idle` is just "not recently active".
    public var attention: Attention {
        switch status {
        case .waiting: return .needsApproval
        case .busy:    return .working
        case .idle:    return (source == .claudeCLI || source == .claudeDesktop) ? .awaitingYou : .idle
        case .shell:   return .idle      // dropped to a shell inside the session
        case .unknown: return .unknown
        }
    }
    public var shortModel: String? { model?.replacingOccurrences(of: "claude-", with: "") }
    public var recallTarget: RecallTarget { RecallTarget(cwd: cwd, windowTitleHint: name, terminal: terminal) }

    public var canRecall: Bool {
        switch source {
        case .claudeCLI, .codexCLI: return terminal.terminalPID != nil || originator == "VSCode"
        case .claudeDesktop, .codexDesktop: return true
        }
    }
}

/// Builds and enriches unified sessions from every collector.
public enum SessionAggregator {

    public static func all() -> [UnifiedSession] { snapshot().sessions }

    /// Top-level sessions plus a map of parent id → sub-agent children (Codex sub-agents).
    public static func snapshot() -> (sessions: [UnifiedSession], subagents: [String: [UnifiedSession]]) {
        let claude = claudeSessions()
        let codexRaw = filterCodex(CodexSessionCollector.recent())
        let codex = codexRaw.map(unified(from:))
        var subagents: [String: [UnifiedSession]] = [:]
        for c in codexRaw {
            let subs = CodexSubagentScanner.scan(rollout: c.url)
            if !subs.isEmpty { subagents[c.id] = subs.map { subagentSession($0, parent: c) } }
        }
        return ((claude + codex).sorted(by: order), subagents)
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
            let isCLI = t.terminalApp != nil
            var model: String?, effort: String?, branch: String?, title: String?, worktree: String?

            if let d = desktop[s.sessionId] {          // Desktop session metadata
                model = d.model; effort = d.effort; title = d.title
                branch = d.branch; worktree = d.worktreeName
            }
            if model == nil || branch == nil {          // fall back to CLI transcript
                if let h = ClaudeHistoryEnricher.enrich(sessionId: s.sessionId, cwd: s.cwd) {
                    model = model ?? h.model; branch = branch ?? h.branch
                }
            }
            return UnifiedSession(
                id: s.sessionId,
                source: isCLI ? .claudeCLI : .claudeDesktop,
                pid: s.pid, cwd: s.cwd, name: s.name, title: title,
                model: model, effort: effort, branch: branch, worktreeName: worktree,
                originator: nil,
                status: UnifiedSession.Status(rawValue: s.status) ?? .unknown,
                waitingFor: s.waitingFor, terminal: t, updatedAt: s.updatedAt)
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
                out.append(c)
            }
        }
        return out + latestAutomation.values
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
