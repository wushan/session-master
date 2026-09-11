import SwiftUI
import SessionCore

struct ProjectDashboardView: View {
    let store: SessionStore
    let search: String
    @State private var expanded: Set<String> = []
    @State private var openId: String?
    @State private var editingId: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Projects").font(.largeTitle.bold())
                    Text("Last 10 days · Active tasks first · All active tasks, plus recent conversations up to five")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if !store.hasLoaded {
                    ProgressView("Loading projects…").frame(maxWidth: .infinity)
                } else {
                    desktopSection(.codexDesktop, tint: .sage)
                    desktopSection(.claudeDesktop, tint: .orange)
                }
            }
            .padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: search) { openId = nil; editingId = nil; expanded = [] }
    }

    private func desktopSection(_ source: UnifiedSession.Source, tint: Color) -> some View {
        let projects = DashboardProject.groups(store.sessions, source: source, search: search)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "macwindow").foregroundStyle(tint)
                Text(source.rawValue).font(.title3.weight(.semibold))
                Text("\(projects.count) projects").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            if projects.isEmpty {
                Text(search.isEmpty ? "No desktop projects active in the last 10 days."
                     : "No matching desktop projects.")
                    .foregroundStyle(.secondary).font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(20)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 360), spacing: 16, alignment: .top)],
                          alignment: .leading, spacing: 16) {
                    ForEach(projects) { project in projectCard(project, source: source, tint: tint) }
                }
            }
        }
    }

    private func projectCard(_ project: DashboardProject, source: UnifiedSession.Source, tint: Color) -> some View {
        let key = source.rawValue + ":" + project.id
        let isExpanded = expanded.contains(key)
        let shown = isExpanded ? project.sessions : project.visibleSessions
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "folder.fill").foregroundStyle(tint).font(.title3)
                VStack(alignment: .leading, spacing: 4) {
                    Text(project.name).font(.headline).lineLimit(1).help(project.id)
                    Text(project.id.isEmpty ? "Unknown folder" : project.id)
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if project.activeCount > 0 {
                    Text("\(project.activeCount) active").font(.caption2.weight(.semibold))
                        .foregroundStyle(tint).padding(6)
                        .background(tint.opacity(0.12), in: Capsule())
                }
            }
            Divider()
            VStack(spacing: 2) {
                ForEach(SessionTree.build(shown, extraChildren: store.subagentChildren)) { node in
                    SessionNodeView(node: node,
                                    openId: $openId, editingId: $editingId, store: store, titleLineLimit: 2)
                }
            }
            HStack {
                Text("\(project.sessions.count) conversation\(project.sessions.count == 1 ? "" : "s")").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                if project.sessions.count > project.visibleSessions.count {
                    Button(isExpanded ? "Show less" : "Show all \(project.sessions.count)") {
                        if isExpanded { expanded.remove(key) } else { expanded.insert(key) }
                    }.buttonStyle(.plain).font(.caption.weight(.medium)).foregroundStyle(tint)
                }
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.1)))
    }
}
