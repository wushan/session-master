import Foundation

/// Resolves the real worktree for a session. A Claude session often runs from the repo
/// root while its work lives on a feature branch checked out in a `.claude/worktrees/...`
/// worktree — so Reveal / "Open in VS Code" should target that worktree, not the root.
public enum GitWorktree {
    static let lock = NSLock()
    nonisolated(unsafe) static var cache: [String: String] = [:]

    /// The directory the user actually wants to open for this session. Cached per (branch, repo)
    /// since it shells out to `git worktree list` and is called for every session each poll.
    public static func effectivePath(branch: String?, cwd: String, isWorktree: Bool) -> String {
        if isWorktree { return cwd }
        guard let branch, !branch.isEmpty, branch != "HEAD" else { return cwd }
        let key = branch + "\u{1}" + cwd
        lock.lock(); let cached = cache[key]; lock.unlock()
        if let cached { return cached }
        let result = worktree(forBranch: branch, repo: cwd) ?? cwd
        lock.lock(); cache[key] = result; lock.unlock()
        return result
    }

    /// If `path` is a `<repo>/.claude/worktrees/<name>` worktree path, the repo root; else nil.
    /// Used to recover a session whose worktree folder was deleted after the branch merged.
    /// Anchored on the *last* marker (a repo could itself live under such a path) and only matches
    /// when a worktree name follows it.
    public static func repoRootForWorktreePath(_ path: String) -> String? {
        let marker = "/.claude/worktrees/"
        guard let r = path.range(of: marker, options: .backwards),
              r.upperBound < path.endIndex else { return nil }
        return String(path[path.startIndex..<r.lowerBound])
    }

    /// Whether `branch` still exists as a local branch in `repo`.
    public static func branchExists(_ branch: String, repo: String) -> Bool {
        Shell.run("/usr/bin/git",
                  ["-C", repo, "rev-parse", "--verify", "--quiet", "refs/heads/" + branch]) != nil
    }

    /// Recreate a removed worktree at `path` checking out `branch`, in `repo`. Returns true on success.
    /// The transcript is keyed to this exact path, so resume only works once the folder is back.
    /// `-f`: a worktree folder deleted with `rm -rf` leaves a stale registration in
    /// `.git/worktrees/<name>`, and a plain `add` then fails with "missing but already registered".
    public static func recreate(path: String, branch: String, repo: String) -> Bool {
        Shell.run("/usr/bin/git",
                  ["-C", repo, "worktree", "add", "-f", path, branch], timeout: 30) != nil
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
