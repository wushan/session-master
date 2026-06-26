import Foundation

/// A recently-ended Claude CLI session — recovered from its transcript (which persists even after
/// the terminal is closed and the `~/.claude/sessions/{pid}.json` file is gone). Lets you *resume*
/// (`claude --resume <id>`) a session you closed, rather than only recall a still-open window.
public struct EndedClaudeSession: Sendable {
    public let sessionId: String
    public let updatedAt: Date
    public let history: ClaudeHistory
}

public enum ClaudeEndedCollector {
    private static let lock = NSLock()
    // Walking ~/.claude/projects + stat-ing every transcript is the expensive part, and the set of
    // recently-touched transcripts barely changes — so cache it and refresh at most every ~30s.
    nonisolated(unsafe) private static var scanCache: (at: Date, items: [(sid: String, url: URL, m: Date)])?
    private static let rescan: TimeInterval = 30

    /// Transcripts modified within `within` whose session isn't currently live — newest first,
    /// capped. Live-exclusion is applied fresh on every call; only the directory walk is throttled.
    public static func recent(within: TimeInterval = 2 * 3600,
                              excluding live: Set<String>, limit: Int = 12) -> [EndedClaudeSession] {
        return candidates(within: within)
            .filter { !live.contains($0.sid) }
            .prefix(limit)
            .compactMap { c in
                ClaudeHistoryEnricher.parse(c.url).map {           // parse is itself mtime-cached
                    EndedClaudeSession(sessionId: c.sid, updatedAt: c.m, history: $0)
                }
            }
    }

    /// Recently-modified transcripts (newest first), cached for `rescan` seconds.
    private static func candidates(within: TimeInterval) -> [(sid: String, url: URL, m: Date)] {
        lock.lock()
        if let c = scanCache, Date().timeIntervalSince(c.at) < rescan { lock.unlock(); return c.items }
        lock.unlock()

        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-within)
        var found: [(sid: String, url: URL, m: Date)] = []
        if let en = fm.enumerator(at: ClaudeHistoryEnricher.projectsDir,
                includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]) {
            for case let url as URL in en {
                // Don't descend into a session's per-session subdirs: `subagents/agent-*.jsonl`
                // (Task sub-agents) and `workflows/` aren't resumable top-level sessions and would
                // otherwise surface as phantom "ended" rows (e.g. `claude --resume agent-…`).
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    let n = url.lastPathComponent
                    if n == "subagents" || n == "workflows" { en.skipDescendants() }
                    continue
                }
                guard url.pathExtension == "jsonl" else { continue }
                // A real session transcript is named <UUID>.jsonl; sub-agent files are agent-<hex>.
                let sid = url.deletingPathExtension().lastPathComponent
                guard UUID(uuidString: sid) != nil else { continue }
                guard let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate, m >= cutoff else { continue }
                found.append((sid, url, m))
            }
        }
        found.sort { $0.m > $1.m }
        lock.lock(); scanCache = (Date(), found); lock.unlock()
        return found
    }
}
