import Foundation

/// A Claude Code sub-agent (Task tool) spawned by a session.
public struct ClaudeSubagent: Sendable {
    public let id: String           // "agent-<hex>"
    public let agentType: String    // "Explore" | "general-purpose" | "code-reviewer" | …
    public let description: String  // the task description shown to the user
    public let updatedAt: Date?     // transcript mtime (last activity)
}

/// Claude sub-agents live as `agent-<id>.meta.json` (+ a matching `.jsonl` transcript) under
/// `~/.claude/projects/<encoded-cwd>/<sessionId>/subagents/`. The parent→child link is the
/// directory itself (named after the parent session id).
///
/// Only *running* sub-agents are surfaced. There is no completion marker in the meta file, so the
/// transcript's mtime is the only "still active" signal: a sub-agent counts as running while its
/// `.jsonl` was written within `runningWindow`. This also drops workflow-internal agents (which
/// write a meta but no `.jsonl` here) — those belong to a workflow, not a standalone Task.
public enum ClaudeSubagentScanner {
    static let runningWindow: TimeInterval = 180

    private static let lock = NSLock()
    // Parsed meta (immutable once written) cached by the subagents-dir mtime, which bumps only when
    // a new agent appears; the per-call running filter re-stats the live `.jsonl` separately.
    nonisolated(unsafe) private static var cache: [String: (sig: String, metas: [Meta])] = [:]
    struct Meta { let id: String; let type: String; let desc: String }

    public static func scan(sessionId: String, cwd: String, now: Date = Date()) -> [ClaudeSubagent] {
        let dir = ClaudeHistoryEnricher.projectsDir
            .appendingPathComponent(ClaudeHistoryEnricher.encode(cwd: cwd))
            .appendingPathComponent(sessionId)
            .appendingPathComponent("subagents")
        guard let dirMtime = mtime(dir) else { return [] }

        let sig = String(dirMtime.timeIntervalSince1970)
        lock.lock(); let cached = cache[dir.path]; lock.unlock()
        let metas: [Meta]
        if let cached, cached.sig == sig {
            metas = cached.metas
        } else {
            let fm = FileManager.default
            let entries = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            var parsed: [Meta] = []
            for url in entries where url.lastPathComponent.hasSuffix(".meta.json") {
                guard let data = try? Data(contentsOf: url),
                      let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
                parsed.append(Meta(
                    id: url.lastPathComponent.replacingOccurrences(of: ".meta.json", with: ""),
                    type: (d["agentType"] as? String) ?? "agent",
                    desc: (d["description"] as? String) ?? ""))
            }
            lock.lock(); cache[dir.path] = (sig, parsed); lock.unlock()
            metas = parsed
        }

        var out: [ClaudeSubagent] = []
        for m in metas {
            let jsonl = dir.appendingPathComponent("\(m.id).jsonl")
            guard let mt = mtime(jsonl), now.timeIntervalSince(mt) < runningWindow else { continue }
            out.append(ClaudeSubagent(id: m.id, agentType: m.type, description: m.desc, updatedAt: mt))
        }
        return out.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
    }

    static func mtime(_ u: URL) -> Date? {
        (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
