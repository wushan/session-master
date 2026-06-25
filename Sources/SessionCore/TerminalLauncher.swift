import AppKit
import Foundation

/// Which terminal to open `Resume` in.
public enum TerminalApp: String, CaseIterable, Sendable, Identifiable {
    case systemDefault = "System default"
    case terminal = "Terminal"
    case iterm2 = "iTerm2"
    case ghostty = "Ghostty"
    public var id: String { rawValue }
}

/// Opens a command in a new terminal window, in a given working directory, under the user's login
/// shell (so `claude` / `codex` resolve on PATH). Used by Resume.
public enum TerminalLauncher {
    public static func run(command: String, cwd: String, terminal: TerminalApp) {
        // Single-quote the cwd so a path with shell metacharacters can't break out. `command` is a
        // fixed tool name + UUID, so it's safe to interpolate.
        let safeCwd = "'" + cwd.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let inner = "cd \(safeCwd) || exit 1; clear; exec \(command)"
        switch terminal {
        case .systemDefault: openCommandFile(shell: shell, inner: inner, app: nil)
        case .terminal:      openCommandFile(shell: shell, inner: inner, app: "Terminal")
        case .iterm2:        runITerm2(inner: inner)
        case .ghostty:
            // Ghostty's `-e` runs the rest as the command; passed as argv (no shell) so safe.
            Shell.run("/usr/bin/open", ["-na", "Ghostty", "--args", "-e", shell, "-l", "-c", inner])
        }
    }

    /// A temp `.command` file opened in Terminal.app (the default handler) — `app` forces Terminal.
    private static func openCommandFile(shell: String, inner: String, app: String?) {
        let script = "#!\(shell) -l\n\(inner)\n"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sm-resume.command")
        guard (try? script.write(to: url, atomically: true, encoding: .utf8)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        if let app { Shell.run("/usr/bin/open", ["-a", app, url.path]) }
        else { NSWorkspace.shared.open(url) }
    }

    private static func runITerm2(inner: String) {
        let esc = inner.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        Shell.osascript("""
        tell application "iTerm"
          activate
          create window with default profile
          tell current session of current window to write text "\(esc)"
        end tell
        """)
    }
}
