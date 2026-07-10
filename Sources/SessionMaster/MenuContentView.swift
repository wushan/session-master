import SwiftUI
import AppKit
import SessionCore

struct MenuContentView: View {
    @Bindable var store: SessionStore
    @Environment(\.openWindow) private var openWindow
    @State private var openId: String?
    @State private var editingId: String?
    @State private var search = ""
    @State private var olderResults: [UnifiedSession] = []
    @State private var popoverWindow: NSWindow?
    @State private var settings = AppSettings.shared

    /// Open the dashboard to a tab and dismiss the menu-bar popover (it doesn't auto-close when
    /// we bring our own window forward).
    private func showDashboard(_ tab: DashboardTab) {
        store.selectedTab = tab
        popoverWindow?.close()
        openDashboard(openWindow)
    }

    /// The popover is the "who needs me NOW" surface: by default it triages (needs-you + working
    /// only) instead of duplicating the dashboard's 20-50-row haystack. "Show all" persists as a
    /// preference; typing in search always looks through the full set.
    private var popoverSessions: [UnifiedSession] {
        let sorted = store.sessions.sorted {
            $0.attention.rank != $1.attention.rank
                ? $0.attention.rank < $1.attention.rank
                : ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast)
        }
        if !search.isEmpty {
            // Fold in older/archived ended matches (same scan as the dashboard) — the popover is
            // the surface people actually search from, and a conversation archived in Desktop
            // whose transcript is past the 24h window exists ONLY in that scan.
            let base = sorted.filter(matchesSearch)
            let have = Set(base.map(\.id))
            return (base + olderResults.filter { matchesSearch($0) && !have.contains($0.id) })
                .sorted { a, b in
                    // The session you named is what you're looking for — a title hit outranks
                    // attention/recency; those only break ties.
                    let (ta, tb) = (titleHit(a), titleHit(b))
                    if ta != tb { return ta }
                    if a.attention.rank != b.attention.rank { return a.attention.rank < b.attention.rank }
                    return (a.updatedAt ?? .distantPast) > (b.updatedAt ?? .distantPast)
                }
        }
        guard !settings.popoverShowAll else { return sorted }
        return sorted.filter { $0.attention.needsUser || $0.attention == .working }
    }

    private func matchesSearch(_ s: UnifiedSession) -> Bool {
        [s.displayTitle, s.projectName, s.branch, s.model, s.cwd, s.subtitle]
            .compactMap { $0 }.joined(separator: " ").localizedCaseInsensitiveContains(search)
    }
    private func titleHit(_ s: UnifiedSession) -> Bool {
        s.displayTitle.localizedCaseInsensitiveContains(search)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            searchBar
            Divider()
            content
        }
        .frame(width: 380)
        .background(WindowAccessor { popoverWindow = $0 })
        // Clear the open card when filtering changes so it can't re-open a row that scrolled away.
        .onChange(of: search) { openId = nil; editingId = nil }
        .onChange(of: settings.popoverShowAll) { openId = nil; editingId = nil }
        // Search reaches older (out-of-window / archived) closed sessions, same as the dashboard.
        .task(id: search) {
            guard search.count >= 2 else { olderResults = []; return }
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            let r = await store.searchOlder(search)
            if !Task.isCancelled { olderResults = r }
        }
    }

    @ViewBuilder private var content: some View {
        Group {
            let sessions = popoverSessions
            if !store.hasLoaded {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading sessions…").foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 28)
            } else if sessions.isEmpty {
                // Triage view empty ≠ no sessions: say the quiet part and offer the way out.
                let quiet = search.isEmpty && !settings.popoverShowAll && !store.sessions.isEmpty
                Text(quiet ? "All quiet — nothing needs you"
                     : (search.isEmpty ? "No active sessions" : "No matches"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 24)
            } else {
                // Height must be sized to the TREE rows actually rendered — the flat session
                // count includes claimed companions (collapsed children), which would reserve
                // ~84pt of permanent blank space each.
                let nodes = SessionTree.build(sessions, extraChildren: store.subagentChildren)
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(nodes) { node in
                            SessionNodeView(node: node, openId: $openId, editingId: $editingId, store: store)
                        }
                    }.padding(8)
                }
                // ScrollView has no intrinsic height inside a self-sizing menu-bar
                // window, so it collapses to 0. Give it a concrete, content-aware height
                // (~100pt/row now the title and badges are on separate lines).
                .frame(height: min(CGFloat(nodes.count) * 100 + 16, 560))
            }
            if search.isEmpty, !store.sessions.isEmpty {
                Button {
                    settings.popoverShowAll.toggle()
                } label: {
                    Text(settings.popoverShowAll
                         ? "Show only sessions that need me"
                         : "Show all \(store.sessions.count) sessions")
                        .font(.caption).foregroundStyle(.tint)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointerCursor()
                .padding(.vertical, 5)
            }
            if !store.jobs.isEmpty {
                Divider()
                automations
            }
            Divider()
            footer
        }
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(.secondary)
            TextField("Filter sessions", text: $search).textFieldStyle(.plain).font(.system(size: 13))
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 13)) }
                    .buttonStyle(.plain).foregroundStyle(.tertiary).pointerCursor()
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .background(Color.primary.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Sessions").font(.headline)
            if let v = store.availableUpdate {
                Button { showDashboard(.about) } label: {
                    Label("Update \(v)", systemImage: "arrow.down.circle.fill")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.orange.opacity(0.18)).foregroundStyle(.orange)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain).pointerCursor().help("A new version is available — open About to update")
            }
            Spacer()
            if store.needsApprovalCount > 0 {
                Label("\(store.needsApprovalCount)", systemImage: "bell.badge.fill")
                    .font(.caption).foregroundStyle(.red).help("Need approval")
            }
            if store.awaitingYouCount > 0 {
                Label("\(store.awaitingYouCount)", systemImage: "person.fill.questionmark")
                    .font(.caption).foregroundStyle(.yellow).help("Your turn")
            }
            Text(search.isEmpty && !settings.popoverShowAll && popoverSessions.count < store.sessions.count
                 ? "\(popoverSessions.count) / \(store.sessions.count)"
                 : "\(popoverSessions.count)")
                .font(.caption).foregroundStyle(.secondary)
                .help("Sessions shown / total")
        }.padding(.horizontal, 12).padding(.vertical, 8)
    }

    @State private var showJobs = false
    @State private var openAuto: String?
    private var automations: some View {
        DisclosureGroup(isExpanded: $showJobs) {
            VStack(spacing: 2) {
                ForEach(store.jobs) { job in
                    JobRowView(job: job, isOpen: openAuto == job.id,
                               onToggle: { openAuto = (openAuto == job.id) ? nil : job.id },
                               onVSCode: { store.openInVSCode(path: $0) })
                }
            }.padding(.horizontal, 8).padding(.bottom, 6)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "clock.badge.checkmark").font(.caption)
                Text("Automations & Routines").font(.caption.weight(.medium))
                Spacer()
                Text("\(store.jobs.filter { !$0.isPaused }.count) active").font(.caption2).foregroundStyle(.secondary)
            }.contentShape(Rectangle())
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button { store.toggleLaunchAtLogin() } label: {
                Image(systemName: store.launchAtLogin ? "bolt.fill" : "bolt")
                    .foregroundStyle(store.launchAtLogin ? .yellow : .secondary)
            }
            .buttonStyle(.borderless).pointerCursor()
            .help(store.launchAtLogin ? "Launch at login: on" : "Launch at login: off")
            Button { showDashboard(.config) } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless).pointerCursor().help("Settings")

            if !store.accessibilityTrusted {
                Button { store.requestAccessibility() } label: {
                    Label("Enable recall", systemImage: "exclamationmark.shield")
                }.buttonStyle(.borderless).foregroundStyle(.orange).font(.caption).pointerCursor()
            } else if let msg = store.lastRecallMessage {
                Text(msg).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button { showDashboard(.sessions) } label: {
                Label("Dashboard", systemImage: "macwindow.badge.plus")
            }
            .buttonStyle(.borderedProminent).controlSize(.large).pointerCursor()
        }.padding(.horizontal, 12).padding(.vertical, 8)
    }
}
