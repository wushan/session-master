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
    // Ended sessions older than the loaded window that match the current search — fetched on demand
    // (debounced) so typing can find/resume a session closed days ago without bloating the default list.
    @State private var olderResults: [UnifiedSession] = []
    @State private var expandedNodes: Set<String> = []
    @State private var expandedProjects: Set<String> = []
    @State private var settings = AppSettings.shared
    @State private var window: NSWindow?
    @State private var didSetInitialSize = false
    @FocusState private var searchFocused: Bool
    @State private var filterExpanded = false
    private let perProjectLimit = 5

    var body: some View {
        // A compact top tab bar (icon over label, selected one highlighted) replaces the old
        // sidebar — it keeps the window narrow without stealing a whole column, and the tabs are
        // always visible instead of hidden behind a toggle.
        VStack(alignment: .leading, spacing: 0) {
            tabBar
            Divider()
            if store.selectedTab == .sessions { sessionControls; Divider() }
            if !store.accessibilityTrusted { AccessibilityBanner(store: store) }
            switch store.selectedTab {
            case .sessions:    sessionsList
            case .automations: automationsList
            case .config:      ConfigView(store: store)
            case .about:       AboutView()
            }
        }
        .frame(minWidth: 380, minHeight: 460)
        .background(.background)
        .background(WindowAccessor { window = $0; applyAlwaysOnTop(); applyInitialSize() })
        .onChange(of: settings.dashboardAlwaysOnTop) { applyAlwaysOnTop() }
        // Menu-bar apps (.accessory) have no Dock tile, so a minimized window vanishes with no
        // way back. While the dashboard is open, become a regular app so it gets a Dock icon and
        // minimize works; drop back to menu-bar-only only once it's really gone — deferred + guarded
        // so closing-then-reopening (or a stray disappear) can't strand the app without a Dock icon.
        .onAppear { NSApp.setActivationPolicy(.regular) }
        // Search reaches older (out-of-window) closed sessions: debounce keystrokes, then scan.
        .task(id: search) {
            guard search.count >= 2 else { olderResults = []; return }
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            let r = await store.searchOlder(search)
            if !Task.isCancelled { olderResults = r }   // don't let a stale query clobber newer results
        }
        .onDisappear {
            DispatchQueue.main.async {
                let stillOpen = NSApp.windows.contains {
                    $0.title == "SessionMaster" && ($0.isVisible || $0.isMiniaturized)
                }
                if !stillOpen { NSApp.setActivationPolicy(.accessory) }
            }
        }
    }

    /// Float the dashboard above other apps' windows (so the session list stays visible) when the
    /// preference is on; back to normal when off.
    private func applyAlwaysOnTop() {
        window?.level = settings.dashboardAlwaysOnTop ? .floating : .normal
    }

    /// Shrink a legacy oversized window down to the new narrow default — once per install
    /// (persisted in UserDefaults: the @State flag resets on every window recreation, which would
    /// re-shrink a window the user deliberately widened past 520pt on each reopen).
    private func applyInitialSize() {
        guard !didSetInitialSize, let window else { return }
        didSetInitialSize = true
        let migrationKey = "didShrinkLegacyWindow"
        if !UserDefaults.standard.bool(forKey: migrationKey) {
            UserDefaults.standard.set(true, forKey: migrationKey)
            var f = window.frame
            if f.size.width > 520 {
                f.size.width = 430
                window.setFrame(f, display: true, animate: false)
            }
        }
        // AppKit makes the first text field (the Filter box) the window's first responder when it
        // opens — drop that so the dashboard doesn't open with the search field focused.
        DispatchQueue.main.async { window.makeFirstResponder(nil) }
    }

    // MARK: Tab bar (Tailscale-style: icon over label, the selected one highlighted)

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach([DashboardTab.sessions, .automations, .config], id: \.self) { tabButton($0) }
            // Refresh lives here (left of About), styled like a tab (icon + label) for consistency
            // but without the selected highlight since it's an action, not a tab. It re-scans every
            // session's latest state now (the app also auto-polls every 2s).
            Button { store.refresh() } label: {
                VStack(spacing: 3) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 15, weight: .medium))
                    Text("Refresh").font(.system(size: 10, weight: .medium)).lineLimit(1)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 6)
                .foregroundStyle(.secondary).contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointerCursor().help("Refresh now — re-scan all sessions")
            tabButton(.about)
        }
        .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 4)
    }

    private func tabButton(_ tab: DashboardTab) -> some View {
        let selected = store.selectedTab == tab
        let hasUpdate = tab == .about && store.availableUpdate != nil
        return Button { store.selectedTab = tab } label: {
            VStack(spacing: 3) {
                Image(systemName: tab.icon).font(.system(size: 15, weight: .medium))
                    // A small dot on About flags an available update (replaces the old badge).
                    .overlay(alignment: .topTrailing) {
                        if hasUpdate {
                            Circle().fill(.red).frame(width: 6, height: 6).offset(x: 5, y: -2)
                        }
                    }
                Text(tab.rawValue).font(.system(size: 10, weight: .medium)).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(selected ? Color.accentColor.opacity(0.14) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor()
        .help(tab.rawValue + (hasUpdate ? " — update available" : ""))
    }

    // MARK: Session controls (filter / sort / search)

    private var sessionControls: some View {
        // Fits the narrow (~380pt) default: a collapsible source filter + a compact Sort menu keep
        // their natural size; the search field absorbs the rest. On focus the filter/sort slide away
        // so the input grows to the full width — easier to read/edit a long query.
        HStack(spacing: 8) {
            if !searchFocused {
                sourceFilterControl
                sortControl
            }
            searchField
        }
        .padding(.horizontal, 8).padding(.vertical, 10)
        .animation(.easeInOut(duration: 0.18), value: searchFocused)
        .animation(.easeInOut(duration: 0.18), value: filterExpanded)
        .onChange(of: searchFocused) { if searchFocused { filterExpanded = false } }
    }

    /// Source filter that saves width: collapsed to one pill showing the active source; tap to
    /// expand the three choices, and picking one collapses it back.
    @ViewBuilder private var sourceFilterControl: some View {
        if filterExpanded {
            HStack(spacing: 2) {
                ForEach(SourceFilter.allCases, id: \.self) { f in
                    let on = sourceFilter == f
                    Button { sourceFilter = f; filterExpanded = false } label: {
                        Text(f.rawValue).font(.caption.weight(.medium))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 7)
                                .fill(on ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06)))
                            .foregroundStyle(on ? Color.accentColor : .primary)
                    }.buttonStyle(.plain).pointerCursor()
                }
            }
        } else {
            // Tint the pill when a non-default filter is active so it reads as "filtered".
            let active = sourceFilter != .all
            Button { filterExpanded = true } label: {
                HStack(spacing: 3) {
                    Text(sourceFilter.rawValue).font(.caption.weight(.medium))
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .foregroundStyle(active ? Color.accentColor : .primary)
                .background(active ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.06))
                .clipShape(Capsule())
            }.buttonStyle(.plain).pointerCursor().help("Filter by source")
        }
    }

    /// Project / Recent aggregated into one compact "Sort" dropdown.
    private var sortControl: some View {
        Menu {
            Picker("Sort", selection: $sortMode) {
                ForEach(SortMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "arrow.up.arrow.down").font(.system(size: 9, weight: .semibold))
                Text(sortMode.rawValue).font(.caption.weight(.medium))
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.primary.opacity(0.06)).clipShape(Capsule())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .pointerCursor().help("Sort order")
    }

    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
            TextField("Filter", text: $search).textFieldStyle(.plain).focused($searchFocused)
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).font(.caption)
                }.buttonStyle(.plain).pointerCursor()
            }
            if searchFocused {
                Button("Done") { searchFocused = false }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.tint).pointerCursor()
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .frame(maxWidth: .infinity)
        .background(Color.primary.opacity(0.06)).clipShape(Capsule())
    }

    // MARK: Sessions (grouped by project)

    private func matches(_ s: UnifiedSession) -> Bool {
        switch sourceFilter {
        case .all: break
        case .claude: if !s.source.isClaude { return false }
        case .codex: if !s.source.isCodex { return false }
        }
        guard !search.isEmpty else { return true }
        // subtitle (last prompt / AI title) included: searchOlder finds out-of-window sessions BY
        // last prompt — omitting it here would drop exactly what that scan matched (and disagree
        // with the popover's haystack).
        let hay = [s.displayTitle, s.projectName, s.branch, s.model, s.cwd, s.subtitle]
            .compactMap { $0 }.joined(separator: " ")
        return hay.localizedCaseInsensitiveContains(search)
    }

    private var filteredSessions: [UnifiedSession] {
        let base = store.sessions.filter(matches)
        guard !search.isEmpty else { return base }
        // Fold in the older (out-of-window) ended matches, deduped against what's already loaded.
        let have = Set(base.map(\.id))
        return base + olderResults.filter { matches($0) && !have.contains($0.id) }
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
            // Plain scroll with zero inter-row spacing so each row's timeline rail joins the next
            // into one continuous vertical line (a List inserts gaps that break the rail).
            ScrollView {
                // Leading alignment + full-width rows so a row wider than the (narrow) window
                // truncates on the right instead of centering and clipping both edges.
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(recentNodes.enumerated()), id: \.element.id) { idx, node in
                        SessionNodeView(node: node, expanded: $expandedNodes, store: store,
                                        isFirst: idx == 0, isLast: idx == recentNodes.count - 1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 6)
                    }
                }.padding(.vertical, 6).frame(maxWidth: .infinity)
            }
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
