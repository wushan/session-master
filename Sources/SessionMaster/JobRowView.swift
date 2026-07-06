import SwiftUI
import AppKit
import SessionCore

/// An automation / routine as an accordion card — the same grammar as a session, but its edge
/// means *armed* (sage) or *paused* (dim) rather than an attention state, and "next run" takes the
/// slot a session's age holds. Read-only (the app doesn't pause/run schedules), so the one action
/// is opening its folder in your editor.
struct JobRowView: View {
    let job: ScheduledJob
    var isOpen = false
    var onToggle: () -> Void = {}
    let onVSCode: (String) -> Void

    @State private var hovering = false

    private var edge: Color { job.isPaused ? Color.secondary.opacity(0.5) : .sage }
    private var srcGlyph: String { job.source == .codex ? "cpu" : "bolt.fill" }
    private var srcHue: Color { job.source == .codex ? .codexHue : .claudeHue }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isOpen { body_ }
        }
        .padding(.leading, 3)
        .background(alignment: .leading) {
            RoundedRectangle(cornerRadius: 3).fill(edge).frame(width: 3).padding(.vertical, 10)
        }
        .background(RoundedRectangle(cornerRadius: 13)
            .fill(isOpen ? Color.primary.opacity(0.05) : (hovering ? Color.primary.opacity(0.035) : .clear)))
        .overlay(RoundedRectangle(cornerRadius: 13)
            .strokeBorder(isOpen ? Color.primary.opacity(0.10) : .clear, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }
        .pointerCursor()
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.18), value: isOpen)
    }

    private var header: some View {
        HStack(spacing: 9) {
            Circle().fill(edge).frame(width: 8, height: 8)
            Text(job.name).font(.system(size: 15.5, weight: .semibold)).lineLimit(1)
                .foregroundStyle(job.isPaused ? .secondary : .primary)
            Spacer(minLength: 6)
            Text(nextRunText).font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(job.isPaused ? .tertiary : .secondary)
            Image(systemName: srcGlyph).font(.system(size: 11, weight: .medium)).foregroundStyle(srcHue)
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary).rotationEffect(.degrees(isOpen ? 90 : 0))
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
    }

    private var body_: some View {
        VStack(alignment: .leading, spacing: 10) {
            Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1)
            cell("Schedule", job.rruleText ?? (job.source == .claude ? "harness routine" : "—"))
            cell("Next run", nextRunText)
            if let m = job.model { cell("Model", [m, job.effort].compactMap { $0 }.joined(separator: " · ")) }
            if let cwd = job.primaryCwd { cell("Where", prettyPath(cwd)) }
            if let s = job.summary, !s.isEmpty {
                Text("“\(s)”").font(.system(size: 12)).italic().foregroundStyle(.secondary).lineLimit(2)
            }
            if let cwd = job.primaryCwd {
                Button { onVSCode(cwd) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.left.forwardslash.chevron.right").font(.system(size: 11))
                        Text("Open in editor").font(.system(size: 12))
                    }.padding(.horizontal, 9).padding(.vertical, 5).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(.secondary).pointerCursor()
            }
        }
        .padding(.horizontal, 12).padding(.top, 11).padding(.bottom, 13)
    }

    private func cell(_ cap: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(cap.uppercased()).font(.system(size: 9.5, weight: .semibold)).tracking(0.9).foregroundStyle(.tertiary)
            Text(value).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private var nextRunText: String {
        if job.isPaused { return "Paused" }
        if let n = job.nextRun { return relative(n) }
        return job.source == .claude ? "routine" : "—"
    }
    private func relative(_ d: Date) -> String {
        let s = d.timeIntervalSinceNow
        if s < 0 { return "due" }
        if s < 3600 { return "in \(Int(s / 60))m" }
        if s < 86_400 { return "in \(Int(s / 3600))h" }
        let f = DateFormatter(); f.dateFormat = "EEE HH:mm"; return f.string(from: d)
    }
    private func prettyPath(_ p: String) -> String {
        let home = NSHomeDirectory()
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }
}
