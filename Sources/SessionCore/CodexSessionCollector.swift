import Foundation

/// A Codex session (CLI / Desktop / VSCode — all write here), from a rollout file under
/// `~/.codex/sessions/YYYY/MM/DD/*.jsonl`. Liveness is inferred from file mtime since
/// Codex, unlike Claude, records no live pid/status file.
public struct CodexSession: Sendable, Identifiable {
    public let id: String
    public let cwd: String
    public let branch: String?
    public let originator: String?     // "Codex Desktop" | "codex-tui" | "codex_exec" | "Claude Code"
    public let model: String?
    public let effort: String?
    public var title: String?           // applied outside the rollout cache (renames independently)
    public let mtime: Date
    public let url: URL                 // rollout file (for sub-agent scanning)
    public let threadSource: String?    // "user" | "automation" | "subagent" | nil(companion)
    public let parentThreadId: String?  // subagent rollouts: the spawning rollout's id
    public let subagentRole: String?    // subagent rollouts: e.g. "review" (session_meta source.subagent)
}

public enum CodexSessionCollector {
    static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
    }
    static var indexURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/session_index.jsonl")
    }

    /// Recently-active sessions: rollouts modified within `within`, newest first, capped. The cap
    /// is generous so an active session (and its scanned sub-agents) isn't pushed off the list by
    /// a burst of other rollouts. 24h (not the old 3h) so a thread from this morning is still
    /// resumable this afternoon — the aggregator decides live/ended per rollout.
    public static func recent(within: TimeInterval = 24 * 3600, limit: Int = 60) -> [CodexSession] {
        let cutoff = Date().addingTimeInterval(-within)
        let titles = threadTitles()
        return candidates().lazy.filter { $0.1 >= cutoff }.prefix(limit)
            .compactMap { parse($0.0, mtime: $0.1, titles: titles) }
    }

    private static let scanLock = NSLock()
    nonisolated(unsafe) private static var scanCache: (at: Date, items: [(URL, Date)])?
    private static let rescan: TimeInterval = 15
    /// How far back the directory walk looks (same idea as ClaudeEndedCollector.scanWindow) —
    /// `recent` narrows from it, and search can span all of it.
    static let scanWindow: TimeInterval = 14 * 86400

    /// Recently-modified rollouts over `scanWindow`, newest first, cached for `rescan` seconds —
    /// the store holds every rollout ever written (600+ and growing), so walking + stat-ing it
    /// on every 2s tick is the expensive part, not the parsing (which is mtime-cached).
    /// Date directories (YYYY/MM/DD) far older than the window are pruned by name; the margin is
    /// generous because a long-lived rollout keeps its old creation dir while its mtime advances.
    static func candidates() -> [(URL, Date)] {
        scanLock.lock()
        if let c = scanCache, Date().timeIntervalSince(c.at) < rescan { scanLock.unlock(); return c.items }
        scanLock.unlock()

        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-scanWindow)
        let pruneBefore = Date().addingTimeInterval(-scanWindow - 30 * 86400)
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey, .isDirectoryKey]
        let rootDepth = root.pathComponents.count
        var found: [(URL, Date)] = []
        if let en = fm.enumerator(at: root, includingPropertiesForKeys: Array(keys)) {
            for case let url as URL in en {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    let comps = url.pathComponents
                    if comps.count == rootDepth + 3,                       // a YYYY/MM/DD leaf dir
                       let y = Int(comps[rootDepth]), let m = Int(comps[rootDepth + 1]),
                       let d = Int(comps[rootDepth + 2]),
                       let day = Calendar.current.date(from: DateComponents(year: y, month: m, day: d)),
                       day < pruneBefore {
                        en.skipDescendants()
                    }
                    continue
                }
                guard url.pathExtension == "jsonl",
                      let v = try? url.resourceValues(forKeys: keys), v.isRegularFile == true,
                      let m = v.contentModificationDate, m >= cutoff else { continue }
                found.append((url, m))
            }
        }
        found.sort { $0.1 > $1.1 }
        scanLock.lock(); scanCache = (Date(), found); scanLock.unlock()
        return found
    }

    static let cache = FileCache<CodexSession>()

    static func parse(_ url: URL, mtime: Date, titles: [String: String]) -> CodexSession? {
        // Re-parse only when the rollout changed; session_meta is immutable and the latest
        // turn_context only changes as the file grows (mtime stamp captures that). The title comes
        // from a *separate* index that can change without the rollout, so apply it OUTSIDE the cache
        // — otherwise a rename never shows until the rollout file happens to be rewritten.
        guard var s = cache.value(path: url.path, stamp: mtime.timeIntervalSince1970 * 1_000_000,
                                  compute: { parseUncached(url, mtime: mtime) }) else { return nil }
        s.title = titles[s.id]
        return s
    }

    static func parseUncached(_ url: URL, mtime: Date) -> CodexSession? {
        guard let first = JSONLReader.firstObject(url),
              first["type"] as? String == "session_meta",
              let p = first["payload"] as? [String: Any],
              let id = p["id"] as? String,
              let cwd = p["cwd"] as? String else { return nil }
        let git = p["git"] as? [String: Any]
        var model: String?
        var effort: String?
        for d in JSONLReader.tailObjects(url).reversed() where d["type"] as? String == "turn_context" {
            let tp = d["payload"] as? [String: Any]
            model = tp?["model"] as? String
            effort = tp?["effort"] as? String
            break
        }
        return CodexSession(id: id, cwd: cwd, branch: git?["branch"] as? String,
                            originator: p["originator"] as? String,
                            model: model, effort: effort, title: nil, mtime: mtime, url: url,
                            threadSource: p["thread_source"] as? String,
                            parentThreadId: p["parent_thread_id"] as? String,
                            subagentRole: (p["source"] as? [String: Any])?["subagent"] as? String)
    }

    private static let titlesLock = NSLock()
    nonisolated(unsafe) private static var titlesCache: (stamp: Double, map: [String: String])?

    static func threadTitles() -> [String: String] {
        let stamp = fileStamp(indexURL)
        titlesLock.lock(); let cached = titlesCache; titlesLock.unlock()
        if let cached, cached.stamp == stamp { return cached.map }
        // On a transient read failure (e.g. the index is momentarily locked), keep the last
        // good map rather than blanking every Codex session's title.
        guard let data = try? Data(contentsOf: indexURL),
              let s = String(data: data, encoding: .utf8) else { return cached?.map ?? [:] }
        var out: [String: String] = [:]
        for line in s.split(separator: "\n") {
            guard let d = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let id = d["id"] as? String, let t = d["thread_name"] as? String else { continue }
            out[id] = t
        }
        titlesLock.lock(); titlesCache = (stamp, out); titlesLock.unlock()
        return out
    }
}
