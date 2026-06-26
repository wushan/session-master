import SwiftUI
import SessionCore

struct JobRowView: View {
    let job: ScheduledJob
    let onVSCode: (String) -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: job.source == .codex ? "clock.arrow.2.circlepath" : "repeat")
                .font(.system(size: 12))
                .foregroundStyle(job.isPaused ? Color.secondary : (job.source == .codex ? .purple : .orange))
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    .foregroundStyle(job.isPaused ? .secondary : .primary)
                HStack(spacing: 6) {
                    Text(scheduleText)
                    if let m = job.model { Text("· \(m)") }
                    if let e = job.effort { Text("· \(e)") }
                }.font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let cwd = job.primaryCwd {
                IconButton(systemName: "chevron.left.forwardslash.chevron.right",
                           help: "Open \(cwd) in VS Code") { onVSCode(cwd) }
                    .opacity(hovering ? 1 : 0.4)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(hovering ? Color.primary.opacity(0.05) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onHover { hovering = $0 }
    }

    private var scheduleText: String {
        if job.isPaused { return "Paused" }
        if let n = job.nextRun { return "next " + relative(n) }
        if job.source == .claude { return "routine" }
        return "—"
    }

    private func relative(_ d: Date) -> String {
        let s = d.timeIntervalSinceNow
        if s < 0 { return "due" }
        if s < 3600 { return "in \(Int(s / 60))m" }
        if s < 86_400 { return "in \(Int(s / 3600))h" }
        let f = DateFormatter(); f.dateFormat = "EEE HH:mm"; return f.string(from: d)
    }
}
