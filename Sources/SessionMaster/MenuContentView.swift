import SwiftUI
import SessionCore

struct MenuContentView: View {
    @Bindable var store: SessionStore
    @Environment(\.openWindow) private var openWindow
    @State private var collapsed: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if store.sessions.isEmpty {
                Text("No live sessions").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 24)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(SessionTree.build(store.sessions, extraChildren: store.subagentChildren)) { node in
                            SessionNodeView(node: node, collapsed: $collapsed, store: store)
                        }
                    }.padding(8)
                }
                // ScrollView has no intrinsic height inside a self-sizing menu-bar
                // window, so it collapses to 0. Give it a concrete, content-aware height.
                .frame(height: min(CGFloat(store.sessions.count) * 66 + 16, 460))
            }
            if !store.jobs.isEmpty {
                Divider()
                automations
            }
            Divider()
            footer
        }
        .frame(width: 380)
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
            Text("\(store.sessions.count)").font(.caption).foregroundStyle(.secondary)
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
            Button { openDashboard(openWindow) } label: { Label("Dashboard", systemImage: "macwindow") }
                .buttonStyle(.borderless).font(.caption).pointerCursor()
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.borderless).font(.caption).pointerCursor()
        }.padding(.horizontal, 12).padding(.vertical, 6)
    }
}
