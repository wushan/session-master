import SwiftUI
import SessionCore

struct MenuContentView: View {
    @Bindable var store: SessionStore
    @Bindable var floating: FloatingPanel
    @Environment(\.openWindow) private var openWindow
    @State private var collapsed: Set<String> = []
    @State private var search = ""

    /// Show every session so you can pick any one back up — sorted so the ones needing you
    /// (and then the most recently active) are at the top.
    private var popoverSessions: [UnifiedSession] {
        let sorted = store.sessions.sorted {
            $0.attention.rank != $1.attention.rank
                ? $0.attention.rank < $1.attention.rank
                : ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast)
        }
        guard !search.isEmpty else { return sorted }
        return sorted.filter { s in
            [s.displayTitle, s.projectName, s.branch, s.model, s.cwd, s.subtitle]
                .compactMap { $0 }.joined(separator: " ").localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            searchBar
            Divider()
            let sessions = popoverSessions
            if !store.hasLoaded {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading sessions…").foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 28)
            } else if sessions.isEmpty {
                Text(search.isEmpty ? "No active sessions" : "No matches").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 24)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(SessionTree.build(sessions, extraChildren: store.subagentChildren)) { node in
                            SessionNodeView(node: node, collapsed: $collapsed, store: store)
                        }
                    }.padding(8)
                }
                // ScrollView has no intrinsic height inside a self-sizing menu-bar
                // window, so it collapses to 0. Give it a concrete, content-aware height.
                .frame(height: min(CGFloat(sessions.count) * 84 + 16, 520))
            }
            if !store.jobs.isEmpty {
                Divider()
                automations
            }
            Divider()
            footer
        }
        .frame(width: 380)
        .onAppear {
            store.openDashboard = { tab in
                store.selectedTab = tab
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
            TextField("Filter sessions", text: $search).textFieldStyle(.plain).font(.caption)
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.tertiary).pointerCursor()
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Color.primary.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Sessions").font(.headline)
            Spacer()
            if store.needsApprovalCount > 0 {
                Label("\(store.needsApprovalCount)", systemImage: "bell.badge.fill")
                    .font(.caption).foregroundStyle(.red).help("Need approval")
            }
            if store.awaitingYouCount > 0 {
                Label("\(store.awaitingYouCount)", systemImage: "person.fill.questionmark")
                    .font(.caption).foregroundStyle(.yellow).help("Your turn")
            }
            Text("\(popoverSessions.count)").font(.caption).foregroundStyle(.secondary)
            Button { floating.toggle() } label: {
                Image(systemName: floating.isShown ? "pin.fill" : "pin")
                    .foregroundStyle(floating.isShown ? .blue : .secondary)
            }
            .buttonStyle(.borderless).pointerCursor()
            .help(floating.isShown ? "Unpin floating window" : "Pin as floating window")
        }.padding(.horizontal, 12).padding(.vertical, 8)
    }

    @State private var showJobs = false
    private var automations: some View {
        DisclosureGroup(isExpanded: $showJobs) {
            VStack(spacing: 2) {
                ForEach(store.jobs) { job in
                    JobRowView(job: job, onVSCode: { store.openInVSCode(path: $0) })
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
        HStack {
            if !store.accessibilityTrusted {
                Button {
                    store.requestAccessibility()
                } label: {
                    Label("Enable recall", systemImage: "exclamationmark.shield")
                }.buttonStyle(.borderless).foregroundStyle(.orange).font(.caption).pointerCursor()
            } else if let msg = store.lastRecallMessage {
                Text(msg).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button { store.toggleLaunchAtLogin() } label: {
                Image(systemName: store.launchAtLogin ? "bolt.fill" : "bolt")
                    .foregroundStyle(store.launchAtLogin ? .yellow : .secondary)
            }
            .buttonStyle(.borderless).font(.caption).pointerCursor()
            .help(store.launchAtLogin ? "Launch at login: on" : "Launch at login: off")
            Button { store.selectedTab = .config; openDashboard(openWindow) } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless).pointerCursor().help("Settings")
            Button { store.selectedTab = .sessions; openDashboard(openWindow) } label: {
                Label("Dashboard", systemImage: "macwindow.badge.plus")
            }
            .buttonStyle(.borderedProminent).controlSize(.large).pointerCursor()
        }.padding(.horizontal, 12).padding(.vertical, 8)
    }
}
