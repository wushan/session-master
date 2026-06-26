import Foundation

/// A Claude Code sub-agent (Task tool) spawned by a session.
public struct ClaudeSubagent: Sendable {
    public let id: String           // "agent-<hex>"
    public let agentType: String    // "Explore" | "general-purpose" | "code-reviewer" | …
    public let description: String  // the task description shown to the user
    public let updatedAt: Date?
}

/// Claude sub-agents live as `agent-<id>.meta.json` (+ a matching `.jsonl` transcript) under
/// `~/.claude/projects/<encoded-cwd>/<sessionId>/subagents/`. The parent→child link is the
/// directory itself (named after the parent session id). Each meta file carries the agent type
/// and task description — enough to list them; the heavy `.jsonl` transcript is never read.
public enum ClaudeSubagentScanner {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: (sig: String, subs: [ClaudeSubagent])] = [:]

    public static func scan(sessionId: String, cwd: String) -> [ClaudeSubagent] {
        let dir = ClaudeHistoryEnricher.projectsDir
            .appendingPathComponent(ClaudeHistoryEnricher.encode(cwd: cwd))
            .appendingPathComponent(sessionId)
            .appendingPathComponent("subagents")
        func mtime(_ u: URL) -> Date? {
            (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }
        // Cheap cache: a meta file is written once when a sub-agent spawns, so the directory's own
        // mtime bumps exactly when a new one appears — one stat skips the readdir + N reads on the
        // common unchanged poll. (Absent dir → no sub-agents.)
        guard let dirMtime = mtime(dir) else { return [] }
        let sig = String(dirMtime.timeIntervalSince1970)
        lock.lock(); let cached = cache[dir.path]; lock.unlock()
        if let cached, cached.sig == sig { return cached.subs }

        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        let metas = entries.filter { $0.lastPathComponent.hasSuffix(".meta.json") }

        var subs: [ClaudeSubagent] = []
        for url in metas {
            guard let data = try? Data(contentsOf: url),
                  let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            subs.append(ClaudeSubagent(
                id: url.lastPathComponent.replacingOccurrences(of: ".meta.json", with: ""),
                agentType: (d["agentType"] as? String) ?? "agent",
                description: (d["description"] as? String) ?? "",
                updatedAt: mtime(url)))
        }
        subs.sort { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }   // newest first
        lock.lock(); cache[dir.path] = (sig, subs); lock.unlock()
        return subs
    }
}
