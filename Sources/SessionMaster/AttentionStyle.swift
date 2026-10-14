import SwiftUI
import SessionCore

/// Maps the semantic Attention state to its dot color (single source of truth for the UI).
extension UnifiedSession.Attention {
    var color: Color {
        switch self {
        case .needsApproval: return .red       // needs your approval — most urgent
        case .awaitingYou:   return .yellow     // your turn to respond
        case .working:       return .green      // actively working
        case .idle:          return .secondary
        case .ended:         return Color.secondary.opacity(0.5)   // dim — resumable, not active
        case .unknown:       return Color.secondary.opacity(0.5)
        }
    }
}

/// One status mark for menu, dashboard and child rows. Native progress animates only
/// while the tool reports work; completed/blocked sessions never keep spinning.
struct SessionStatusIndicator: View {
    let session: UnifiedSession
    var size: CGFloat = 12
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if session.attention == .working {
                if reduceMotion { Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.green) }
                else { ProgressView().controlSize(.mini) }
            } else if session.attention == .needsApproval {
                Image(systemName: "hand.raised.fill").foregroundStyle(.red)
            } else if session.status == .input {
                Image(systemName: "questionmark.circle.fill").foregroundStyle(.yellow)
            } else if session.status == .completed {
                Image(systemName: "checkmark.circle").foregroundStyle(session.attention.needsUser ? .yellow : .secondary)
            } else if session.status == .failed || session.status == .interrupted {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary)
            } else {
                Circle().fill(session.attention.color).frame(width: size * 0.65, height: size * 0.65)
            }
        }
        .font(.system(size: size)).frame(width: size, height: size)
        .accessibilityElement(children: .ignore).accessibilityLabel(session.statusLabel)
        .help(session.waitingFor ?? session.statusLabel)
    }
}
