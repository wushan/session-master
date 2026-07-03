import Foundation
import Observation
import AppKit
import SessionCore

/// Observable UI state: polls collectors on a timer (off the main thread) and exposes
/// unified sessions + actions. FSEvents-based watching is a later refinement.
@MainActor
@Observable
final class SessionStore {
    private(set) var sessions: [UnifiedSession] = []
    private(set) var subagentChildren: [String: [UnifiedSession]] = [:]
    /// The parent→child tree over `sessions` — built once per refresh so the menu-bar counts
    /// agree with what's actually visible (claimed companions render as collapsed children;
    /// counting them at top level shows badge numbers the user can't find in the list).
    private(set) var nodes: [SessionNode] = []
    private(set) var jobs: [ScheduledJob] = []
    private(set) var accessibilityTrusted = false
    private(set) var launchAtLogin = false
    private(set) var lastRefresh: Date?
    private(set) var hasLoaded = false           // first poll done? (loading vs empty)
    private(set) var availableUpdate: String?    // newer published version, if one exists
    var selectedTab: DashboardTab = .sessions    // which dashboard tab is shown
    var lastRecallMessage: String?

    private var timer: Timer?
    private var refreshing = false
    private var refreshStartedAt: Date?
    private var prevAttention: [String: UnifiedSession.Attention] = [:]
    private var notifyArmed = false
    private let settings = AppSettings.shared

    func start() {
        launchAtLogin = LoginItem.isEnabled
        Notifier.requestAuthorization()
        refresh()
        checkForUpdate()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private var lastUpdateCheck: Date?
    /// Check GitHub for a newer release, at most hourly. Surfaces `availableUpdate` for the UI.
    func checkForUpdate(force: Bool = false) {
        if !force, let last = lastUpdateCheck, Date().timeIntervalSince(last) < 3600 { return }
        lastUpdateCheck = Date()
        Task { [weak self] in
            let latest = await Updater.latest()
            guard let self, let latest else { return }
            self.availableUpdate = Updater.isNewer(latest, than: Updater.currentVersion) ? latest : nil
        }
    }

    func refresh() {
        // Skip only while a refresh is genuinely in flight. If a prior one wedged (a hung
        // subprocess despite Shell's timeout, an unexpected error), let a new one through after a
        // grace period so polling can never stop permanently.
        if refreshing, let started = refreshStartedAt, Date().timeIntervalSince(started) < 20 { return }
        refreshing = true
        refreshStartedAt = Date()
        Task.detached(priority: .utility) {
            let snap = SessionAggregator.snapshot()
            let jobs = ScheduleAggregator.all()
            let trusted = Recaller.accessibilityTrusted()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.sessions = snap.sessions
                self.subagentChildren = snap.subagents
                self.nodes = SessionTree.build(snap.sessions, extraChildren: snap.subagents)
                self.jobs = jobs
                self.accessibilityTrusted = trusted
                self.lastRefresh = Date()
                self.hasLoaded = true
                self.refreshing = false
                self.detectAttentionTransitions()
                self.checkForUpdate()   // throttled to hourly inside
            }
        }
    }

    /// Notify (sound + banner) when a session newly needs the user — finished its turn or
    /// hit a permission prompt. Skips the first refresh so launch doesn't flood notifications.
    private func detectAttentionTransitions() {
        if notifyArmed, settings.notificationsEnabled {
            for s in sessions {
                guard let old = prevAttention[s.id], old != s.attention else { continue }
                switch s.attention {
                case .needsApproval:
                    Notifier.fire(title: s.displayTitle, body: "Needs your approval",
                                  soundName: "Funk", withSound: settings.soundEnabled)
                case .awaitingYou:
                    // Only a genuine turn-completion is news (it was working, or blocked on an
                    // approval). idle/ended → awaitingYou flips happen when the user themself
                    // resumes a session or a saved row goes live — notifying those is noise.
                    if old == .working || old == .needsApproval {
                        Notifier.fire(title: s.displayTitle, body: "Finished — your turn",
                                      soundName: "Glass", withSound: settings.soundEnabled)
                    }
                default: break
                }
            }
        }
        prevAttention = Dictionary(sessions.map { ($0.id, $0.attention) }, uniquingKeysWith: { a, _ in a })
        notifyArmed = true
    }

    /// Attention counts over top-level rows only (children are collapsed by default — a badge
    /// number the user can't see anywhere in the list reads as a phantom).
    var needsApprovalCount: Int { nodes.filter { $0.session.attention == .needsApproval }.count }
    var awaitingYouCount: Int { nodes.filter { $0.session.attention == .awaitingYou }.count }
    var workingCount: Int { nodes.filter { $0.session.attention == .working }.count }
    var needsYouCount: Int { needsApprovalCount + awaitingYouCount }

    func recall(_ s: UnifiedSession) {
        // Recall does subprocess (osascript/tmux), Accessibility, and a frontmost-wait — all of
        // which can take 100s of ms. Run it off the main thread so the UI never hitches, then hop
        // back to update the status line.
        Task.detached(priority: .userInitiated) {
            let outcome: RecallOutcome
            switch s.source {
            case .claudeDesktop:
                AppActivator.bringToFront(appNamed: "Claude"); outcome = .foregroundedApp("Claude")
            case .codexDesktop:
                // Codex registers codex://threads/<id> — navigate straight to the conversation.
                AppActivator.openDeeplink("codex://threads/\(s.id)"); outcome = .foregroundedApp("Codex")
            case .codexCLI:
                if s.terminal.terminalPID != nil || s.terminal.viaTmux {
                    outcome = Recaller.recall(s.recallTarget)
                } else if s.originator == "VSCode" {
                    AppActivator.bringToFront(appNamed: "Visual Studio Code"); outcome = .foregroundedApp("VS Code")
                } else {
                    AppActivator.bringToFront(appNamed: "Codex"); outcome = .foregroundedApp("Codex")
                }
            case .claudeCLI:
                outcome = Recaller.recall(s.recallTarget)
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.lastRecallMessage = self.describe(outcome, for: s)
                if case .needsAccessibility = outcome { self.requestAccessibility() }
            }
        }
    }

    private var resumingIds: Set<String> = []

    /// Reopen an ended CLI session: launch the chosen terminal running its resume command in its cwd.
    func resume(_ s: UnifiedSession) {
        guard let cmd = s.resumeCommand else { return }
        // A double-click (or two clicks before the next poll notices the new process) would
        // launch two terminals attached to the same session — guard per id for a few seconds.
        guard resumingIds.insert(s.id).inserted else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.resumingIds.remove(s.id)
        }
        // Need a real folder: `cd '' || exit 1` does NOT abort (empty operand is a no-op), so an
        // empty cwd would silently resume in $HOME — the wrong place. Refuse instead.
        guard !s.cwd.isEmpty else {
            lastRecallMessage = "Can’t resume “\(s.displayTitle)” — its folder is unknown."
            return
        }
        // The Desktop store outlives the CLI's transcript retention: a session whose history was
        // cleaned up would open a terminal that just prints "No conversation found" and exits.
        if s.source.isClaude,
           ClaudeHistoryEnricher.transcriptURL(sessionId: s.id, cwd: s.cwd) == nil {
            lastRecallMessage = "Can’t resume “\(s.displayTitle)” — its history is no longer on disk."
            return
        }
        // The folder gone — old behaviour ran `cd` into a missing dir, so the terminal opened and
        // instantly closed with no clue why. If it was a git worktree (merged branch → pruned
        // worktree), offer to recreate it; the transcript is intact and keyed to this exact path.
        if !FileManager.default.fileExists(atPath: s.cwd) {
            handleMissingFolder(s, command: cmd); return
        }
        launchResume(s, command: cmd)
    }

    private func launchResume(_ s: UnifiedSession, command cmd: String) {
        let terminal = settings.resumeTerminal
        let cwd = s.cwd
        lastRecallMessage = "Resuming “\(s.displayTitle)” in \(terminal.rawValue)…"
        // File IO + `open` off the main thread (like recall) so the UI never hitches.
        Task.detached(priority: .userInitiated) {
            TerminalLauncher.run(command: cmd, cwd: cwd, terminal: terminal)
        }
    }

    /// The session's folder no longer exists. If it's a recreatable `.claude/worktrees/...` worktree
    /// (repo present, branch still exists), prompt to recreate it and resume; otherwise explain why
    /// resume can't proceed instead of silently flashing a terminal open and shut.
    /// The git probes run off the main thread (a stalled git would otherwise freeze the whole UI
    /// for up to Shell's watchdog) — only the alerts hop back.
    private func handleMissingFolder(_ s: UnifiedSession, command cmd: String) {
        let path = s.cwd
        Task.detached(priority: .userInitiated) {
            let repo = GitWorktree.repoRootForWorktreePath(path)
            let recreatable: Bool
            if let repo, FileManager.default.fileExists(atPath: repo),
               let branch = s.branch, !branch.isEmpty, branch != "HEAD",
               GitWorktree.branchExists(branch, repo: repo) { recreatable = true }
            else { recreatable = false }
            await MainActor.run { [weak self] in
                guard let self else { return }
                if recreatable, let repo, let branch = s.branch {
                    self.promptRecreateWorktree(s, command: cmd, path: path, repo: repo, branch: branch)
                } else {
                    let alert = NSAlert()
                    alert.messageText = "Can’t resume “\(s.displayTitle)”"
                    alert.informativeText = "Its folder no longer exists:\n\(path)\n\nThe conversation history is intact, but its working directory is gone, so it can’t be reopened from here."
                    alert.addButton(withTitle: "OK")
                    NSApp.activate(ignoringOtherApps: true)
                    alert.runModal()
                    self.lastRecallMessage = "Can’t resume — “\(path)” no longer exists."
                }
            }
        }
    }

    private func promptRecreateWorktree(_ s: UnifiedSession, command cmd: String,
                                        path: String, repo: String, branch: String) {
        let alert = NSAlert()
        alert.messageText = "Recreate worktree to resume?"
        alert.informativeText = "The folder for “\(s.displayTitle)” is gone:\n\(path)\n\nIt was a git worktree on branch “\(branch)” that’s since been removed. The conversation history is intact — recreate the worktree to resume it."
        alert.addButton(withTitle: "Recreate & Resume")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            lastRecallMessage = "Resume cancelled."
            return
        }
        lastRecallMessage = "Recreating worktree for “\(s.displayTitle)”…"
        Task.detached(priority: .userInitiated) {
            let ok = GitWorktree.recreate(path: path, branch: branch, repo: repo)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if ok { self.launchResume(s, command: cmd) }
                else { self.lastRecallMessage = "Couldn’t recreate the worktree at “\(path)”." }
            }
        }
    }

    /// Search ended sessions older than the default window for ones matching `query` (title / last
    /// prompt / branch / cwd). Runs the transcript scan off the main thread. Excludes ids already
    /// loaded so results only add older matches.
    func searchOlder(_ query: String) async -> [UnifiedSession] {
        let exclude = Set(sessions.map(\.id))
        return await Task.detached(priority: .userInitiated) {
            SessionAggregator.searchEndedSessions(query: query, excluding: exclude)
        }.value
    }

    /// Resolve the session's real worktree (feature-branch worktree, not the repo root).
    func effectivePath(_ s: UnifiedSession) -> String {
        GitWorktree.effectivePath(branch: s.branch, cwd: s.cwd, isWorktree: s.isWorktree)
    }
    func openInVSCode(_ s: UnifiedSession) { openInEditor(effectivePath(s)) }
    func openInVSCode(path: String) { openInEditor(path) }
    private func openInEditor(_ path: String) {
        // Read settings on the main actor, then launch off it (the editor command may block).
        let appName = settings.editor.appName
        let custom = settings.editor == .custom ? settings.customEditorCommand : nil
        Task.detached(priority: .userInitiated) {
            EditorOpener.open(path: path, appName: appName, customCommand: custom)
        }
    }
    func revealInFinder(_ s: UnifiedSession) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: effectivePath(s))])
    }
    func setTitle(_ title: String?, for s: UnifiedSession) {
        CustomTitles.set(title, for: s.id)
        refresh()
    }
    func toggleLaunchAtLogin() { LoginItem.setEnabled(!launchAtLogin); launchAtLogin = LoginItem.isEnabled }
    func requestAccessibility() { _ = Recaller.ensureAccessibility(prompt: true) }
    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func describe(_ o: RecallOutcome, for s: UnifiedSession) -> String {
        switch o {
        case .raisedWindow(let t, let other, let otherSpace):
            let note = otherSpace ? " — switched to its desktop ↗︎"
                     : (other ? " — on your other display ↗︎" : "")
            return "Focused “\(t)”" + note
        case .appleScriptSwitched:    return "Switched to \(s.terminal.terminalApp ?? "terminal")"
        case .tmuxSwitched(let t):    return "tmux → \(t)"
        case .foregroundedApp(let n): return "Brought \(n) to front"
        case .exposedWindows(let n):  return "Click your window in \(n)’s Exposé ↧"
        case .needsAccessibility:     return "Grant Accessibility to recall windows"
        case .notFound:               return "Couldn’t locate that window"
        case .failed(let m):          return m
        }
    }
}
