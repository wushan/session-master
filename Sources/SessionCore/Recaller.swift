import AppKit
import ApplicationServices
import Foundation

/// Everything the recaller needs to bring a session's terminal window forward.
public struct RecallTarget: Sendable {
    public let cwd: String?
    /// The terminal window title to match (Claude's session `name`). Most reliable key.
    public let windowTitleHint: String?
    public let tty: String?
    public let terminalApp: String?
    public let terminalBundleID: String?
    public let terminalPID: pid_t?
    public let viaTmux: Bool

    public init(cwd: String?, windowTitleHint: String? = nil, tty: String?, terminalApp: String?,
                terminalBundleID: String?, terminalPID: pid_t?, viaTmux: Bool) {
        self.cwd = cwd; self.windowTitleHint = windowTitleHint; self.tty = tty
        self.terminalApp = terminalApp; self.terminalBundleID = terminalBundleID
        self.terminalPID = terminalPID; self.viaTmux = viaTmux
    }

    /// Build from a correlated TerminalInfo plus the session's known cwd and title hint.
    public init(cwd: String?, windowTitleHint: String? = nil, terminal: TerminalInfo) {
        self.init(cwd: cwd, windowTitleHint: windowTitleHint, tty: terminal.tty,
                  terminalApp: terminal.terminalApp, terminalBundleID: terminal.terminalBundleID,
                  terminalPID: terminal.terminalPID, viaTmux: terminal.viaTmux)
    }
}

public enum RecallOutcome: Sendable {
    case raisedWindow(title: String, otherDisplay: Bool, fromOtherSpace: Bool)  // matched & raised a window
    case appleScriptSwitched         // iTerm2/Terminal switched to the tab by tty
    case tmuxSwitched(String)        // tmux selected the pane (target)
    case foregroundedApp(String)     // best-effort: brought the app forward, no precise window
    case exposedWindows(String)      // fanned the app's windows out with App Exposé — user clicks one
    case needsAccessibility          // AX not granted; cannot raise specific window
    case notFound
    case failed(String)
}

public enum Recaller {

    // MARK: - Accessibility trust

    public static func accessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Prompts the user (system dialog) to grant Accessibility if not yet trusted.
    @discardableResult
    public static func ensureAccessibility(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    // MARK: - Top-level recall

    public static func recall(_ a: RecallTarget) -> RecallOutcome {
        // tmux first: the pane lives inside the tmux server regardless of terminal.
        if a.viaTmux, let tty = a.tty {
            switch tmuxSwitch(tty: tty) {
            case .tmuxSwitched(let t):
                if let tp = a.terminalPID { NSRunningApplication(processIdentifier: tp)?.activate() }
                return .tmuxSwitched(t)
            default: break
            }
        }

        switch a.terminalBundleID {
        case "com.apple.Terminal":
            if let tty = a.tty, appleScriptSelect(app: "Terminal", tty: tty) { return .appleScriptSwitched }
        case "com.googlecode.iterm2":
            if let tty = a.tty, appleScriptSelectITerm(tty: tty) { return .appleScriptSwitched }
        default:
            break
        }

        // Generic / no-IPC terminals (Ghostty, WezTerm, kitty, …): use Accessibility.
        if let tp = a.terminalPID {
            guard accessibilityTrusted() else { return .needsAccessibility }
            // Windows the Accessibility API can see are those on a currently-shown Space. Match by
            // title and focus it in place (SkyLight per-window focus brings its display forward).
            if let (window, title) = matchWindow(appPID: tp, titleHint: a.windowTitleHint, cwd: a.cwd) {
                focusWindow(window, appPID: tp)
                return .raisedWindow(title: title, otherDisplay: false, fromOtherSpace: false)
            }
            // Not on any visible Space — AX can't see it (Ghostty only exposes its focused window),
            // and modern macOS has locked down every private Space/window-move SPI. Use the native
            // path: activate the terminal and fan its windows out with App Exposé so the user clicks
            // the one to recall — macOS then switches to its desktop cleanly.
            if !Spaces.hiddenWindowIDs(ofPID: tp).isEmpty {
                NSRunningApplication(processIdentifier: tp)?.activate()
                usleep(120_000)   // let the app come forward before App Exposé
                if Spaces.appExpose(), let name = a.terminalApp { return .exposedWindows(name) }
            }
            NSRunningApplication(processIdentifier: tp)?.activate()
            // Last resort: just brought the terminal app forward (can't target the exact window).
            if let name = a.terminalApp { return .foregroundedApp(name) }
        }
        return .notFound
    }

    /// Focus a specific window and bring its app forward. Prefers the SkyLight per-window focus
    /// (clean across Spaces — no app-activate that would drag the window or revert a Space switch);
    /// falls back to plain AX raise + app activate if that SPI is unavailable.
    static func focusWindow(_ window: AXUIElement, appPID tp: pid_t) {
        if let wid = Spaces.windowID(of: window), Spaces.focusWindowID(wid, pid: tp) { return }
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(tp),
                                     kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        NSRunningApplication(processIdentifier: tp)?.activate()
    }

    // MARK: - Accessibility window raising

    /// Find the app window matching the session. Primary key is the title hint (Claude's
    /// `name`, which IS the terminal title); cwd forms are a fallback. Returns (element, title).
    static func matchWindow(appPID: pid_t, titleHint: String?, cwd: String?) -> (AXUIElement, String)? {
        let windows = windowTitles(appPID: appPID)
        // Key-major, priority-ordered: the session name (window title) is the reliable key,
        // so try it across ALL windows first. Only then fall back to the cwd path forms, and
        // the bare basename last (it's the loosest and can collide with another window).
        var keys: [String] = []
        if let h = titleHint, h.count > 2 { keys.append(h) }
        if let c = cwd {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            keys.append(c)
            if c.hasPrefix(home) { keys.append("~" + c.dropFirst(home.count)) }
            let base = (c as NSString).lastPathComponent
            if base.count > 4 { keys.append(base) }   // gate short/common basenames
        }
        for key in keys {
            if let hit = windows.first(where: { $0.1.localizedCaseInsensitiveContains(key) }) {
                return hit
            }
        }
        return nil
    }

    /// All (window element, title) pairs for an app via Accessibility.
    public static func windowTitles(appPID: pid_t) -> [(AXUIElement, String)] {
        let app = AXUIElementCreateApplication(appPID)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ref) == .success,
              let windows = ref as? [AXUIElement] else { return [] }
        return windows.map { w in
            var t: CFTypeRef?
            AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &t)
            return (w, (t as? String) ?? "")
        }
    }

    // MARK: - AppleScript (iTerm2 / Terminal.app)

    static func appleScriptSelect(app: String, tty: String) -> Bool {
        let script = """
        tell application "\(app)"
          activate
          repeat with w in windows
            repeat with t in tabs of w
              try
                if tty of t is "\(tty)" then
                  set selected tab of w to t
                  set index of w to 1
                  return "ok"
                end if
              end try
            end repeat
          end repeat
        end tell
        return "no"
        """
        return runOSAScript(script) == "ok"
    }

    static func appleScriptSelectITerm(tty: String) -> Bool {
        let script = """
        tell application "iTerm2"
          activate
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                try
                  if tty of s is "\(tty)" then
                    select s
                    select t
                    tell w to select
                    return "ok"
                  end if
                end try
              end repeat
            end repeat
          end repeat
        end tell
        return "no"
        """
        return runOSAScript(script) == "ok"
    }

    // MARK: - tmux

    static func tmuxSwitch(tty: String) -> RecallOutcome {
        guard let listing = runShell("/usr/bin/env",
                ["tmux", "list-panes", "-a", "-F",
                 "#{pane_tty}|#{session_name}|#{window_index}|#{pane_index}"]) else {
            return .failed("tmux not available")
        }
        for line in listing.split(separator: "\n") {
            let f = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 4, f[0] == tty else { continue }
            let win = "\(f[1]):\(f[2])"
            let pane = "\(win).\(f[3])"
            _ = runShell("/usr/bin/env", ["tmux", "select-window", "-t", win])
            _ = runShell("/usr/bin/env", ["tmux", "select-pane", "-t", pane])
            _ = runShell("/usr/bin/env", ["tmux", "switch-client", "-t", win])
            return .tmuxSwitched(pane)
        }
        return .notFound
    }

    // MARK: - Shell helpers

    @discardableResult
    static func runShell(_ launchPath: String, _ args: [String]) -> String? { Shell.run(launchPath, args) }

    static func runOSAScript(_ source: String) -> String? { Shell.osascript(source) }
}
