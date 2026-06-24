import Foundation

/// Optional, lazily-enriched status for a session — git state, PR, recent prompt, context use.
/// Everything here is cheap & mtime-cached so it can run on every poll.
public struct SessionRich: Sendable {
    public var git: GitStatus?
    public var aiTitle: String?
    public var lastPrompt: String?
    public var prNumber: Int?
    public var prURL: String?
    public var prState: String?        // "OPEN" | "DRAFT" | "MERGED" | "CLOSED"
    public var prReviewDecision: String?
    public var contextPercent: Int?    // % of the model context window used
    public var customTitle: String?    // user-set name (overrides the auto title)

    public init() {}
}
