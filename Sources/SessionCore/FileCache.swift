import Foundation

/// A combined mtime+size stamp for a file. Changes whenever the file is modified or grows,
/// which is the signal collectors use to avoid re-reading unchanged files every poll.
public func fileStamp(_ url: URL) -> Double {
    let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
    let m = v?.contentModificationDate?.timeIntervalSince1970 ?? 0
    return m * 1_000_000 + Double(v?.fileSize ?? 0)
}

/// Thread-safe per-path cache: recomputes a value only when the file's stamp changes.
/// The app polls every 2s indefinitely, so this keeps disk reads proportional to actual
/// session activity rather than re-reading every transcript/rollout on every tick.
public final class FileCache<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: (stamp: Double, value: Value)] = [:]

    public init() {}

    public func value(path: String, stamp: Double, compute: () -> Value?) -> Value? {
        lock.lock()
        if let entry = store[path], entry.stamp == stamp { lock.unlock(); return entry.value }
        lock.unlock()
        guard let computed = compute() else { return nil }
        lock.lock(); store[path] = (stamp, computed); lock.unlock()
        return computed
    }
}
