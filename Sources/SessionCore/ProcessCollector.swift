import Darwin

/// Terminal ownership for a given process, discovered by walking the parent chain.
/// Driven by a pid from a session file — NOT by scanning process names, because the
/// claude CLI renames its own `p_comm` to its version string (e.g. "2.1.187").
public struct TerminalInfo: Sendable {
    public let alive: Bool
    public let tty: String?              // "/dev/ttys068" (from the session process itself)
    public let terminalApp: String?      // "Ghostty" | "iTerm2" | "Terminal" | "VS Code" | ...
    public let terminalBundleID: String?
    public let terminalPID: pid_t?
    public let viaTmux: Bool

    public static let dead = TerminalInfo(alive: false, tty: nil, terminalApp: nil,
                                          terminalBundleID: nil, terminalPID: nil, viaTmux: false)
}

/// Low-level process facts from a single `sysctl(KERN_PROC_ALL)` snapshot.
struct ProcRecord {
    let pid: pid_t
    let ppid: pid_t
    let comm: String   // p_comm, truncated to 16 chars; unreliable for app identity
    let tdev: dev_t    // controlling tty device, or -1 (NODEV)
}

public enum ProcessCollector {

    /// Snapshot every process via sysctl. One syscall → pid/ppid/comm/controlling-tty.
    static func snapshot() -> [ProcRecord] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }

        let stride = MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 16)
        var size2 = procs.count * stride
        guard sysctl(&mib, u_int(mib.count), &procs, &size2, nil, 0) == 0 else { return [] }

        let count = size2 / stride
        return procs.prefix(count).map { kp in
            var k = kp
            let comm = withUnsafeBytes(of: &k.kp_proc.p_comm) { raw -> String in
                guard let base = raw.bindMemory(to: CChar.self).baseAddress else { return "" }
                return String(cString: base)
            }
            return ProcRecord(pid: kp.kp_proc.p_pid,
                              ppid: kp.kp_eproc.e_ppid,
                              comm: comm,
                              tdev: kp.kp_eproc.e_tdev)
        }
    }

    // MARK: - Public correlation API

    /// Correlate many session pids to their terminals in one snapshot pass.
    public static func correlateTerminals(pids: [pid_t]) -> [pid_t: TerminalInfo] {
        let records = snapshot()
        let byPID = Dictionary(records.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [pid_t: TerminalInfo] = [:]
        for pid in pids {
            guard let rec = byPID[pid] else { out[pid] = .dead; continue }
            let (term, tmux) = owningTerminal(startPID: pid, byPID: byPID)
            out[pid] = TerminalInfo(alive: true,
                                    tty: ttyName(rec.tdev),
                                    terminalApp: term?.name,
                                    terminalBundleID: term?.bundleID,
                                    terminalPID: term?.pid,
                                    viaTmux: tmux)
        }
        return out
    }

    public static func terminalInfo(forPID pid: pid_t) -> TerminalInfo {
        correlateTerminals(pids: [pid])[pid] ?? .dead
    }

    /// Debug: raw (pid, ppid, comm, tdev) for every process in the snapshot.
    public static func debugAll() -> [(pid: pid_t, ppid: pid_t, comm: String, tdev: dev_t)] {
        snapshot().map { ($0.pid, $0.ppid, $0.comm, $0.tdev) }
    }

    // MARK: - Terminal detection

    struct TerminalHit { let name: String; let bundleID: String?; let pid: pid_t }

    /// Known terminal emulators keyed by a lowercased substring of their `p_comm`.
    static let knownTerminals: [(needle: String, name: String, bundleID: String?)] = [
        ("ghostty",    "Ghostty",   "com.mitchellh.ghostty"),
        ("iterm2",     "iTerm2",    "com.googlecode.iterm2"),
        ("iterm",      "iTerm2",    "com.googlecode.iterm2"),
        ("terminal",   "Terminal",  "com.apple.Terminal"),
        ("wezterm",    "WezTerm",   "com.github.wez.wezterm"),
        ("kitty",      "kitty",     "net.kovidgoyal.kitty"),
        ("alacritty",  "Alacritty", "org.alacritty"),
        ("warp",       "Warp",      "dev.warp.Warp-Stable"),
        ("code helper","VS Code",   "com.microsoft.VSCode"),
        ("electron",   "VS Code",   "com.microsoft.VSCode"),
        ("code",       "VS Code",   "com.microsoft.VSCode"),
    ]

    /// Walk the parent chain to find the owning terminal emulator.
    /// Detects tmux specially: panes are children of the tmux *server*, not a terminal.
    static func owningTerminal(startPID: pid_t, byPID: [pid_t: ProcRecord]) -> (TerminalHit?, Bool) {
        var viaTmux = false
        var current = byPID[startPID]?.ppid ?? 0
        var hops = 0
        while current > 1, hops < 16 {
            guard let rec = byPID[current] else { break }
            let comm = rec.comm.lowercased()
            if comm.hasPrefix("tmux") { viaTmux = true }
            for t in knownTerminals where comm.contains(t.needle)
                && !(t.needle == "code" && comm.contains("xcode")) {   // "xcode" contains "code"
                return (TerminalHit(name: t.name, bundleID: t.bundleID, pid: rec.pid), viaTmux)
            }
            current = rec.ppid
            hops += 1
        }
        return (nil, viaTmux)
    }

    // MARK: - Per-process detail (libproc)

    static func ttyName(_ dev: dev_t) -> String? {
        guard dev != -1, dev != 0 else { return nil }
        guard let c = devname(dev, mode_t(S_IFCHR)) else { return nil }
        return "/dev/" + String(cString: c)
    }

    public static func cwd(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let sz = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let r = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, sz)
        guard r == sz else { return nil }
        return withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
            guard let base = raw.bindMemory(to: CChar.self).baseAddress else { return nil }
            let s = String(cString: base)
            return s.isEmpty ? nil : s
        }
    }

    public static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
