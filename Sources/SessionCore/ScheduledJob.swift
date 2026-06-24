import Foundation

/// A scheduled/recurring job: a Codex automation or a Claude routine.
public struct ScheduledJob: Identifiable, Sendable {
    public enum Source: String, Sendable { case codex = "Codex", claude = "Claude" }

    public let id: String
    public let source: Source
    public let name: String
    public let status: String?       // "ACTIVE"/"PAUSED" (Codex); nil for Claude routines
    public let rruleText: String?
    public let nextRun: Date?
    public let model: String?
    public let effort: String?
    public let cwds: [String]
    public let summary: String?
    public let updatedAt: Date?

    public var isPaused: Bool { (status ?? "").uppercased() == "PAUSED" }
    public var primaryCwd: String? { cwds.first }
}

public enum CodexAutomationCollector {
    static var dir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/automations")
    }

    public static func jobs() -> [ScheduledJob] {
        let fm = FileManager.default
        guard let subdirs = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        return subdirs.compactMap { sub in
            let toml = sub.appendingPathComponent("automation.toml")
            guard let text = try? String(contentsOf: toml, encoding: .utf8) else { return nil }
            let t = TOMLLite.parse(text)
            let status = t["status"] as? String
            let rrule = t["rrule"] as? String
            let active = (status ?? "ACTIVE").uppercased() != "PAUSED"
            return ScheduledJob(
                id: (t["id"] as? String) ?? sub.lastPathComponent,
                source: .codex,
                name: (t["name"] as? String) ?? sub.lastPathComponent,
                status: status,
                rruleText: rrule,
                nextRun: (active ? rrule.flatMap { RRule.parse($0).nextRun() } : nil),
                model: t["model"] as? String,
                effort: t["reasoning_effort"] as? String,
                cwds: (t["cwds"] as? [String]) ?? [],
                summary: (t["prompt"] as? String).map { String($0.prefix(140)) },
                updatedAt: (t["updated_at"] as? Int).map { Date(timeIntervalSince1970: Double($0) / 1000) }
            )
        }
    }
}

public enum ClaudeRoutinesCollector {
    static var dir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/scheduled-tasks")
    }

    public static func jobs() -> [ScheduledJob] {
        let fm = FileManager.default
        guard let subdirs = try? fm.contentsOfDirectory(at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        return subdirs.compactMap { sub in
            let skill = sub.appendingPathComponent("SKILL.md")
            guard let text = try? String(contentsOf: skill, encoding: .utf8) else { return nil }
            let front = frontmatter(text)
            let mtime = (try? skill.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            // Schedule lives in the harness, not on disk — so no rrule / next run here.
            return ScheduledJob(
                id: "claude:" + sub.lastPathComponent,
                source: .claude,
                name: front["name"] ?? sub.lastPathComponent,
                status: nil, rruleText: nil, nextRun: nil, model: nil, effort: nil,
                cwds: [], summary: front["description"], updatedAt: mtime)
        }
    }

    /// Parse the leading `--- key: value ---` YAML frontmatter block.
    static func frontmatter(_ text: String) -> [String: String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        var out: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let k = line[..<colon].trimmingCharacters(in: .whitespaces)
            let v = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            out[k] = v
        }
        return out
    }
}

public enum ScheduleAggregator {
    public static func all() -> [ScheduledJob] {
        (CodexAutomationCollector.jobs() + ClaudeRoutinesCollector.jobs())
            .sorted { ($0.nextRun ?? .distantFuture) < ($1.nextRun ?? .distantFuture) }
    }
}
