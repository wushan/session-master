import Foundation

/// A session plus its child sessions (Codex companions spawned by a Claude session).
public struct SessionNode: Identifiable, Sendable {
    public let session: UnifiedSession
    public let children: [UnifiedSession]
    public var id: String { session.id }
    public var hasChildren: Bool { !children.isEmpty }
}

/// Builds the parent→child tree. A Codex session launched by Claude Code (its `originator`)
/// is nested under the Claude session sharing the same project and branch.
public enum SessionTree {
    /// `extraChildren` maps a parent session id to additional children (e.g. Codex sub-agents).
    public static func build(_ sessions: [UnifiedSession],
                             extraChildren: [String: [UnifiedSession]] = [:]) -> [SessionNode] {
        var claudeByKey: [String: UnifiedSession] = [:]
        var claudeByRoot: [String: [UnifiedSession]] = [:]
        for s in sessions where s.source.isClaude {
            claudeByRoot[s.projectRoot, default: []].append(s)
            if let b = s.branch, !b.isEmpty { claudeByKey[key(s.projectRoot, b)] = s }
        }

        var childrenOf = extraChildren
        var claimed = Set<String>()
        for s in sessions where s.source.isCodex && s.originator == "Claude Code" {
            guard let b = s.branch, !b.isEmpty else { continue }
            // Prefer an exact project+branch match. If none (e.g. the Claude session's branch is
            // unknown — its transcript can record "HEAD"), fall back to the *only* Claude session
            // in that project root.
            let root = claudeByRoot[s.projectRoot]
            guard let parent = claudeByKey[key(s.projectRoot, b)]
                    ?? (root?.count == 1 ? root?.first : nil) else { continue }
            childrenOf[parent.id, default: []].append(s)
            claimed.insert(s.id)
        }

        return sessions
            .filter { !claimed.contains($0.id) }
            .map { SessionNode(session: $0, children: childrenOf[$0.id] ?? []) }
    }

    static func key(_ project: String, _ branch: String) -> String { project + "\u{1}" + branch }
}
