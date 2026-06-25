import Foundation

/// A Codex session (CLI / Desktop / VSCode — all write here), from a rollout file under
/// `~/.codex/sessions/YYYY/MM/DD/*.jsonl`. Liveness is inferred from file mtime since
/// Codex, unlike Claude, records no live pid/status file.
public struct CodexSession: Sendable, Identifiable {
    public let id: String
    public let cwd: String
    public let branch: String?
    public let originator: String?     // "Codex Desktop" | "VSCode" | "CLI" | "Claude Code"
    public let model: String?
    public let effort: String?
    public var title: String?           // applied outside the rollout cache (renames independently)
    public let mtime: Date
    public let url: URL                 // rollout file (for sub-agent scanning)
    public let threadSource: String?    // "user" | "automation" | "subagent" | nil(companion)
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
    /// a burst of other rollouts.
    public static func recent(within: TimeInterval = 3 * 3600, limit: Int = 60) -> [CodexSession] {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-within)
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: Array(keys)) else { return [] }

        var candidates: [(URL, Date)] = []
        for case let url as URL in en where url.pathExtension == "jsonl" {
            guard let v = try? url.resourceValues(forKeys: keys),
                  v.isRegularFile == true,
                  let m = v.contentModificationDate, m >= cutoff else { continue }
            candidates.append((url, m))
        }
        candidates.sort { $0.1 > $1.1 }
        let titles = threadTitles()
        return candidates.prefix(limit).compactMap { parse($0.0, mtime: $0.1, titles: titles) }
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
                            threadSource: p["thread_source"] as? String)
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
