import SessionCore
import Darwin
import AppKit

// recall-probe — M1 spike CLI verifying pid→terminal correlation and window recall.
// Sessions come from ~/.claude/sessions/*.json (authoritative); the probe walks each
// pid's parent chain to find its terminal, then recalls it.
//
//   recall-probe list            live Claude sessions + owning terminal
//   recall-probe ax-check        report Accessibility trust (prompts if not granted)
//   recall-probe ax-dump <pid>   dump all AX window titles of an app pid
//   recall-probe recall <pid>    recall the session with this CLI pid
//   recall-probe raw [filter]    raw process snapshot (debug)

let args = Array(CommandLine.arguments.dropFirst())
let cmd = args.first ?? "list"

func col(_ s: String?, _ w: Int) -> String {
    let v = s ?? "—"
    if v.count >= w { return String(v.prefix(w - 1)) + " " }
    return v + String(repeating: " ", count: w - v.count)
}

func liveTargets() -> [(LiveClaudeSession, TerminalInfo)] {
    let sessions = ClaudeLiveCollector.sessions()
    let terms = ProcessCollector.correlateTerminals(pids: sessions.map(\.pid))
    return sessions.map { ($0, terms[$0.pid] ?? .dead) }
}

switch cmd {
case "search":
    // Probe the full ended-session search pipeline the dashboard uses.
    let q = args.count > 1 ? args[1] : ""
    print("== ClaudeEndedCollector.matching(q: \(q)) ==")
    let raw = ClaudeEndedCollector.matching(query: q, excluding: [])
    for e in raw {
        print("  sid=\(e.sessionId.prefix(8)) custom=\(e.history.customTitle ?? "—") ai=\(e.history.aiTitle ?? "—") cwd=\(e.history.cwd ?? "—")")
    }
    print("== SessionAggregator.searchEndedSessions ==")
    for u in SessionAggregator.searchEndedSessions(query: q, excluding: []) {
        print("  id=\(u.id.prefix(8)) displayTitle=\(u.displayTitle) subtitle=\(u.subtitle ?? "—")")
    }
    print("== dashboard 全路徑模擬 (store.sessions → searchOlder(exclude:loaded) → matches 重濾) ==")
    let loaded = SessionAggregator.all()
    let exclude = Set(loaded.map(\.id))
    func matches(_ s: UnifiedSession) -> Bool {
        let hay = [s.displayTitle, s.projectName, s.branch, s.model, s.cwd, s.subtitle,
                   s.rich.searchText, s.rich.prNumber.map { "PR#\($0)" }]
            .compactMap { $0 }.joined(separator: " ")
        return hay.localizedCaseInsensitiveContains(q)
    }
    let base = loaded.filter(matches)
    for u in base { print("  [loaded] \(u.id.prefix(8)) \(u.displayTitle) src=\(u.source)") }
    let older = SessionAggregator.searchEndedSessions(query: q, excluding: exclude)
    for u in older {
        print("  [older]  \(u.id.prefix(8)) \(u.displayTitle) matchesUI=\(matches(u)) dedupDropped=\(exclude.contains(u.id))")
    }
case "list":
    let rows = liveTargets().sorted { $0.0.pid < $1.0.pid }
    print("PID    STATUS   TTY          TERMINAL   TMUX  CWD")
    print(String(repeating: "─", count: 100))
    for (s, t) in rows {
        print(col(String(s.pid), 7) + col(s.status, 9) + col(t.tty, 13)
              + col(t.terminalApp, 11) + col(t.viaTmux ? "yes" : "", 6) + s.cwd)
    }
    print("\n\(rows.count) live Claude session(s).")

case "ax-check":
    let trusted = Recaller.ensureAccessibility(prompt: true)
    print("Accessibility trusted: \(trusted)")
    if !trusted { print("→ Grant in System Settings ▸ Privacy & Security ▸ Accessibility, then re-run.") }

case "ax-dump":
    guard args.count >= 2, let pid = pid_t(args[1]) else { print("usage: ax-dump <pid>"); exit(2) }
    guard Recaller.accessibilityTrusted() else { print("Accessibility not granted; run ax-check first."); exit(1) }
    let titles = Recaller.windowTitles(appPID: pid)
    print("App pid \(pid): \(titles.count) window(s)")
    for (i, t) in titles.enumerated() { print(String(format: "  [%02d] %@", i, t.1.isEmpty ? "<no title>" : t.1)) }

case "recall":
    guard args.count >= 2, let pid = pid_t(args[1]) else { print("usage: recall <pid>"); exit(2) }
    guard let (s, t) = liveTargets().first(where: { $0.0.pid == pid }) else {
        print("No live Claude session with pid \(pid)."); exit(1)
    }
    print("Recalling pid \(pid) in \(t.terminalApp ?? "?") tty \(t.tty ?? "?") name \"\(s.name ?? "")\"")
    switch Recaller.recall(RecallTarget(cwd: s.cwd, windowTitleHint: s.name, terminal: t)) {
    case .raisedWindow(let x, let other, let otherSpace):
        let note = otherSpace ? " (switched to its desktop)" : (other ? " (on other display)" : "")
        print("✅ raised window: \"\(x)\"\(note)")
    case .appleScriptSwitched:    print("✅ switched tab via AppleScript")
    case .tmuxSwitched(let x):    print("✅ tmux selected pane: \(x)")
    case .foregroundedApp(let n): print("⚠️  no precise window match — brought \(n) to front (fallback)")
    case .exposedWindows(let n):  print("🪟  App Exposé for \(n) — click the window to recall")
    case .needsAccessibility:     print("❌ Accessibility not granted — run `recall-probe ax-check`")
    case .notFound:               print("❌ could not locate a window/terminal to recall")
    case .failed(let m):          print("❌ \(m)")
    }

case "deepsearch":
    // searchEndedSessions ONLY (no snapshot) — isolates deep-scan cost from git/gh subprocesses.
    let q = args.count > 1 ? args[1] : ""
    let t0 = Date()
    let r = SessionAggregator.searchEndedSessions(query: q, excluding: [])
    print("\(r.count) hits in \(String(format: "%.2f", -t0.timeIntervalSinceNow))s")
    for u in r { print("  \(u.id.prefix(8)) [\(u.source.rawValue)] \(u.displayTitle)") }
    let t1 = Date()
    _ = SessionAggregator.searchEndedSessions(query: q, excluding: [])
    print("warm re-query: \(String(format: "%.2f", -t1.timeIntervalSinceNow))s")

case "ages":
    // Verify session ordering timestamps: content-based lastActivity vs what the UI shows.
    for s in SessionAggregator.all().sorted(by: { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }) {
        let age = s.updatedAt.map { d -> String in
            let m = Int(-d.timeIntervalSinceNow / 60)
            return m < 60 ? "\(m)m" : m < 60*48 ? "\(m/60)h" : "\(m/1440)d"
        } ?? "—"
        print(col(age, 6) + col(s.source.rawValue, 15) + s.displayTitle.prefix(40))
    }
case "all":
    let rows = SessionAggregator.all()
    print("STATUS   SOURCE         MODEL            EFFORT  TERM/ORIG    PROJECT / BRANCH")
    print(String(repeating: "─", count: 110))
    for s in rows {
        let termOrig = s.terminal.terminalApp ?? s.originator ?? "—"
        let proj = s.projectName + (s.branch.map { " @\($0)" } ?? "")
        print(col(s.status.rawValue, 9) + col(s.source.rawValue, 15) + col(s.shortModel, 17)
              + col(s.effort, 8) + col(termOrig, 13) + proj)
    }
    print("\n\(rows.count) sessions  (\(rows.filter{$0.source.isClaude}.count) Claude, \(rows.filter{$0.source.isCodex}.count) Codex)")

case "subs":
    guard args.count >= 2 else { print("usage: subs <rollout.jsonl>"); exit(2) }
    let subs = CodexSubagentScanner.scan(rollout: URL(fileURLWithPath: args[1]))
    print("\(subs.count) sub-agent(s):")
    for s in subs { print("  \(s.nickname)  (\(s.id))") }

case "tree":
    for node in SessionAggregator.tree() {
        let s = node.session
        let wt = GitWorktree.effectivePath(branch: s.branch, cwd: s.cwd, isWorktree: s.isWorktree)
        let git = s.rich.git.map { "[\($0.trackLabel ?? "sync") \($0.dirtyCount > 0 ? "·\($0.dirtyCount)Δ" : "")]" } ?? ""
        let pr = s.rich.prNumber.map { " PR#\($0)" } ?? ""
        print("• [\(s.source.rawValue)] \(s.displayTitle)  (\(s.attention.rawValue)) \(git)\(pr)")
        if let sub = s.subtitle { print("    ↳ \(sub.prefix(70))") }
        print("    open→ \(wt)")
        for c in node.children {
            print("    └─ [\(c.source.rawValue)] \(c.displayTitle)  open→ \(c.cwd)")
        }
    }

case "jobs":
    let df = DateFormatter(); df.dateFormat = "EEE MM-dd HH:mm"
    let jobs = ScheduleAggregator.all()
    print("SRC     STATUS   NEXT RUN          MODEL              NAME")
    print(String(repeating: "─", count: 100))
    for j in jobs {
        let next = j.nextRun.map { df.string(from: $0) } ?? (j.source == .claude ? "(harness)" : "—")
        print(col(j.source.rawValue, 8) + col(j.isPaused ? "PAUSED" : (j.status == nil ? "routine" : "ACTIVE"), 9)
              + col(next, 18) + col(j.model, 19) + j.name)
    }
    print("\n\(jobs.count) jobs (\(jobs.filter{$0.source == .codex}.count) Codex automations, \(jobs.filter{$0.source == .claude}.count) Claude routines)")

case "raw":
    let all = ProcessCollector.debugAll()
    print("total \(all.count) procs in snapshot")
    let filter = args.count >= 2 ? args[1].lowercased() : nil
    for r in all where filter == nil || String(r.pid) == filter || r.comm.lowercased().contains(filter!) {
        print("pid=\(r.pid)\tppid=\(r.ppid)\ttdev=\(r.tdev)\tcomm=\(r.comm)")
    }

default:
    print("usage: recall-probe [list|ax-check|ax-dump <pid>|recall <pid>|raw [filter]]")
}
