import Foundation

public struct CodexSubagent: Sendable { public let id: String; public let nickname: String }

/// Codex sessions spawn sub-agents (each its own rollout). The parent→child link only
/// exists in the parent rollout's `spawn_agent` tool output: {"agent_id":"…","nickname":"…"}.
/// We scan for those, caching by file size so the multi-MB read happens only when it grows.
public enum CodexSubagentScanner {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: (size: Int, subs: [CodexSubagent])] = [:]

    private static let regex = try? NSRegularExpression(
        pattern: #"\{"agent_id":"([^"]+)","nickname":"([^"]+)"\}"#)

    public static func scan(rollout url: URL) -> [CodexSubagent] {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
        else { return [] }
        lock.lock(); let cached = cache[url.path]; lock.unlock()
        if let cached, cached.size == size { return cached.subs }

        guard let data = try? Data(contentsOf: url),
              let raw = String(data: data, encoding: .utf8), let regex else { return [] }
        // The spawn_agent result is JSON embedded inside a JSON string, so its quotes are
        // backslash-escaped (\"agent_id\":\"…\"). Unescape once so the pattern matches.
        let text = raw.replacingOccurrences(of: "\\\"", with: "\"")
        var byId: [String: String] = [:]   // last nickname wins
        let ns = text as NSString
        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m, m.numberOfRanges == 3 else { return }
            byId[ns.substring(with: m.range(at: 1))] = ns.substring(with: m.range(at: 2))
        }
        let subs = byId.map { CodexSubagent(id: $0.key, nickname: $0.value) }
            .sorted { $0.nickname < $1.nickname }
        lock.lock(); cache[url.path] = (size, subs); lock.unlock()
        return subs
    }
}
