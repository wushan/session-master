import Foundation

/// Rich metadata for a Claude Desktop session, from
/// `~/Library/Application Support/Claude/claude-code-sessions/**/local_*.json`.
public struct DesktopSessionInfo: Sendable {
    public let cliSessionId: String?
    public let model: String?
    public let effort: String?
    public let title: String?
    public let branch: String?
    public let worktreeName: String?
    public let isArchived: Bool
    public let scheduledTaskId: String?
    public let lastActivityAt: Date?
}

public enum ClaudeDesktopCollector {
    static var dir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
    }

    static let cache = FileCache<DesktopSessionInfo>()

    /// Index Desktop sessions by their `cliSessionId`, which equals the live session's id.
    /// Each file is parsed only when its mtime changes (the dir is enumerated every poll).
    public static func indexByCliSessionId() -> [String: DesktopSessionInfo] {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { return [:] }
        var out: [String: DesktopSessionInfo] = [:]
        for case let url as URL in en where url.lastPathComponent.hasPrefix("local_")
            && url.pathExtension == "json" {
            guard let info = cache.value(path: url.path, stamp: fileStamp(url), compute: { parse(url) }),
                  let cli = info.cliSessionId else { continue }
            out[cli] = info
        }
        return out
    }

    static func parse(_ url: URL) -> DesktopSessionInfo? {
        guard let data = try? Data(contentsOf: url),
              let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let cli = d["cliSessionId"] as? String else { return nil }
        return DesktopSessionInfo(
            cliSessionId: cli,
            model: d["model"] as? String,
            effort: d["effort"] as? String,
            title: d["title"] as? String,
            branch: d["branch"] as? String,
            worktreeName: d["worktreeName"] as? String,
            isArchived: (d["isArchived"] as? Bool) ?? false,
            scheduledTaskId: d["scheduledTaskId"] as? String,
            lastActivityAt: msDate(d["lastActivityAt"])
        )
    }

    static func msDate(_ any: Any?) -> Date? {
        guard let ms = any as? Double ?? (any as? Int).map(Double.init) else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }
}
