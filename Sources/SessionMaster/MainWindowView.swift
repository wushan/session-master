import SwiftUI
import AppKit
import SessionCore

enum DashboardTab: String, CaseIterable {
    case sessions = "Sessions", automations = "Automations", config = "Config", about = "About"
    var icon: String {
        switch self {
        case .sessions:    return "list.bullet.rectangle"
        case .automations: return "clock.arrow.2.circlepath"
        case .config:      return "gearshape"
        case .about:       return "info.circle"
        }
    }
}

struct MainWindowView: View {
    @Bindable var store: SessionStore

    enum SourceFilter: String, CaseIterable { case all = "All", claude = "Claude", codex = "Codex" }
    enum SortMode: String, CaseIterable { case project = "Project", recent = "Recent" }

    @State private var sourceFilter: SourceFilter = .all
    @State private var sortMode: SortMode = .recent
    @State private var search = ""
    @State private var expandedNodes: Set<String> = []
    @State private var expandedProjects: Set<String> = []
    private let perProjectLimit = 5

    var body: some View {
        NavigationSplitView {
            List(DashboardTab.allCases, id: \.self, selection: Binding(
                get: { store.selectedTab }, set: { if let v = $0 { store.selectedTab = v } })) { tab in
                Label(tab.rawValue, systemImage: tab.icon).tag(tab)
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 168, max: 220)
        } detail: {
            VStack(spacing: 0) {
                if store.selectedTab == .sessions { sessionControls; Divider() }
                if !store.accessibilityTrusted { AccessibilityBanner(store: store) }
                switch store.selectedTab {
                case .sessions:    sessionsList
                case .automations: automationsList
                case .config:      ConfigView(store: store)
                case .about:       AboutView()
                }
            }
        }
        .frame(minWidth: 720, minHeight: 460)
        .background(.background)
        // Menu-bar apps (.accessory) have no Dock tile, so a minimized window vanishes with no
        // way back. While the dashboard is open, become a regular app so it gets a Dock icon and
        // minimize works; drop back to menu-bar-only only once it's really gone — deferred + guarded
        // so closing-then-reopening (or a stray disappear) can't strand the app without a Dock icon.
        .onAppear { NSApp.setActivationPolicy(.regular) }
        .onDisappear {
            DispatchQueue.main.async {
                let stillOpen = NSApp.windows.contains {
                    $0.title == "SessionMaster" && ($0.isVisible || $0.isMiniaturized)
                }
                if !stillOpen { NSApp.setActivationPolicy(.accessory) }
            }
        }
    }

    // MARK: Session controls (filter / sort / search — the tabs live in the sidebar now)

    private var sessionControls: some View {
        HStack(spacing: 12) {
            Picker("", selection: $sourceFilter) {
                ForEach(SourceFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).fixedSize()
            Picker("", selection: $sortMode) {
                ForEach(SortMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).fixedSize().help("Sort order")
            Spacer()
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
                TextField("Filter", text: $search).textFieldStyle(.plain).frame(width: 160)
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
        if !store.hasLoaded {
            loadingState
        } else if filteredSessions.isEmpty {
            emptyState("No matching sessions")
        } else if sortMode == .recent {
            List(recentNodes) { node in
                SessionNodeView(node: node, expanded: $expandedNodes, store: store)
                    .listRowInsets(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6))
            }.listStyle(.inset)
        } else {
            List {
                ForEach(grouped, id: \.project) { group in
                    let expanded = expandedProjects.contains(group.project)
                    let shown = expanded ? group.nodes : Array(group.nodes.prefix(perProjectLimit))
                    Section {
                        ForEach(shown) { node in
                            SessionNodeView(node: node, expanded: $expandedNodes, store: store)
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

    private var loadingState: some View {
        VStack(spacing: 10) {
            Spacer()
            ProgressView().controlSize(.small)
            Text("Loading sessions…").font(.caption).foregroundStyle(.secondary)
            Spacer()
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
