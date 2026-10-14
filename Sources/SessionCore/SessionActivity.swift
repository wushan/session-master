import Foundation

/// Evidence from the tool, never elapsed-time inference. Observed with Codex Desktop
/// 0.162.0-alpha.17.2 and Claude Desktop 2.37337.1 / Claude Code 2.1.295 (2026-10-14).
public struct SessionActivity: Sendable {
    public var status: UnifiedSession.Status = .unknown
    public var timestamp: Date?
    public var turnId: String?
    public var waitingFor: String?
    var settledAt: Date?
    var turnStartedAt: Date?

    mutating func consumeCodex(_ record: [String: Any]) {
        guard record["type"] as? String == "event_msg",
              let p = record["payload"] as? [String: Any], let type = p["type"] as? String else { return }
        let id = p["turn_id"] as? String
        switch type {
        case "task_started":
            turnId = id; status = .busy; waitingFor = nil
        case "task_complete", "turn_aborted":
            // A delayed completion belonging to an older turn must not stop a newer one.
            guard id == nil || turnId == nil || id == turnId else { return }
            status = type == "task_complete" ? .completed : .interrupted
            waitingFor = nil
        default: return
        }
        timestamp = Self.date(record["timestamp"])
        if status == .completed || status == .interrupted { settledAt = timestamp }
    }

    mutating func consumeClaude(_ record: [String: Any]) {
        guard record["isSidechain"] as? Bool != true else { return }
        let message = record["message"] as? [String: Any]
        switch record["type"] as? String {
        case "user":
            guard record["isMeta"] as? Bool != true else { return }
            let blocks = message?["content"] as? [[String: Any]] ?? []
            let text = message?["content"] as? String
                ?? (blocks.count == 1 ? blocks.first?["text"] as? String : nil)
            if text == "[Request interrupted by user]" || text == "[Request interrupted by user for tool use]" {
                status = .interrupted
            } else {
                status = .busy
                if !blocks.contains(where: { $0["type"] as? String == "tool_result" }) {
                    turnStartedAt = Self.date(record["timestamp"])
                }
            }
        case "assistant":
            guard message?["model"] as? String != "<synthetic>" else { return }
            switch message?["stop_reason"] as? String {
            case "end_turn", "stop_sequence": status = .completed
            case "max_tokens": status = .interrupted
            default: status = .busy
            }
        case "system" where record["subtype"] as? String == "turn_duration":
            status = .completed
        default: return
        }
        waitingFor = nil
        timestamp = Self.date(record["timestamp"])
        if status == .completed || status == .interrupted { settledAt = timestamp }
    }

    static func date(_ value: Any?) -> Date? {
        guard let s = value as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}

/// Replays a file once, then only complete appended lines. A start event may be many MB
/// behind the tail during a long tool call, so a fixed tail window loses the running state.
/// Only lifecycle lines are JSON-decoded; prompt/tool output is not retained in this cache.
final class ActivityReplay: @unchecked Sendable {
    private struct Entry {
        var stamp: Double
        var inode: UInt64
        var offset: UInt64 = 0
        var skippingLine = false
        var activity = SessionActivity()
    }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func read(_ url: URL) -> SessionActivity {
        lock.lock(); defer { lock.unlock() }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? UInt64,
              let inode = attrs[.systemFileNumber] as? UInt64,
              let mtime = attrs[.modificationDate] as? Date else { return SessionActivity() }
        let stamp = mtime.timeIntervalSince1970 * 1_000_000 + Double(size)
        var e = entries[url.path] ?? Entry(stamp: -1, inode: inode)
        if e.stamp == stamp, e.inode == inode { return e.activity }
        // Rewritten/synced transcripts must replay, even if their size did not change.
        if e.inode != inode || size <= e.offset { e = Entry(stamp: -1, inode: inode) }
        guard let fh = try? FileHandle(forReadingFrom: url) else { return SessionActivity() }
        defer { try? fh.close() }
        do {
            try fh.seek(toOffset: e.offset)
            var pending = Data()
            while let chunk = try fh.read(upToCount: 64 * 1024), !chunk.isEmpty {
                pending.append(chunk)
                var start = pending.startIndex
                while let newline = pending.range(of: Data([10]), in: start..<pending.endIndex)?.lowerBound {
                    let line = pending[start..<newline]
                    let consumed = line.count + 1
                    let candidate = line.range(of: Data("\"task_started\"".utf8)) != nil
                        || line.range(of: Data("\"task_complete\"".utf8)) != nil
                        || line.range(of: Data("\"turn_aborted\"".utf8)) != nil
                    if !e.skippingLine, candidate, let record = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] {
                        e.activity.consumeCodex(record)
                    }
                    e.offset += UInt64(consumed)
                    e.skippingLine = false
                    start = newline + 1
                }
                pending.removeSubrange(..<start)
                // Lifecycle records are small. Skip an oversized prompt/tool line without
                // buffering arbitrary history or decoding its content; resume at its newline.
                if pending.count > 8 * 1024 * 1024 || e.skippingLine {
                    e.offset += UInt64(pending.count); pending.removeAll(keepingCapacity: false)
                    e.skippingLine = true
                }
            }
            // Leave an unfinished last line on disk to be re-read after the writer completes it.
            e.stamp = stamp; entries[url.path] = e
            if entries.count > 4000 { entries = [url.path: e] }
            return e.activity
        } catch { return SessionActivity() }
    }
}

enum SessionActivityCollector {
    static let replay = ActivityReplay()
    static let claudeCache = FileCache<SessionActivity>()
    static func claude(sessionId: String, cwd: String) -> SessionActivity {
        guard let url = ClaudeHistoryEnricher.transcriptURL(sessionId: sessionId, cwd: cwd) else {
            return SessionActivity()
        }
        // Claude's most recent message carries its stop_reason. Do not replay hundreds of
        // MB of old Desktop transcripts just to recover the last turn's state.
        return claudeCache.value(path: url.path, stamp: fileStamp(url)) {
            var activity = SessionActivity()
            for record in JSONLReader.tailObjects(url) { activity.consumeClaude(record) }
            return activity
        } ?? SessionActivity()
    }
}
