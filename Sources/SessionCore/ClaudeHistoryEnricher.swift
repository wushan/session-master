import Foundation

/// Metadata recovered from a Claude CLI session's transcript (`~/.claude/projects/.../<id>.jsonl`).
public struct ClaudeHistory: Sendable {
    public let model: String?
    public let branch: String?
    public let aiTitle: String?
    public let customTitle: String?  // the user's explicit rename (a "custom-title" marker)
    public let lastPrompt: String?
    public let prNumber: Int?
    public let prURL: String?
    public let contextPercent: Int?
    public let contextTokens: Int?   // raw token count, for recomputing % when the true window
                                     // (1M) is only knowable from outside the transcript
    public let cwd: String?          // recovered from the transcript (for ended-session resume)
}

/// Claude CLI sessions only record pid/cwd/name/status in `~/.claude/sessions`. The
/// model and git branch live in the project transcript — recovered here from its tail.
public enum ClaudeHistoryEnricher {
    static var projectsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    }

    /// Project directory names dash-encode the cwd: the CLI turns EVERY non-alphanumeric
    /// character into `-` (not just `/` and `.` — also spaces, `~`, `_`, …), e.g.
    /// "…/Mobile Documents/iCloud~md~obsidian/…" → "…-Mobile-Documents-iCloud-md-obsidian-…".
    /// Verified against every on-disk project dir; ASCII-only to match the CLI's regex semantics.
    static func encode(cwd: String) -> String {
        String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
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

    /// The transcript's last-modified time — a cheap activity signal (it is appended on every
    /// turn). Used to override a Desktop session's frozen `lastActivityAt` and to infer liveness
    /// for argv-detected resumes. Only checks the direct encoded path (no dir scan) so it stays
    /// cheap to call per session each poll.
    public static func transcriptMtime(sessionId: String, cwd: String) -> Date? {
        let direct = projectsDir.appendingPathComponent(encode(cwd: cwd))
            .appendingPathComponent("\(sessionId).jsonl")
        return (try? FileManager.default.attributesOfItem(atPath: direct.path))?[.modificationDate] as? Date
    }

    static let cache = FileCache<ClaudeHistory>()

    public static func enrich(sessionId: String, cwd: String) -> ClaudeHistory? {
        guard let url = transcriptURL(sessionId: sessionId, cwd: cwd) else { return nil }
        return parse(url)
    }

    /// Parse a transcript file directly (used both by enrich and for ended-session discovery,
    /// where we only have the file, not the cwd up front). Cached on the file's mtime+size.
    public static func parse(_ url: URL) -> ClaudeHistory? {
        cache.value(path: url.path, stamp: fileStamp(url)) {
            var model: String?, branch: String?, aiTitle: String?, lastPrompt: String?, cwd: String?
            var customTitle: String?
            var prNumber: Int?, prURL: String?, ctxTokens: Int?
            for d in JSONLReader.tailObjects(url).reversed() {
                let msg = d["message"] as? [String: Any]
                // Only accept real model ids; Claude writes "<synthetic>" system turns (often the
                // very last record) that must not be shown as the model. Match by exclusion, not
                // a "claude-" prefix — Bedrock/Vertex ids ("us.anthropic.claude-…") are real too.
                if model == nil, let m = msg?["model"] as? String, !m.isEmpty, m != "<synthetic>" { model = m }
                if branch == nil, let b = d["gitBranch"] as? String, b != "HEAD", !b.isEmpty { branch = b }
                if cwd == nil, let c = d["cwd"] as? String, !c.isEmpty { cwd = c }
                // Latest *real* assistant turn only: "<synthetic>" records carry an all-zero
                // usage dict, and taking it would pin a ~90%-full session at "0% ctx" — exactly
                // when the warning matters.
                if ctxTokens == nil, let u = msg?["usage"] as? [String: Any],
                   (msg?["model"] as? String) != "<synthetic>" {
                    ctxTokens = ((u["input_tokens"] as? Int) ?? 0)
                        + ((u["cache_read_input_tokens"] as? Int) ?? 0)
                        + ((u["cache_creation_input_tokens"] as? Int) ?? 0)
                }
                switch d["type"] as? String {
                case "ai-title":   if aiTitle == nil { aiTitle = d["aiTitle"] as? String }
                case "custom-title": if customTitle == nil { customTitle = d["customTitle"] as? String }
                case "last-prompt": if lastPrompt == nil { lastPrompt = d["lastPrompt"] as? String }
                case "pr-link":
                    if prNumber == nil { prNumber = d["prNumber"] as? Int; prURL = d["prUrl"] as? String }
                default: break
                }
            }
            // A 200k-window session auto-compacts well before 200k, so observing more than that
            // proves it's running on the 1M context window — even when the transcript's model id
            // lacks the "1m" marker (a CLI transcript records "claude-opus-4-8"; the "[1m]" suffix
            // only appears in the Desktop store). Without this, a long 1M session reads a bogus
            // >100% against the 200k denominator and pins at 100%.
            let is1M = (model ?? "").localizedCaseInsensitiveContains("1m") || (ctxTokens ?? 0) > 200_000
            let window = is1M ? 1_000_000.0 : 200_000.0
            let pct = ctxTokens.map { min(100, Int(Double($0) / window * 100)) }
            return ClaudeHistory(model: model, branch: branch, aiTitle: aiTitle,
                                 customTitle: customTitle, lastPrompt: lastPrompt,
                                 prNumber: prNumber, prURL: prURL, contextPercent: pct,
                                 contextTokens: ctxTokens, cwd: cwd)
        }
    }

    /// Context% against the window the *merged* model implies. CLI transcripts never carry the
    /// "[1m]" marker (it lives only in the Desktop store), so a 1M session under 200k tokens
    /// reads ~5× inflated from the transcript alone — the caller that knows the Desktop model
    /// string uses this to correct it.
    public static func contextPercent(history h: ClaudeHistory?, model: String?) -> Int? {
        guard let h else { return nil }
        if let t = h.contextTokens, (model ?? "").localizedCaseInsensitiveContains("1m") {
            return min(100, Int(Double(t) / 1_000_000 * 100))
        }
        return h.contextPercent
    }
}
