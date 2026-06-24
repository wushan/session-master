import Foundation

/// Opens a folder in the user's chosen editor — a GUI app via `open -a`, or a custom command.
public enum EditorOpener {
    public static func open(path: String, appName: String?, customCommand: String?) {
        if let app = appName, !app.isEmpty {
            Shell.run("/usr/bin/open", ["-a", app, path])
        } else if let cmd = customCommand, !cmd.trimmingCharacters(in: .whitespaces).isEmpty {
            let full = cmd.contains("{path}")
                ? cmd.replacingOccurrences(of: "{path}", with: path)
                : "\(cmd) \"\(path)\""
            Shell.run("/bin/sh", ["-lc", full])
        } else {
            VSCodeOpener.open(path)
        }
    }
}
