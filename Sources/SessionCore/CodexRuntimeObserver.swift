import Darwin
import Foundation

/// Passive Desktop IPC follower. It only sends initialize + following-changed; it cannot
/// start/resume a turn, claim ownership, or answer approvals. The Desktop's app-server may
/// be separate from the managed daemon, so querying a different daemon gives false idle.
/// IPC stream protocol v11 observed in ChatGPT/Codex build 155.0.8059.40 (2026-10-14).
final class CodexRuntimeObserver: @unchecked Sendable {
    static let shared = CodexRuntimeObserver()
    private let lock = NSLock()
    private var desired = Set<String>()
    private var states: [String: [String: Any]] = [:]
    private var running = false

    func observe(_ ids: Set<String>) {
        lock.lock(); desired = ids; states = states.filter { ids.contains($0.key) }
        let start = !running && !ids.isEmpty
        if start { running = true }
        lock.unlock()
        if start { DispatchQueue.global(qos: .utility).async { self.run() } }
    }

    func activity(for id: String, persisted: SessionActivity) -> SessionActivity {
        lock.lock(); let runtime = states[id]; lock.unlock()
        return Self.reconcile(runtime, persisted: persisted)
    }

    static func reconcile(_ runtime: [String: Any]?, persisted: SessionActivity) -> SessionActivity {
        guard let runtime else {
            var result = persisted
            if result.status == .busy || result.status == .waiting || result.status == .input {
                result.status = .unknown; result.waitingFor = nil
            }
            return result
        }
        var result = persisted
        result.waitingFor = nil
        switch runtime["type"] as? String {
        case "active":
            let flags = runtime["activeFlags"] as? [String] ?? []
            if flags.contains("waitingOnApproval") {
                result.status = .waiting; result.waitingFor = "Approve in Codex"
            } else if flags.contains("waitingOnUserInput") {
                result.status = .input; result.waitingFor = "Answer in Codex"
            } else { result.status = .busy }
        case "idle", "notLoaded":
            // An unload/crash is not evidence of successful completion.
            if persisted.status == .busy || persisted.status == .waiting || persisted.status == .input {
                result.status = .interrupted
            }
        case "systemError": result.status = .failed
        default: result.status = .unknown
        }
        return result
    }

    private func run() {
        defer {
            lock.lock(); running = false; states.removeAll(); lock.unlock()
        }
        while true {
            lock.lock(); let needed = desired; lock.unlock()
            if needed.isEmpty { return }
            let fd = connectSocket()
            if fd < 0 { Thread.sleep(forTimeInterval: 2); continue }
            connection(fd)
            close(fd)
            lock.lock(); states.removeAll(); lock.unlock()
            Thread.sleep(forTimeInterval: 2)
        }
    }

    private func connectSocket() -> Int32 {
        let path = NSHomeDirectory() + "/.codex/ipc/ipc.sock"
        // Never connect to another user's endpoint or create a router/socket ourselves.
        var st = stat()
        guard lstat(path, &st) == 0, st.st_uid == getuid(), st.st_mode & S_IFMT == S_IFSOCK else { return -1 }
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return -1 }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if ok != 0 { close(fd); return -1 }
        return fd
    }

    private func send(_ message: [String: Any], fd: Int32) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return false }
        var length = UInt32(data.count).littleEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }; frame.append(data)
        return frame.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
    }

    private func connection(_ fd: Int32) {
        guard send(["type": "request", "requestId": "session-master-observer", "version": 0,
                    "method": "initialize", "params": ["clientType": "session-master"]], fd: fd) else { return }
        var clientId: String?
        var subscribed = Set<String>()
        var revisions: [String: Int] = [:]
        var owners: [String: String] = [:]
        let initializedBy = Date().addingTimeInterval(5)
        var buffer = Data()
        var bytes = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            lock.lock(); let needed = desired; lock.unlock()
            if needed.isEmpty { return }
            if clientId == nil, Date() > initializedBy { return }
            if let clientId {
                for id in subscribed.symmetricDifference(needed) {
                    guard send(["type": "broadcast", "method": "thread-stream-following-changed", "version": 1,
                                "sourceClientId": clientId,
                                "params": ["conversationId": id, "hostId": "local", "following": needed.contains(id)]], fd: fd) else { return }
                }
                subscribed = needed
                lock.lock(); states = states.filter { needed.contains($0.key) }; lock.unlock()
            }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, 500)
            if ready < 0 { if errno == EINTR { continue }; return }
            if ready == 0 { continue }
            let count = recv(fd, &bytes, bytes.count, 0)
            if count <= 0 { return }
            buffer.append(contentsOf: bytes.prefix(count))
            while buffer.count >= 4 {
                let length = buffer.prefix(4).enumerated().reduce(0) { $0 | (Int($1.element) << ($1.offset * 8)) }
                // A future protocol / oversized history must fail soft, not exhaust app memory.
                guard length > 0, length <= 32 * 1024 * 1024 else { return }
                if buffer.count < length + 4 { break }
                let data = buffer.subdata(in: buffer.startIndex + 4..<buffer.startIndex + 4 + length)
                buffer.removeFirst(length + 4)
                // This worker lives for the lifetime of the app. Drain temporary Foundation
                // JSON objects per frame instead of retaining whole conversation snapshots.
                let keepReading = autoreleasepool { () -> Bool in
                    guard let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
                    if message["method"] as? String == "initialize",
                       let result = message["result"] as? [String: Any] { clientId = result["clientId"] as? String }
                    if message["type"] as? String == "client-discovery-request" {
                        // Explicitly decline all command routing; we are only an observer.
                        guard send(["type": "client-discovery-response", "requestId": message["requestId"] ?? "",
                                    "response": ["canHandle": false]], fd: fd) else { return false }
                    }
                    if message["method"] as? String == "client-status-changed",
                       let p = message["params"] as? [String: Any], p["status"] as? String == "disconnected",
                       let owner = p["clientId"] as? String {
                        lock.lock()
                        for id in owners.keys.filter({ owners[$0] == owner }) {
                            states.removeValue(forKey: id); owners.removeValue(forKey: id)
                            revisions.removeValue(forKey: id); subscribed.remove(id)
                        }
                        lock.unlock()
                    }
                    guard message["method"] as? String == "thread-stream-state-changed",
                          message["version"] as? Int == 11,
                          let p = message["params"] as? [String: Any], p["hostId"] as? String == "local",
                          let id = p["conversationId"] as? String, needed.contains(id),
                          let change = p["change"] as? [String: Any] else { return true }
                    lock.lock()
                    if change["type"] as? String == "snapshot" {
                        states[id] = (change["conversationState"] as? [String: Any])?["threadRuntimeStatus"] as? [String: Any]
                        revisions[id] = change["revision"] as? Int
                        owners[id] = message["sourceClientId"] as? String
                    } else if let patches = change["patches"] as? [[String: Any]],
                              let base = change["baseRevision"] as? Int, base == revisions[id],
                              owners[id] == message["sourceClientId"] as? String {
                        for patch in patches { Self.apply(patch, to: &states[id]) }
                        revisions[id] = change["revision"] as? Int
                    } else {
                        // Never apply a patch onto the wrong snapshot after reconnect/owner changes.
                        states.removeValue(forKey: id); revisions.removeValue(forKey: id)
                        subscribed.remove(id)
                    }
                    lock.unlock()
                    return true
                }
                if !keepReading { return }
            }
        }
    }

    static func apply(_ patch: [String: Any], to runtime: inout [String: Any]?) {
        guard let path = patch["path"] as? [Any], path.first as? String == "threadRuntimeStatus" else { return }
        let remove = patch["op"] as? String == "remove"
        if path.count == 1 { runtime = remove ? nil : patch["value"] as? [String: Any]; return }
        guard let key = path[1] as? String, runtime != nil else { return }
        if path.count == 2 { runtime?[key] = remove ? nil : patch["value"]; return }
        if key == "activeFlags", path.count == 3, let index = path[2] as? Int {
            var flags = runtime?[key] as? [String] ?? []
            if remove, flags.indices.contains(index) { flags.remove(at: index) }
            else if let flag = patch["value"] as? String {
                if patch["op"] as? String == "add", index <= flags.count, index >= 0 { flags.insert(flag, at: index) }
                else if flags.indices.contains(index) { flags[index] = flag }
            }
            runtime?[key] = flags
        }
    }
}
