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

/// Opens a command in a new terminal window, in a given working directory, under the user's
/// *interactive login* shell. Interactive matters: Claude's resume renderer crashes if `.zshrc`
/// isn't sourced (some config it needs is interactive-only), and a plain `-l -c` login shell skips
/// it — exactly the difference between a manual `claude --resume` (works) and a scripted one (crashes).
public enum TerminalLauncher {
    public static func run(command: String, cwd: String, terminal: TerminalApp) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        // `command` is a fixed tool name + UUID, so it's safe to interpolate; the cwd is single-quoted.
        let inner = "cd \(sq(cwd)) || exit 1; clear; exec \(command)"
        switch terminal {
        case .systemDefault: openCommandFile(shell: shell, inner: inner, app: nil)
        case .terminal:      openCommandFile(shell: shell, inner: inner, app: "Terminal")
        case .iterm2:        runITerm2(inner: inner)          // iTerm's own shell is already interactive
        case .ghostty:
            // Ghostty's `-e` runs the rest as the command; passed as argv (no shell) so safe.
            Shell.run("/usr/bin/open", ["-na", "Ghostty", "--args", "-e", shell, "-l", "-i", "-c", inner])
        }
    }

    private static func sq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// A temp `.command` opened in Terminal.app — it execs an interactive login shell (`-l -i`) so
    /// the user's shell config is sourced.
    private static func openCommandFile(shell: String, inner: String, app: String?) {
        let script = "#!/bin/bash\nexec \(shell) -l -i -c \(sq(inner))\n"
        // Unique filename: a fixed path lets a second resume overwrite the first before Terminal
        // has exec'd it, sending both windows to the same (latest) session.
        let name = "sm-resume-\(UUID().uuidString.prefix(8)).command"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
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
