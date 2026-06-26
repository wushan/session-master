import Foundation

/// A dynamic Workflow run (the Workflow tool's multi-agent orchestration) spawned by a session.
public struct ClaudeWorkflow: Sendable {
    public let id: String        // "wf_<id>"
    public let name: String      // human name, e.g. "s2s-postback-design-review"
    public let startedAt: Date?
}

/// Workflow runs live under `~/.claude/projects/<encoded-cwd>/<sessionId>/workflows/`:
/// `scripts/<name>-wf_<id>.js` is written when a run starts; `wf_<id>.json` (the journal) is written
/// only when it completes. So a script with **no** matching journal is an in-progress run — the
/// only ones surfaced here. A run that never produced a journal after `maxRun` is treated as
/// abandoned so a dead run doesn't linger forever.
public enum ClaudeWorkflowScanner {
    static let maxRun: TimeInterval = 3 * 3600

    public static func scan(sessionId: String, cwd: String, now: Date = Date()) -> [ClaudeWorkflow] {
        let base = ClaudeHistoryEnricher.projectsDir
            .appendingPathComponent(ClaudeHistoryEnricher.encode(cwd: cwd))
            .appendingPathComponent(sessionId)
            .appendingPathComponent("workflows")
        let fm = FileManager.default
        // Completed runs: wf_<id>.json journals at the workflows/ root.
        let journals = (try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
        let completed = Set(journals.filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent })
        // Each run's script: scripts/<name>-wf_<id>.js, written at start.
        let scripts = (try? fm.contentsOfDirectory(at: base.appendingPathComponent("scripts"),
                        includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var out: [ClaudeWorkflow] = []
        for url in scripts where url.pathExtension == "js" {
            let stem = url.deletingPathExtension().lastPathComponent   // "<name>-wf_<id>"
            // The wf id is the trailing token, so anchor on the LAST "-wf_" (a workflow name may
            // itself contain it) — otherwise a completed run could split wrong and never match its
            // journal, showing as running forever.
            guard let r = stem.range(of: "-wf_", options: .backwards) else { continue }
            let wfId = "wf_" + stem[r.upperBound...]
            guard !completed.contains(wfId) else { continue }          // finished → not running
            let started = ClaudeSubagentScanner.mtime(url)
            if let started, now.timeIntervalSince(started) > maxRun { continue }   // abandoned
            out.append(ClaudeWorkflow(id: wfId, name: String(stem[..<r.lowerBound]), startedAt: started))
        }
        return out.sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
    }
}
