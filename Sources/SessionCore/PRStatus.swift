import Foundation

/// Pull-request state for a branch, via one batched `gh pr list` per repo (cached ~5 min).
/// Needs network + `gh` auth; degrades to nil (the transcript still provides the PR number).
public struct PRInfo: Sendable {
    public let number: Int
    public let state: String          // OPEN | CLOSED | MERGED
    public let isDraft: Bool
    public let reviewDecision: String?
    public let url: String
    public var displayState: String { isDraft ? "DRAFT" : state }
}

public enum PRStatus {
    static let ttl: TimeInterval = 300
    static let lock = NSLock()
    nonisolated(unsafe) static var repoCache: [String: (at: Date, map: [String: PRInfo])] = [:]
    nonisolated(unsafe) static var slugCache: [String: String] = [:]
    nonisolated(unsafe) static var inflight: Set<String> = []

    static let ghPath: String? = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    /// Non-blocking: returns whatever is cached now and schedules a background refresh if the
    /// repo's PR list is stale — so the 2s session poll never waits on a `gh` network call.
    public static func forBranch(_ branch: String, repoDir: String) -> PRInfo? {
        guard let slug = repoSlug(repoDir), ghPath != nil else { return nil }
        lock.lock()
        let cached = repoCache[slug]
        let fresh = cached.map { Date().timeIntervalSince($0.at) < ttl } ?? false
        lock.unlock()
        if !fresh { scheduleFetch(slug) }
        return cached?.map[branch]
    }

    static func scheduleFetch(_ slug: String) {
        guard claimInflight(slug) else { return }
        Task.detached(priority: .utility) {
            let map = fetch(slug)
            storeResult(slug, map)
        }
    }

    /// Returns true if this caller now owns the in-flight fetch for `slug` (sync — keeps NSLock
    /// out of the async closure, which Swift 6 forbids).
    private static func claimInflight(_ slug: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if inflight.contains(slug) { return false }
        inflight.insert(slug); return true
    }

    private static func storeResult(_ slug: String, _ map: [String: PRInfo]?) {
        lock.lock(); defer { lock.unlock() }
        if let map {
            repoCache[slug] = (Date(), map)                       // success → fresh for the full TTL
        } else if repoCache[slug] != nil {
            // Failure: short backoff (retry ~30s) instead of locking out for the full 5 min, while
            // keeping whatever good data we already had — don't surface a transient gh hiccup as "no PR".
            let keep = repoCache[slug]?.map ?? [:]
            repoCache[slug] = (Date().addingTimeInterval(-(ttl - 30)), keep)
        }
        inflight.remove(slug)
    }

    static func fetch(_ slug: String) -> [String: PRInfo]? {
        guard let gh = ghPath,
              let out = Shell.run(gh, ["pr", "list", "--state", "all", "--limit", "100", "-R", slug,
                  "--json", "number,headRefName,state,isDraft,reviewDecision,url"]),
              let arr = (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [[String: Any]]
        else { return nil }
        var map: [String: PRInfo] = [:]
        for d in arr {
            guard let branch = d["headRefName"] as? String, let num = d["number"] as? Int,
                  let state = d["state"] as? String, let url = d["url"] as? String else { continue }
            if let existing = map[branch], existing.state == "OPEN" { continue }   // prefer the open PR
            map[branch] = PRInfo(number: num, state: state, isDraft: (d["isDraft"] as? Bool) ?? false,
                reviewDecision: (d["reviewDecision"] as? String).flatMap { $0.isEmpty ? nil : $0 }, url: url)
        }
        return map
    }

    static func repoSlug(_ dir: String) -> String? {
        lock.lock(); let cached = slugCache[dir]; lock.unlock()
        if let cached { return cached.isEmpty ? nil : cached }
        let url = Shell.run("/usr/bin/git", ["-C", dir, "remote", "get-url", "origin"]) ?? ""
        let slug = url
            .replacingOccurrences(of: #"^git@[^:]+:"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^https://[^/]+/"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\.git$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock(); slugCache[dir] = slug; lock.unlock()
        return slug.isEmpty ? nil : slug
    }
}
