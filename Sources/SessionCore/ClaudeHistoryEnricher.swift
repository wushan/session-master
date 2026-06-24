import Foundation

/// Metadata recovered from a Claude CLI session's transcript (`~/.claude/projects/.../<id>.jsonl`).
public struct ClaudeHistory: Sendable {
    public let model: String?
    public let branch: String?
    public let aiTitle: String?
    public let lastPrompt: String?
    public let prNumber: Int?
    public let prURL: String?
}

/// Claude CLI sessions only record pid/cwd/name/status in `~/.claude/sessions`. The
/// model and git branch live in the project transcript — recovered here from its tail.
public enum ClaudeHistoryEnricher {
    static var projectsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    }

    /// Project directory names dash-encode the cwd (each `/` and `.` becomes `-`).
    static func encode(cwd: String) -> String {
        String(cwd.map { ($0 == "/" || $0 == ".") ? "-" : $0 })
    }

    public static func transcriptURL(sessionId: String, cwd: String) -> URL? {
        let fm = FileManager.default
        let direct = projectsDir.appendingPathComponent(encode(cwd: cwd))
            .appendingPathComponent("\(sessionId).jsonl")
        if fm.fileExists(atPath: direct.path) { return direct }
        // Fallback: exotic paths may encode differently — search project dirs by id.
        guard let dirs = try? fm.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: nil)
        else { return nil }
        for d in dirs {
            let f = d.appendingPathComponent("\(sessionId).jsonl")
            if fm.fileExists(atPath: f.path) { return f }
        }
        return nil
    }

    static let cache = FileCache<ClaudeHistory>()

    public static func enrich(sessionId: String, cwd: String) -> ClaudeHistory? {
        guard let url = transcriptURL(sessionId: sessionId, cwd: cwd) else { return nil }
        return cache.value(path: url.path, stamp: fileStamp(url)) {
            var model: String?, branch: String?, aiTitle: String?, lastPrompt: String?
            var prNumber: Int?, prURL: String?
            for d in JSONLReader.tailObjects(url).reversed() {
                // Only accept real model ids; Claude writes "<synthetic>" system turns
                // (often the very last record) that must not be shown as the model.
                if model == nil, let m = (d["message"] as? [String: Any])?["model"] as? String,
                   m.hasPrefix("claude-") { model = m }
                if branch == nil, let b = d["gitBranch"] as? String, b != "HEAD", !b.isEmpty { branch = b }
                switch d["type"] as? String {
                case "ai-title":   if aiTitle == nil { aiTitle = d["aiTitle"] as? String }
                case "last-prompt": if lastPrompt == nil { lastPrompt = d["lastPrompt"] as? String }
                case "pr-link":
                    if prNumber == nil { prNumber = d["prNumber"] as? Int; prURL = d["prUrl"] as? String }
                default: break
                }
            }
            return ClaudeHistory(model: model, branch: branch, aiTitle: aiTitle,
                                 lastPrompt: lastPrompt, prNumber: prNumber, prURL: prURL)
        }
    }
}
