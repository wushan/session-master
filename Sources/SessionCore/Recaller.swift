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
            if let (window, title) = matchWindow(appPID: tp, titleHint: a.windowTitleHint, cwd: a.cwd) {
                // If the window lives on another virtual desktop (Space), switch to that desktop —
                // AXRaise alone won't cross Spaces. Only if it's already on the current Space do we
                // pull it across displays instead.
                let otherDisplay = isOnOtherDisplay(window)
                let switchedSpace = Spaces.switchToWindowSpace(window)
                if !switchedSpace { bringToCurrentScreen(window) }
                AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                AXUIElementSetAttributeValue(AXUIElementCreateApplication(tp),
                                             kAXFrontmostAttribute as CFString, kCFBooleanTrue)
                NSRunningApplication(processIdentifier: tp)?.activate()
                return .raisedWindow(title: title, otherDisplay: otherDisplay && !switchedSpace,
                                     fromOtherSpace: switchedSpace)
            }
            // Fallback: bring the terminal app forward (can't target the exact window).
            NSRunningApplication(processIdentifier: tp)?.activate()
            if let name = a.terminalApp { return .foregroundedApp(name) }
        }
        return .notFound
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

    /// Pull the window onto the display the user's cursor is on (multi-monitor). AX position
    /// moves work across displays, so this runs whenever the window is on another screen.
    /// Single-display setups never trigger it. (Cross-*Space* moves are handled separately by
    /// `Spaces.pullToCurrentSpace`, since Accessibility can't cross virtual desktops.)
    static func bringToCurrentScreen(_ window: AXUIElement) {
        guard NSScreen.screens.count > 1 else { return }
        guard let current = cursorScreen(), let pos = axPosition(window) else { return }
        if screenOf(quartzTopLeft: pos)?.frame == current.frame { return }   // already on current
        let primaryMaxY = NSScreen.screens[0].frame.maxY
        let inset: CGFloat = 80
        setAXPosition(window, CGPoint(x: current.frame.minX + inset,
                                      y: primaryMaxY - current.frame.maxY + inset))
    }

    static func cursorScreen() -> NSScreen? {
        let m = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(m) } ?? NSScreen.main
    }

    /// The screen a window sits on, tested from a point 20px INSIDE its top-left so a window
    /// flush against a display boundary isn't mis-attributed to the neighbouring display.
    static func screenOf(quartzTopLeft pos: CGPoint) -> NSScreen? {
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        let interior = CGPoint(x: pos.x + 20, y: primaryMaxY - pos.y - 20)
        return NSScreen.screens.first { $0.frame.contains(interior) }
    }

    /// True when the recalled window ended up on a different display than the user's cursor.
    static func isOnOtherDisplay(_ window: AXUIElement) -> Bool {
        guard NSScreen.screens.count > 1, let pos = axPosition(window),
              let ws = screenOf(quartzTopLeft: pos), let cs = cursorScreen() else { return false }
        return ws.frame != cs.frame
    }

    static func axPosition(_ w: AXUIElement) -> CGPoint? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &ref) == .success,
              let value = ref, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var pt = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &pt) else { return nil }
        return pt
    }

    static func setAXPosition(_ w: AXUIElement, _ p: CGPoint) {
        var pt = p
        guard let v = AXValueCreate(.cgPoint, &pt) else { return }
        AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, v)
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
