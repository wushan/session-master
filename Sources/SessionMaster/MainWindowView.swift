import SwiftUI
import SessionCore

struct MainWindowView: View {
    @Bindable var store: SessionStore

    enum Tab: String, CaseIterable { case sessions = "Sessions", automations = "Automations" }
    enum SourceFilter: String, CaseIterable { case all = "All", claude = "Claude", codex = "Codex" }
    enum SortMode: String, CaseIterable { case project = "Project", recent = "Recent" }

    @State private var tab: Tab = .sessions
    @State private var sourceFilter: SourceFilter = .all
    @State private var sortMode: SortMode = .project
    @State private var search = ""
    @State private var collapsed: Set<String> = []
    @State private var expandedProjects: Set<String> = []
    private let perProjectLimit = 5

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if !store.accessibilityTrusted { AccessibilityBanner(store: store) }
            switch tab {
            case .sessions:    sessionsList
            case .automations: automationsList
            }
        }
        .frame(minWidth: 560, minHeight: 420)
        .background(.background)
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).fixedSize()

            if tab == .sessions {
                Picker("", selection: $sourceFilter) {
                    ForEach(SourceFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).fixedSize()
                Picker("", selection: $sortMode) {
                    ForEach(SortMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).fixedSize().help("Sort order")
            }
            Spacer()
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
                TextField("Filter", text: $search).textFieldStyle(.plain).frame(width: 140)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.primary.opacity(0.06)).clipShape(Capsule())

            Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help("Refresh now").pointerCursor()
        }.padding(10)
    }

    // MARK: Sessions (grouped by project)

    private var filteredSessions: [UnifiedSession] {
        store.sessions.filter { s in
            switch sourceFilter {
            case .all: break
            case .claude: if !s.source.isClaude { return false }
            case .codex: if !s.source.isCodex { return false }
            }
            guard !search.isEmpty else { return true }
            let hay = [s.displayTitle, s.projectName, s.branch, s.model, s.cwd]
                .compactMap { $0 }.joined(separator: " ")
            return hay.localizedCaseInsensitiveContains(search)
        }
    }

    private var grouped: [(project: String, nodes: [SessionNode])] {
        Dictionary(grouping: SessionTree.build(filteredSessions, extraChildren: store.subagentChildren),
                   by: \.session.projectName)
            // Within a project: needs-you first, then most-recent first.
            .map { (project: $0.key, nodes: $0.value.sorted {
                $0.session.attention.rank != $1.session.attention.rank
                    ? $0.session.attention.rank < $1.session.attention.rank
                    : ($0.session.updatedAt ?? .distantPast) > ($1.session.updatedAt ?? .distantPast)
            }) }
            .sorted { $0.project.localizedCaseInsensitiveCompare($1.project) == .orderedAscending }
    }

    /// Flat list across all projects, most-recently-active first (needs-you still on top).
    private var recentNodes: [SessionNode] {
        SessionTree.build(filteredSessions, extraChildren: store.subagentChildren).sorted {
            $0.session.attention.rank != $1.session.attention.rank
                ? $0.session.attention.rank < $1.session.attention.rank
                : ($0.session.updatedAt ?? .distantPast) > ($1.session.updatedAt ?? .distantPast)
        }
    }

    @ViewBuilder private var sessionsList: some View {
        if filteredSessions.isEmpty {
            emptyState("No matching sessions")
        } else if sortMode == .recent {
            List(recentNodes) { node in
                SessionNodeView(node: node, collapsed: $collapsed, store: store)
                    .listRowInsets(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6))
            }.listStyle(.inset)
        } else {
            List {
                ForEach(grouped, id: \.project) { group in
                    let expanded = expandedProjects.contains(group.project)
                    let shown = expanded ? group.nodes : Array(group.nodes.prefix(perProjectLimit))
                    Section {
                        ForEach(shown) { node in
                            SessionNodeView(node: node, collapsed: $collapsed, store: store)
                                .listRowInsets(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6))
                        }
                        if group.nodes.count > perProjectLimit {
                            Button {
                                if expanded { expandedProjects.remove(group.project) }
                                else { expandedProjects.insert(group.project) }
                            } label: {
                                Text(expanded ? "Show less"
                                     : "Show \(group.nodes.count - perProjectLimit) more…")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain).pointerCursor()
                            .listRowInsets(EdgeInsets(top: 2, leading: 30, bottom: 4, trailing: 6))
                        }
                    } header: {
                        HStack(spacing: 6) {
                            Image(systemName: "folder.fill").font(.caption2).foregroundStyle(.secondary)
                            Text(group.project).font(.subheadline.weight(.semibold))
                            Text("\(group.nodes.count)").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }.listStyle(.inset)
        }
    }

    // MARK: Automations

    @ViewBuilder private var automationsList: some View {
        if store.jobs.isEmpty {
            emptyState("No automations or routines")
        } else {
            List {
                ForEach([ScheduledJob.Source.codex, .claude], id: \.self) { src in
                    let items = store.jobs.filter { $0.source == src }
                    if !items.isEmpty {
                        Section(src == .codex ? "Codex automations" : "Claude routines") {
                            ForEach(items) { job in
                                JobRowView(job: job, onVSCode: { store.openInVSCode(path: $0) })
                            }
                        }
                    }
                }
            }.listStyle(.inset)
        }
    }

    private func emptyState(_ text: String) -> some View {
        VStack { Spacer(); Text(text).foregroundStyle(.secondary); Spacer() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
