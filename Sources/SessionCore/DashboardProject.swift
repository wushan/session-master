import Foundation

public struct DashboardProject: Identifiable {
    public let id: String
    public let name: String
    public let sessions: [UnifiedSession]
    public var activeCount: Int { sessions.filter(Self.isActive).count }
    public var visibleSessions: [UnifiedSession] { Array(sessions.prefix(max(5, activeCount))) }
    public var updatedAt: Date { sessions.compactMap(\.updatedAt).max() ?? .distantPast }

    public static func isActive(_ session: UnifiedSession) -> Bool {
        session.attention.needsUser || session.attention == .working
    }

    private static func projectPath(_ session: UnifiedSession) -> String {
        guard session.cwd.contains("/.codex/worktrees/") else { return session.projectRoot }
        var directory = URL(fileURLWithPath: session.cwd)
        while directory.path != "/" {
            let gitFile = directory.appendingPathComponent(".git")
            if let pointer = try? String(contentsOf: gitFile, encoding: .utf8), pointer.hasPrefix("gitdir: ") {
                let gitPath = String(pointer.dropFirst(8)).trimmingCharacters(in: .whitespacesAndNewlines)
                let gitDirectory = URL(fileURLWithPath: gitPath, relativeTo: directory)
                if let common = try? String(contentsOf: gitDirectory.appendingPathComponent("commondir"), encoding: .utf8) {
                    let root = URL(fileURLWithPath: common.trimmingCharacters(in: .whitespacesAndNewlines),
                                   relativeTo: gitDirectory).standardizedFileURL
                    if root.lastPathComponent == ".git" { return root.deletingLastPathComponent().path }
                }
                break
            }
            directory.deleteLastPathComponent()
        }
        return session.cwd
    }

    public static func groups(_ sessions: [UnifiedSession], source: UnifiedSession.Source,
                              search: String = "", now: Date = Date()) -> [DashboardProject] {
        let cutoff = now.addingTimeInterval(-10 * 86400)
        let eligible = sessions.filter {
            $0.source == source && !$0.isAutomationRun && !$0.isRoutineRun
                && (isActive($0) || ($0.updatedAt ?? .distantPast) >= cutoff)
        }
        return Dictionary(grouping: eligible, by: { projectPath($0) }).compactMap { path, items in
            let name = (path as NSString).lastPathComponent
            let projectMatches = name.localizedCaseInsensitiveContains(search)
                || path.localizedCaseInsensitiveContains(search)
            let matches = items.filter {
                search.isEmpty || projectMatches || $0.displayTitle.localizedCaseInsensitiveContains(search)
                    || ($0.subtitle ?? "").localizedCaseInsensitiveContains(search)
            }
            guard !matches.isEmpty else { return nil }
            let sorted = matches.sorted {
                if $0.attention.rank != $1.attention.rank { return $0.attention.rank < $1.attention.rank }
                if $0.updatedAt != $1.updatedAt { return ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
                return $0.id < $1.id
            }
            return DashboardProject(id: path, name: name.isEmpty ? "No project" : name, sessions: sorted)
        }.sorted {
            if ($0.activeCount > 0) != ($1.activeCount > 0) { return $0.activeCount > 0 }
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id < $1.id
        }
    }
}
