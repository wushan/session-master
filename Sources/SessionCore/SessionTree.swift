import Foundation

/// A session plus its child sessions (Codex companions spawned by a Claude session).
public struct SessionNode: Identifiable, Sendable {
    public let session: UnifiedSession
    public let children: [UnifiedSession]
    public var id: String { session.id }
    public var hasChildren: Bool { !children.isEmpty }
}

/// Builds the parent→child tree. A Codex session driven by a Claude session — a `Claude Code`
/// companion or a `codex exec` run Claude kicked off — is nested under the Claude session sharing
/// the same project and branch.
public enum SessionTree {
    /// Codex originators that mean "spawned by a Claude session" (so they nest under it).
    static let claudeDriven: Set<String> = ["Claude Code", "codex_exec"]

    /// `extraChildren` maps a parent session id to additional children (e.g. Codex sub-agents).
    public static func build(_ sessions: [UnifiedSession],
                             extraChildren: [String: [UnifiedSession]] = [:]) -> [SessionNode] {
        var claudeByKey: [String: UnifiedSession] = [:]        // projectRoot + branch
        var claudeByPR: [String: UnifiedSession] = [:]         // projectRoot + PR number
        var claudeByWorktree: [String: UnifiedSession] = [:]   // projectRoot + worktree name
        var claudeByRoot: [String: [UnifiedSession]] = [:]
        for s in sessions where s.source.isClaude {
            claudeByRoot[s.projectRoot, default: []].append(s)
            if let b = s.branch, !b.isEmpty { claudeByKey[key(s.projectRoot, b)] = s }
            if let pr = s.rich.prNumber { claudeByPR[key(s.projectRoot, String(pr))] = s }
            if let wt = s.worktreeKey { claudeByWorktree[key(s.projectRoot, wt)] = s }
        }

        var childrenOf = extraChildren
        var claimed = Set<String>()
        for s in sessions where s.source.isCodex && claudeDriven.contains(s.originator ?? "") {
            // A companion's recorded branch is usually its own feature branch, not the parent's
            // worktree branch, so an exact branch match often misses. Match on branch OR the shared
            // PR number OR the shared worktree name (the Claude session may have been launched from
            // the repo root on `master` while driving the companion into a feature worktree — only
            // the worktree name links them), then fall back to the *only* Claude session in that
            // project root (also when the companion has no branch at all).
            let root = claudeByRoot[s.projectRoot]
            let byBranch = s.branch.flatMap { $0.isEmpty ? nil : claudeByKey[key(s.projectRoot, $0)] }
            let byPR = s.rich.prNumber.flatMap { claudeByPR[key(s.projectRoot, String($0))] }
            let byWorktree = s.worktreeKey.flatMap { claudeByWorktree[key(s.projectRoot, $0)] }
            guard let parent = byBranch ?? byPR ?? byWorktree ?? (root?.count == 1 ? root?.first : nil)
            else { continue }
            childrenOf[parent.id, default: []].append(s)
            claimed.insert(s.id)
        }

        return sessions
            .filter { !claimed.contains($0.id) }
            .map { SessionNode(session: $0, children: childrenOf[$0.id] ?? []) }
    }

    static func key(_ project: String, _ branch: String) -> String { project + "\u{1}" + branch }
}
