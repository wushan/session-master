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
    // The directory walk covers this whole span (cached); `recent` narrows to its own `within` from
    // it, and `matching` searches across all of it — so one scan serves both without conflicting cutoffs.
    // 90 days: "that conversation from last month" is exactly what deep search is for — a
    // fortnight matched nobody's memory of when they closed a session. The transcript store is
    // small (≈100 files), so the wider walk costs nothing meaningful.
    private static let scanWindow: TimeInterval = 90 * 86400

    /// Transcripts whose conversation progressed within `within` and whose session isn't currently
    /// live — newest first, capped. The mtime cutoff is only a cheap pre-filter; the real window
    /// check uses the transcript's newest CONTENT timestamp, because Claude Desktop batch-touches
    /// old transcripts (relaunch/sync) and a bare mtime window would resurrect weeks-dead sessions
    /// as "ended 20m ago". Live-exclusion is applied fresh on every call.
    public static func recent(within: TimeInterval = 24 * 3600,
                              excluding live: Set<String>, limit: Int = 20) -> [EndedClaudeSession] {
        let cutoff = Date().addingTimeInterval(-within)
        return candidates()
            .filter { $0.m >= cutoff && !live.contains($0.sid) }
            .prefix(limit)
            .compactMap { c -> EndedClaudeSession? in
                guard let h = ClaudeHistoryEnricher.parse(c.url) else { return nil }  // mtime-cached
                let updated = h.lastTimestamp ?? c.m
                guard updated >= cutoff else { return nil }
                return EndedClaudeSession(sessionId: c.sid, updatedAt: updated, history: h)
            }
    }

    /// Ended sessions across the full scan window whose transcript matches `query` (title / last
    /// prompt / branch / cwd) — lets the dashboard search surface an older closed session beyond
    /// the default recency window. Parses lazily, newest first, until `limit` matches (capped).
    public static func matching(query: String, excluding: Set<String>, limit: Int = 20) -> [EndedClaudeSession] {
        let q = query.lowercased()
        guard q.count >= 2 else { return [] }
        var out: [EndedClaudeSession] = []
        var scanned = 0
        for c in candidates() where !excluding.contains(c.sid) {
            scanned += 1
            if scanned > 1000 { break }
            guard let h = ClaudeHistoryEnricher.parse(c.url) else { continue }
            // Include the SessionMaster rename (CustomTitles) — a session renamed in the app has its
            // name in UserDefaults, not the transcript, so search must look there too or the name
            // you gave it can't find it.
            // "PR#758" so "#758", "758" and "pr#758" all hit the linked PR by substring.
            let hay = [CustomTitles.get(c.sid), h.customTitle, h.aiTitle, h.lastPrompt, h.branch, h.cwd,
                       h.prNumber.map { "PR#\($0)" }]
                .compactMap { $0 }.joined(separator: "\u{1}").lowercased()
            if hay.contains(q) {
                out.append(EndedClaudeSession(sessionId: c.sid, updatedAt: h.lastTimestamp ?? c.m,
                                              history: h))
                if out.count >= limit { break }
            }
        }
        return out
    }

    /// Recently-modified transcripts over `scanWindow` (newest first), cached for `rescan` seconds.
    private static func candidates() -> [(sid: String, url: URL, m: Date)] {
        lock.lock()
        if let c = scanCache, Date().timeIntervalSince(c.at) < rescan { lock.unlock(); return c.items }
        lock.unlock()

        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-scanWindow)
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
