import Darwin
import Foundation

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
        var capacity = size / stride + 16
        // The table can grow between the size probe and the fetch (process-spawn bursts, e.g. a
        // parallel build). Retry with a larger buffer instead of returning [] — an empty snapshot
        // would blank every session's terminal info for a tick and flip live CLI rows to Desktop.
        for _ in 0..<3 {
            var procs = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
            var size2 = procs.count * stride
            if sysctl(&mib, u_int(mib.count), &procs, &size2, nil, 0) == 0 {
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
            capacity = capacity * 3 / 2
        }
        return []
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

    /// The process's actual start time — the pid-recycling disambiguator. `isAlive` alone can't
    /// tell "the claude that wrote this file" from "whatever now owns its recycled pid" (kill(0)
    /// even returns EPERM for another user's process); comparing start times can.
    public static func startTime(of pid: pid_t) -> Date? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0,
              info.kp_proc.p_pid == pid else { return nil }
        let tv = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
    }

    // MARK: - argv-based resume detection

    /// A live `claude --resume <id>` / `--continue` CLI process recovered from argv.
    /// `sessionId` is nil for the id-less forms (`--continue`, `-c`, the bare `-r` picker) —
    /// the aggregator resolves those to the transcript the process is actually appending to.
    public struct ResumeProcess: Sendable {
        public let pid: pid_t
        public let sessionId: String?
    }

    /// Read a process's full argv via `KERN_PROCARGS2`. nil if not available/permitted.
    /// Layout: `int argc`, `exec_path\0`, NUL padding, then `argv[0]\0 argv[1]\0 …`.
    static func args(of pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
        var argc: Int32 = 0
        withUnsafeMutableBytes(of: &argc) { $0.copyBytes(from: buf[0..<MemoryLayout<Int32>.size]) }
        var i = MemoryLayout<Int32>.size
        while i < size, buf[i] != 0 { i += 1 }   // skip exec_path
        while i < size, buf[i] == 0 { i += 1 }    // skip padding NULs before argv[0]
        var args: [String] = []
        var cur = [UInt8]()
        while i < size, args.count < Int(argc) {
            let b = buf[i]; i += 1
            if b == 0 { args.append(String(decoding: cur, as: UTF8.self)); cur.removeAll(keepingCapacity: true) }
            else { cur.append(b) }
        }
        return args
    }

    /// Find live `claude` resume/continue processes. The CLI does not always write
    /// `~/.claude/sessions/{pid}.json` (notably when resuming a Desktop-origin session in a
    /// terminal), so the live-state files miss them; reading argv recovers the pid, and the
    /// session id when the invocation carried one. All takeover forms are matched — `--resume <id>`,
    /// `--resume=<id>`, `-r <id>`, and the id-less `--continue` / `-c` / bare `-r` picker (whose
    /// session id the aggregator resolves from the transcript the process appends to). A bare
    /// positional UUID is treated by the CLI as a prompt, not a resume, so it is not matched.
    public static func claudeResumeProcesses() -> [ResumeProcess] {
        var out: [ResumeProcess] = []
        for rec in snapshot() {
            // Cheap candidate filter before reading argv: claude either keeps p_comm "claude" or
            // renames it to its version string ("2.1.193", starts with a digit). Skip the rest.
            guard rec.comm.lowercased() == "claude" || (rec.comm.first?.isNumber ?? false) else { continue }
            guard let argv = args(of: rec.pid), let exe = argv.first,
                  exe.split(separator: "/").last?.lowercased().hasPrefix("claude") ?? false else { continue }
            var isTakeover = false
            var sid: String?
            for (i, a) in argv.enumerated().dropFirst() {
                if a == "--resume" || a == "-r" || a == "--continue" || a == "-c" {
                    isTakeover = true
                    if i + 1 < argv.count, isSessionUUID(argv[i + 1]) { sid = argv[i + 1] }
                } else if a.hasPrefix("--resume=") || a.hasPrefix("-r=") {
                    isTakeover = true
                    let v = String(a.split(separator: "=", maxSplits: 1).last ?? "")
                    if isSessionUUID(v) { sid = v }
                }
            }
            guard isTakeover else { continue }
            out.append(ResumeProcess(pid: rec.pid, sessionId: sid))
        }
        return out
    }

    static func isSessionUUID(_ s: String) -> Bool { s.count == 36 && UUID(uuidString: s) != nil }

    // MARK: - Codex TUI detection

    /// A live interactive `codex` TUI process (rollout liveness for Codex, which — unlike
    /// Claude — writes no live pid/status file).
    public struct CodexProcess: Sendable {
        public let pid: pid_t
        public let cwd: String
        public let resumeId: String?    // `codex resume <id>` → the exact rollout id
    }

    /// Codex subcommands that are NOT an interactive TUI attached to a rollout the user works in
    /// (headless exec runs, plugin/IDE servers, one-shot utilities).
    static let codexNonTUI: Set<String> = ["exec", "e", "mcp", "mcp-server", "app-server",
                                           "proto", "apply", "login", "logout", "sandbox",
                                           "completion", "debug", "cloud"]

    /// Global codex flags that take a separate value argument — their value must not be mistaken
    /// for the subcommand (`codex --profile work exec …` is an exec run, not a "work" TUI).
    static let codexValueFlags: Set<String> = ["-m", "--model", "-p", "--profile", "-c", "--config",
                                               "-C", "--cd", "-s", "--sandbox", "-a", "--ask-for-approval",
                                               "-i", "--image", "--color", "--oss"]

    /// The first argv token that is actually a subcommand: skips flags AND the value of
    /// known value-taking flags. nil == plain `codex` TUI.
    static func codexSubcommand(_ argv: [String]) -> String? {
        var i = 1
        while i < argv.count {
            let a = argv[i]
            if a.hasPrefix("-") {
                if codexValueFlags.contains(a) { i += 2 } else { i += 1 }   // --flag=v self-contains
                continue
            }
            return a
        }
        return nil
    }

    /// Find live interactive codex TUI processes (`codex`, `codex resume …`). Matched back to
    /// rollouts by explicit resume id or by cwd, giving Codex sessions real liveness + a terminal
    /// to recall — and preventing "Resume" from attaching a second TUI to a running thread.
    public static func codexTUIProcesses() -> [CodexProcess] {
        var out: [CodexProcess] = []
        for rec in snapshot() where rec.comm == "codex" {
            guard let argv = args(of: rec.pid), let exe = argv.first,
                  exe.split(separator: "/").last?.lowercased() == "codex" else { continue }
            let sub = codexSubcommand(argv)
            if let sub, codexNonTUI.contains(sub) { continue }
            var resumeId: String?
            if sub == "resume", let i = argv.firstIndex(of: "resume"), i + 1 < argv.count,
               isSessionUUID(argv[i + 1]) { resumeId = argv[i + 1] }
            guard let cwd = cwd(of: rec.pid) else { continue }
            out.append(CodexProcess(pid: rec.pid, cwd: cwd, resumeId: resumeId))
        }
        return out
    }
}
