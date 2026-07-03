import Foundation

/// Cheap, local git state for a worktree — recomputed only when HEAD/index change.
public struct GitStatus: Sendable {
    public enum Track: Sendable, Equatable {
        case inSync, ahead(Int), behind(Int), diverged(Int, Int), gone, noUpstream, unknown
    }
    public let track: Track
    public let dirtyCount: Int

    /// Short label for the branch's relationship to its upstream.
    public var trackLabel: String? {
        switch track {
        case .gone:           return "merged"        // upstream deleted → likely merged/done
        case .ahead(let n):   return "↑\(n)"          // unpushed commits
        case .behind(let n):  return "↓\(n)"          // needs pull/rebase
        case .diverged(let a, let b): return "↑\(a) ↓\(b)"
        case .noUpstream:     return "unpushed"      // never pushed
        case .inSync, .unknown: return nil
        }
    }
}

public enum GitStatusCollector {
    static let cache = FileCache<GitStatus>()
    static let lock = NSLock()
    nonisolated(unsafe) static var gitdirs: [String: (dir: String?, at: Date)] = [:]

    static func gitdir(_ dir: String) -> String? {
        lock.lock(); let cached = gitdirs[dir]; lock.unlock()
        if let cached {
            // Failures are cached too — sessions in deleted worktrees / non-git folders would
            // otherwise spawn a `git rev-parse` subprocess on every 2s poll, forever. Negatives
            // are re-probed occasionally so a later `git init`/restore is still picked up.
            if cached.dir != nil || Date().timeIntervalSince(cached.at) < 90 { return cached.dir }
        }
        let g = Shell.run("/usr/bin/git", ["-C", dir, "rev-parse", "--absolute-git-dir"])
        let value = (g?.isEmpty == false) ? g : nil
        lock.lock(); gitdirs[dir] = (value, Date()); lock.unlock()
        return value
    }

    public static func status(dir: String) -> GitStatus? {
        guard let gd = gitdir(dir) else { return nil }
        // Recompute on HEAD/index/FETCH_HEAD change, and at least every ~90s — so remote-ref changes
        // (a fetch, an upstream pruned, a PR merged) that don't touch HEAD/index still refresh the
        // ahead/behind/gone state instead of showing stale tracking info indefinitely.
        let bucket = (Date().timeIntervalSince1970 / 90).rounded(.down) * 90
        let stamp = mtime(gd + "/HEAD") + mtime(gd + "/index") * 1e-3
            + mtime(gd + "/FETCH_HEAD") * 1e-4 + bucket
        return cache.value(path: dir, stamp: stamp) { compute(dir) }
    }

    static func mtime(_ path: String) -> Double {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970 ?? 0
    }

    static func compute(_ dir: String) -> GitStatus? {
        guard let head = Shell.run("/usr/bin/git", ["-C", dir, "symbolic-ref", "-q", "HEAD"]),
              !head.isEmpty else { return nil }
        let line = Shell.run("/usr/bin/git",
            ["-C", dir, "for-each-ref", "--format=%(upstream:short)|%(upstream:track)", head]) ?? ""
        let f = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        let upstream = f.first ?? ""
        let trackStr = f.count > 1 ? f[1] : ""
        let dirty = (Shell.run("/usr/bin/git", ["-C", dir, "status", "--porcelain", "-uno"]) ?? "")
            .split(separator: "\n").count
        return GitStatus(track: parseTrack(upstream: upstream, trackStr), dirtyCount: dirty)
    }

    static func parseTrack(upstream: String, _ s: String) -> GitStatus.Track {
        if s.contains("gone") { return .gone }
        let ahead = number(after: "ahead ", in: s)
        let behind = number(after: "behind ", in: s)
        if let a = ahead, let b = behind { return .diverged(a, b) }
        if let a = ahead { return .ahead(a) }
        if let b = behind { return .behind(b) }
        return upstream.isEmpty ? .noUpstream : .inSync
    }

    static func number(after token: String, in s: String) -> Int? {
        guard let r = s.range(of: token) else { return nil }
        let digits = s[r.upperBound...].prefix { $0.isNumber }
        return Int(digits)
    }
}
