import Foundation

/// Desktop's SDK handles permissions in the app, so ~/.claude/sessions may be absent.
/// Its main log records requests and responses by request ID (Desktop 2.37337.1).
/// No command arguments, messages, or credentials are kept in this projection.
enum ClaudePermissionLog {
    struct Event {
        let at: Date
        let requestId: String
        let sessionId: String?
        let tool: String?
    }
    static let cache = FileCache<[Event]>()
    private static let request = try! NSRegularExpression(pattern:
        #"Emitted tool permission request ([\w-]+) for (\S+) in session (local_[\w-]+)"#)
    private static let response = try! NSRegularExpression(pattern:
        #"Received permission response for ([\w-]+):"#)

    static func parse(_ line: String) -> Event? {
        guard line.contains("permission request") || line.contains("permission response"), line.count >= 19 else { return nil }
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd HH:mm:ss" // Electron log timestamps are local time.
        guard let at = df.date(from: String(line.prefix(19))) else { return nil }
        let ns = line as NSString, range = NSRange(location: 0, length: ns.length)
        if let m = request.firstMatch(in: line, range: range) {
            return Event(at: at, requestId: ns.substring(with: m.range(at: 1)),
                         sessionId: ns.substring(with: m.range(at: 3)), tool: ns.substring(with: m.range(at: 2)))
        }
        if let m = response.firstMatch(in: line, range: range) {
            return Event(at: at, requestId: ns.substring(with: m.range(at: 1)), sessionId: nil, tool: nil)
        }
        return nil
    }

    static func pending(events: [Event], sessionId: String, processStarted: Date,
                        activity: SessionActivity) -> SessionActivity {
        var requests: [String: Event] = [:]
        for event in events.sorted(by: { $0.at < $1.at }) where event.at >= processStarted {
            if event.sessionId != nil { requests[event.requestId] = event }
            else { requests.removeValue(forKey: event.requestId) }
        }
        let unresolved = requests.values.filter {
            $0.sessionId == sessionId && $0.at > (activity.settledAt ?? .distantPast)
                // Log timestamps have second precision; transcript timestamps have milliseconds.
                && $0.at >= (activity.turnStartedAt?.addingTimeInterval(-1) ?? .distantPast)
        }
        guard let request = unresolved.max(by: { $0.at < $1.at }),
              activity.status != .completed, activity.status != .interrupted, activity.status != .failed else { return activity }
        var result = activity
        result.status = request.tool == "AskUserQuestion" ? .input : .waiting
        result.waitingFor = request.tool == "AskUserQuestion" ? "Answer in Claude" : "Approve \(request.tool ?? "tool") in Claude"
        return result
    }

    static func events() -> [Event]? {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Claude")
        guard FileManager.default.isReadableFile(atPath: root.appendingPathComponent("main.log").path) else { return nil }
        return (0...4).reversed().flatMap { index -> [Event] in
            let url = root.appendingPathComponent(index == 0 ? "main.log" : "main\(index).log")
            return cache.value(path: url.path, stamp: fileStamp(url)) {
                guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
                defer { try? fh.close() }
                // Rotation bounds history; permission requests before this process started are
                // discarded, so a previous launch can never resurrect an approval prompt.
                guard let size = try? fh.seekToEnd() else { return nil }
                let start = size > 4 * 1024 * 1024 ? size - 4 * 1024 * 1024 : 0
                try? fh.seek(toOffset: start)
                guard let data = try? fh.readToEnd() else { return nil }
                let text = String(decoding: data, as: UTF8.self)
                var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                if start > 0, !lines.isEmpty { lines.removeFirst() }
                if data.last != 10, !lines.isEmpty { lines.removeLast() }
                return lines.compactMap { parse(String($0)) }
            } ?? []
        }
    }
}
