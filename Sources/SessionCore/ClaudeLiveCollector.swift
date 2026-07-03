import Foundation

/// A live Claude Code CLI session, read from `~/.claude/sessions/{pid}.json`.
/// This is the authoritative source for which CLI sessions are running and their status —
/// process-name scanning is unreliable because the CLI renames its own process.
public struct LiveClaudeSession: Sendable, Identifiable {
    public let pid: pid_t
    public let sessionId: String
    public let cwd: String
    public let status: String          // "busy" | "waiting" | "idle"
    /// Claude's session summary; it is also the terminal window title (sans spinner),
    /// which makes it the reliable key for Accessibility-based window recall.
    public let name: String?
    /// How `name` was set: "derived" means Claude auto-derived it from the worktree/cwd (an ugly
    /// slug like "dazzling-williamson-d051b8-6e"); a user/AI-set name has a different/absent source.
    public let nameSource: String?
    public let kind: String?           // "interactive" | ...
    public let version: String?
    public let entrypoint: String?
    public let waitingFor: String?
    /// The owning process's start time in ctime format ("Wed Jul  1 06:50:48 2026") — written by
    /// the CLI precisely to disambiguate pid recycling after a crash/reboot.
    public let procStart: String?
    public let startedAt: Date?
    public let updatedAt: Date?

    public var id: String { sessionId }
}

public enum ClaudeLiveCollector {

    public static var sessionsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions")
    }

    /// Parse every `*.json` under ~/.claude/sessions. Skips files whose pid is no longer alive —
    /// including recycled pids: a stale file left by a crash/power-loss whose pid was reassigned
    /// to some other process must not resurrect as a phantom live session (frozen in its last
    /// status, permanently blocking the real ended/resumable row). The CLI only unlinks these
    /// files on graceful exit, so `procStart` vs the actual process start time is the tiebreak.
    public static func sessions(includeDead: Bool = false) -> [LiveClaudeSession] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: sessionsDir,
                includingPropertiesForKeys: nil) else { return [] }
        var out: [LiveClaudeSession] = []
        for url in files where url.pathExtension == "json" {
            guard let s = parse(url) else { continue }
            if includeDead { out.append(s); continue }
            guard ProcessCollector.isAlive(s.pid) else { continue }
            if let recorded = s.procStart.flatMap(ctimeDate),
               let actual = ProcessCollector.startTime(of: s.pid),
               abs(actual.timeIntervalSince(recorded)) > 15 { continue }   // recycled pid
            out.append(s)
        }
        return out
    }

    /// Parse the CLI's ctime-format procStart ("Wed Jul  1 06:50:48 2026" — single-digit days
    /// are double-space padded, hence the collapse). Local time, matching what the CLI wrote.
    static func ctimeDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return f.date(from: s.replacingOccurrences(of: "  ", with: " "))
    }

    static func parse(_ url: URL) -> LiveClaudeSession? {
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pidNum = raw["pid"] as? Int,
              let sessionId = raw["sessionId"] as? String,
              let cwd = raw["cwd"] as? String else { return nil }
        return LiveClaudeSession(
            pid: pid_t(pidNum),
            sessionId: sessionId,
            cwd: cwd,
            status: (raw["status"] as? String) ?? "idle",
            name: raw["name"] as? String,
            nameSource: raw["nameSource"] as? String,
            kind: raw["kind"] as? String,
            version: raw["version"] as? String,
            entrypoint: raw["entrypoint"] as? String,
            waitingFor: raw["waitingFor"] as? String,
            procStart: raw["procStart"] as? String,
            startedAt: msDate(raw["startedAt"]),
            updatedAt: msDate(raw["updatedAt"])
        )
    }

    static func msDate(_ any: Any?) -> Date? {
        guard let ms = any as? Double ?? (any as? Int).map(Double.init) else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }
}
