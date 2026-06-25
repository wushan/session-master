import Foundation

/// Opens a folder in the user's chosen editor — a GUI app via `open -a`, or a custom command.
public enum EditorOpener {
    public static func open(path: String, appName: String?, customCommand: String?) {
        if let app = appName, !app.isEmpty {
            Shell.run("/usr/bin/open", ["-a", app, path])
        } else if let cmd = customCommand?.trimmingCharacters(in: .whitespaces), !cmd.isEmpty {
            // Tokenize the command and substitute {path} as ONE argument, then run via a login shell
            // using positional parameters (`exec "$@"`) — the script string is constant, so the
            // path can't be interpreted by the shell (no $(…)/backtick/quote injection) while the
            // editor binary is still resolved against the user's PATH.
            var argv = cmd.split(separator: " ").map(String.init)
            if let i = argv.firstIndex(where: { $0.contains("{path}") }) {
                argv[i] = argv[i].replacingOccurrences(of: "{path}", with: path)
            } else {
                argv.append(path)
            }
            Shell.run("/bin/sh", ["-lc", "exec \"$@\"", "sh"] + argv)
        } else {
            VSCodeOpener.open(path)
        }
    }
}
