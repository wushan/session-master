import Foundation

/// Resolves the real worktree for a session. A Claude session often runs from the repo
/// root while its work lives on a feature branch checked out in a `.claude/worktrees/...`
/// worktree — so Reveal / "Open in VS Code" should target that worktree, not the root.
public enum GitWorktree {
    /// The directory the user actually wants to open for this session.
    public static func effectivePath(branch: String?, cwd: String, isWorktree: Bool) -> String {
        if isWorktree { return cwd }
        guard let branch, !branch.isEmpty, branch != "HEAD" else { return cwd }
        return worktree(forBranch: branch, repo: cwd) ?? cwd
    }

    static func worktree(forBranch branch: String, repo: String) -> String? {
        guard let out = Shell.run("/usr/bin/git", ["-C", repo, "worktree", "list", "--porcelain"])
        else { return nil }
        var path: String?
        for line in out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("worktree ") {
                path = String(line.dropFirst("worktree ".count))
            } else if line.hasPrefix("branch ") {
                let name = line.dropFirst("branch ".count)
                    .replacingOccurrences(of: "refs/heads/", with: "")
                if name == branch, let p = path { return p }
            }
        }
        return nil
    }
}
