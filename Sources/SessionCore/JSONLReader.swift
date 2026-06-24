import Foundation

/// Efficient partial readers for large `.jsonl` rollout/transcript files.
/// We never read whole multi-MB files — only the first record (session metadata)
/// and a tail window (latest turn context / model).
public enum JSONLReader {
    private static let newline: UInt8 = 0x0A

    /// Parse the first JSON object (e.g. Codex `session_meta` / Claude's first record).
    public static func firstObject(_ url: URL, maxBytes: Int = 1 << 20) -> [String: Any]? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        let data = (try? fh.read(upToCount: maxBytes)) ?? Data()
        let slice = data.firstIndex(of: newline).map { data[..<$0] } ?? data
        return (try? JSONSerialization.jsonObject(with: Data(slice))) as? [String: Any]
    }

    /// Parse the complete JSON objects contained in the last `maxBytes` of the file.
    public static func tailObjects(_ url: URL, maxBytes: Int = 64 * 1024) -> [[String: Any]] {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? fh.seek(toOffset: start)
        let data = (try? fh.readToEnd()) ?? Data()
        var lines = data.split(separator: newline, omittingEmptySubsequences: true)
        if start > 0, !lines.isEmpty { lines.removeFirst() }  // drop the partial first line
        return lines.compactMap { (try? JSONSerialization.jsonObject(with: Data($0))) as? [String: Any] }
    }
}
