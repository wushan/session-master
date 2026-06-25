import AppKit
import Foundation

/// Reopens an ended CLI session by launching a Terminal that runs its tool's resume command
/// (`claude --resume <id>` / `codex resume <id>`) in the session's working directory.
public enum Resumer {
    @discardableResult
    public static func open(command: String, cwd: String) -> Bool {
        // Single-quote the cwd so a path with shell metacharacters can't break out. The command is
        // built from a fixed tool name + the session's UUID, so it needs no escaping. The user's
        // $SHELL as a login shell gives `claude`/`codex` the right PATH.
        let safeCwd = "'" + cwd.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let script = """
        #!\(shell) -l
        cd \(safeCwd) || exit 1
        exec \(command)
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sm-resume.command")
        guard (try? script.write(to: url, atomically: true, encoding: .utf8)) != nil else { return false }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return NSWorkspace.shared.open(url)
    }
}
