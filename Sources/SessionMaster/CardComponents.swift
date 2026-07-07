import SwiftUI
import SessionCore

// The card design system (v0.5.0): a small palette, a context ring, brood pips for children,
// a source badge, chips, and the shared empty/quiet/permission state panel. Everything else
// (colors that mean session state) comes from Attention.color in AttentionStyle.swift.

extension Color {
    /// Chrome accent — the only strong color that isn't a session state. Primary buttons, selected
    /// controls, links, focus. A desaturated sage (#7fb0a8), terminal-adjacent, quiet.
    static let sage = Color(red: 0.498, green: 0.690, blue: 0.659)
    /// A calm context-ring fill while the budget is still healthy (#5f8f7e).
    static let ctxLow = Color(red: 0.372, green: 0.561, blue: 0.494)
    static let claudeHue = Color(red: 1.0, green: 0.624, blue: 0.039)   // #ff9f0a
    static let codexHue = Color(red: 0.749, green: 0.353, blue: 0.941)  // #bf5af0
}

/// Context-window gauge. A ring that fills with usage; it stays calm (sage-green) until the budget
/// tightens, then warns amber (≥70%) and red (≥85%). The collapsed row shows a small unlabeled one
/// only when it's getting high; the expanded card shows the labeled one always.
struct ContextRing: View {
    let percent: Int
    var size: CGFloat = 34
    var showLabel = true

    var color: Color { percent >= 85 ? .red : percent >= 70 ? .yellow : .ctxLow }
    private var lw: CGFloat { max(2, size * 0.09) }

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.08), lineWidth: lw)
            Circle().trim(from: 0, to: min(1, CGFloat(percent) / 100))
                .stroke(color, style: StrokeStyle(lineWidth: lw, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if showLabel {
                Text("\(percent)")
                    .font(.system(size: size * 0.31, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .help("\(percent)% of context window used")
    }
}

/// Brood pips — how a collapsed card signals what it spawned. Only *loud* children draw a mark:
/// needs-approval (red) first, then working (green), capped at three with a `+N` overflow. Children
/// that exist but are all quiet fold into one hollow ring; no children draws nothing. The whole
/// thing is display-only (a `.help` census on hover), so the row keeps its single click = expand.
struct BroodPips: View {
    let children: [UnifiedSession]

    /// One pass over the (tiny) child list → the loud ones (needs-approval, then your-turn, then
    /// working — any state that wants the user or is active) and the census counts, so a collapsed
    /// row isn't scanning the array five times per render.
    private var summary: (loud: [UnifiedSession], census: String) {
        var loud: [UnifiedSession] = []
        var approval = 0, working = 0, turn = 0, idle = 0
        for k in children {
            switch k.attention {
            case .needsApproval: approval += 1; loud.append(k)
            case .awaitingYou:   turn += 1;     loud.append(k)
            case .working:       working += 1;  loud.append(k)
            default:             idle += 1
            }
        }
        loud.sort { $0.attention.rank < $1.attention.rank }
        let parts = [(approval, "needs approval"), (turn, "your turn"),
                     (working, "working"), (idle, "idle")]
            .compactMap { $0.0 > 0 ? "\($0.0) \($0.1)" : nil }
        return (loud, parts.joined(separator: " · "))
    }

    var body: some View {
        let (loud, census) = summary
        if children.isEmpty {
            EmptyView()
        } else if loud.isEmpty {
            // All quiet: a calm hollow ring, but keep the fan-out count visible (a session with 12
            // idle sub-agents shouldn't look like one with 1).
            HStack(spacing: 4) {
                Circle().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1.4).frame(width: 6, height: 6)
                if children.count > 1 {
                    Text("\(children.count)").font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }.help("Sub-agents · " + census)
        } else {
            HStack(spacing: 3) {
                ForEach(Array(loud.prefix(3).enumerated()), id: \.offset) { _, c in
                    Circle().fill(c.attention.color).frame(width: 5, height: 5)
                }
                if loud.count > 3 {
                    Text("+\(loud.count - 3)")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                }
            }
            .help(census)
        }
    }
}

/// The surface glyph — WHERE the session lives, its own monochrome channel now that the tool
/// (Claude/Codex) is carried by the colored ToolMark. A filled terminal = a live terminal you can
/// recall, an outline terminal = a closed CLI session, a macwindow = a Desktop-app conversation.
func surfaceGlyph(_ s: UnifiedSession) -> String {
    switch s.source {
    case .claudeDesktop, .codexDesktop: return "macwindow"
    case .claudeCLI, .codexCLI:
        return (s.terminal.terminalPID != nil || s.terminal.viaTmux) ? "terminal.fill" : "terminal"
    }
}
func surfaceHelp(_ s: UnifiedSession) -> String {
    switch s.source {
    case .claudeDesktop, .codexDesktop: return "Desktop app conversation"
    case .claudeCLI, .codexCLI:
        return (s.terminal.terminalPID != nil || s.terminal.viaTmux)
            ? "Terminal — attached (recallable)" : "CLI session — terminal closed"
    }
}
func sourceHue(_ s: UnifiedSession) -> Color { s.source.isCodex ? .codexHue : .claudeHue }

// MARK: - Tool marks (hand-drawn, brand-evoking — no vendor asset files in the repo)

/// Claude's mark: an orange radial sunburst.
struct ClaudeMark: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: r.midX, y: r.midY)
        let rays = 11
        let inner = min(r.width, r.height) * 0.12
        for i in 0..<rays {
            let a = CGFloat(i) / CGFloat(rays) * 2 * .pi - .pi / 2
            let len = min(r.width, r.height) * (i % 2 == 0 ? 0.5 : 0.4)   // slight variation → organic
            p.move(to: CGPoint(x: c.x + cos(a) * inner, y: c.y + sin(a) * inner))
            p.addLine(to: CGPoint(x: c.x + cos(a) * len, y: c.y + sin(a) * len))
        }
        return p
    }
}

/// Codex's mark: a purple six-petal blossom (evokes the OpenAI knot silhouette).
struct CodexMark: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let w = min(r.width, r.height)
        let base = CGRect(x: r.midX + w * 0.05, y: r.midY - w * 0.10, width: w * 0.4, height: w * 0.2)
        for i in 0..<6 {
            let a = CGFloat(i) / 6 * 2 * .pi
            let t = CGAffineTransform(translationX: r.midX, y: r.midY)
                .rotated(by: a)
                .translatedBy(x: -r.midX, y: -r.midY)
            p.addPath(Path(ellipseIn: base), transform: t)
        }
        return p
    }
}

/// The colored tool mark — Claude vs Codex at a glance, in the brand color.
struct ToolMark: View {
    let session: UnifiedSession
    var size: CGFloat = 13
    var body: some View {
        Group {
            if session.source.isCodex {
                CodexMark().stroke(Color.codexHue, style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
            } else {
                ClaudeMark().stroke(Color.claudeHue, style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
            }
        }
        .frame(width: size, height: size)
        .help(session.source.isCodex ? "Codex" : "Claude")
    }
}

/// A capsule chip — always its natural size (never compresses into vertical text).
struct Chip: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text).font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.18)).foregroundStyle(color)
            .clipShape(Capsule()).fixedSize()
    }
}

/// The shared centered state panel: empty / all-quiet / no-permission. One icon, a headline, a
/// quiet subline, an optional action — same restraint as the cards (one state hue + sage button).
struct StatePanel: View {
    let systemImage: String
    let iconTint: Color
    let title: String
    let subtitle: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: systemImage).font(.system(size: 26))
                .foregroundStyle(iconTint).padding(.bottom, 8)
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(subtitle).font(.system(size: 11.5)).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center).frame(maxWidth: 240)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent).tint(.sage).controlSize(.regular)
                    .pointerCursor().padding(.top, 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(40)
    }
}
