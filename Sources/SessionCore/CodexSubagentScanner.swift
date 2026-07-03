import Foundation

public struct CodexSubagent: Sendable { public let id: String; public let nickname: String }

/// Codex sessions spawn sub-agents (each its own rollout). In the legacy format the parent→child
/// link only exists in the parent rollout's `spawn_agent` tool output:
/// {"agent_id":"…","nickname":"…"} (newer rollouts carry `parent_thread_id` in the CHILD's
/// session_meta instead — handled by the aggregator; this scanner covers the old format).
///
/// Scanning is incremental: rollouts reach 100MB+ and are appended while a session is active, so
/// re-reading the whole file each 2s poll would burn CPU/memory forever. We remember how many
/// bytes were scanned per path and only read the appended slice (plus a small overlap so a match
/// spanning the boundary isn't lost).
public enum CodexSubagentScanner {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: (scanned: Int, byId: [String: String])] = [:]
    private static let overlap = 4096

    // agent_id constrained to a real UUID so quoted examples in conversation text (docs, code
    // reviews of this very file…) can't fabricate phantom children.
    private static let regex = try? NSRegularExpression(
        pattern: #"\{"agent_id":"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})","nickname":"([^"]{1,80})"\}"#)

    public static func scan(rollout url: URL) -> [CodexSubagent] {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
        else { return [] }
        lock.lock(); var entry = cache[url.path] ?? (0, [:]); lock.unlock()
        if size < entry.scanned { entry = (0, [:]) }             // truncated/replaced → rescan
        if size > entry.scanned, let regex {
            let start = max(0, entry.scanned - overlap)
            guard let fh = try? FileHandle(forReadingFrom: url) else { return subs(entry.byId) }
            defer { try? fh.close() }
            try? fh.seek(toOffset: UInt64(start))
            let data = (try? fh.read(upToCount: size - start)) ?? Data()
            // The spawn_agent result is JSON embedded inside a JSON string, so its quotes are
            // backslash-escaped (\"agent_id\":\"…\"). Unescape the slice so the pattern matches.
            let text = String(decoding: data, as: UTF8.self)
                .replacingOccurrences(of: "\\\"", with: "\"")
            let ns = text as NSString
            regex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                guard let m, m.numberOfRanges == 3 else { return }
                entry.byId[ns.substring(with: m.range(at: 1))] = ns.substring(with: m.range(at: 2))
            }
            entry.scanned = size
            lock.lock(); cache[url.path] = entry; lock.unlock()
        }
        return subs(entry.byId)
    }

    private static func subs(_ byId: [String: String]) -> [CodexSubagent] {
        byId.map { CodexSubagent(id: $0.key, nickname: $0.value) }.sorted { $0.nickname < $1.nickname }
    }
}
