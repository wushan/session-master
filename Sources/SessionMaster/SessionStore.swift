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
    private(set) var jobs: [ScheduledJob] = []
    private(set) var accessibilityTrusted = false
    private(set) var launchAtLogin = false
    private(set) var lastRefresh: Date?
    var lastRecallMessage: String?

    private var timer: Timer?
    private var refreshing = false

    func start() {
        launchAtLogin = LoginItem.isEnabled
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        Task.detached(priority: .utility) { [weak self] in
            let snap = SessionAggregator.snapshot()
            let jobs = ScheduleAggregator.all()
            let trusted = Recaller.accessibilityTrusted()
            await MainActor.run {
                guard let self else { return }
                self.sessions = snap.sessions
                self.subagentChildren = snap.subagents
                self.jobs = jobs
                self.accessibilityTrusted = trusted
                self.lastRefresh = Date()
                self.refreshing = false
            }
        }
    }

    var needsApprovalCount: Int { sessions.filter { $0.attention == .needsApproval }.count }
    var awaitingYouCount: Int { sessions.filter { $0.attention == .awaitingYou }.count }
    var workingCount: Int { sessions.filter { $0.attention == .working }.count }
    var needsYouCount: Int { needsApprovalCount + awaitingYouCount }

    func recall(_ s: UnifiedSession) {
        let outcome: RecallOutcome
        switch s.source {
        case .claudeDesktop:
            AppActivator.bringToFront(appNamed: "Claude"); outcome = .foregroundedApp("Claude")
        case .codexDesktop:
            // Codex registers codex://threads/<id> — navigate straight to the conversation.
            AppActivator.openDeeplink("codex://threads/\(s.id)"); outcome = .foregroundedApp("Codex")
        case .codexCLI:
            if s.terminal.terminalPID != nil {
                outcome = Recaller.recall(s.recallTarget)
            } else if s.originator == "VSCode" {
                AppActivator.bringToFront(appNamed: "Visual Studio Code"); outcome = .foregroundedApp("VS Code")
            } else {
                AppActivator.bringToFront(appNamed: "Codex"); outcome = .foregroundedApp("Codex")
            }
        case .claudeCLI:
            outcome = Recaller.recall(s.recallTarget)
            if case .needsAccessibility = outcome { requestAccessibility() }
        }
        lastRecallMessage = describe(outcome, for: s)
    }

    /// Resolve the session's real worktree (feature-branch worktree, not the repo root).
    func effectivePath(_ s: UnifiedSession) -> String {
        GitWorktree.effectivePath(branch: s.branch, cwd: s.cwd, isWorktree: s.isWorktree)
    }
    func openInVSCode(_ s: UnifiedSession) { VSCodeOpener.open(effectivePath(s)) }
    func openInVSCode(path: String) { VSCodeOpener.open(path) }
    func revealInFinder(_ s: UnifiedSession) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: effectivePath(s))])
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
        case .raisedWindow(let t, let other):
            return "Focused “\(t)”" + (other ? " — on your other display ↗︎" : "")
        case .appleScriptSwitched:    return "Switched to \(s.terminal.terminalApp ?? "terminal")"
        case .tmuxSwitched(let t):    return "tmux → \(t)"
        case .foregroundedApp(let n): return "Brought \(n) to front"
        case .needsAccessibility:     return "Grant Accessibility to recall windows"
        case .notFound:               return "Couldn’t locate that window"
        case .failed(let m):          return m
        }
    }
}
