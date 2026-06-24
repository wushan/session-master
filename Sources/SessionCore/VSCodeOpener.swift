import Foundation

/// Opens a folder (worktree) in VS Code via the `code` CLI, falling back to `open -a`.
public enum VSCodeOpener {
    static let candidates = ["/usr/local/bin/code", "/opt/homebrew/bin/code"]

    @discardableResult
    public static func open(_ path: String) -> Bool {
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            Shell.run(c, ["--new-window", path])
            return true
        }
        return Shell.run("/usr/bin/open", ["-a", "Visual Studio Code", path]) != nil
    }

    public static var isAvailable: Bool {
        candidates.contains { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
