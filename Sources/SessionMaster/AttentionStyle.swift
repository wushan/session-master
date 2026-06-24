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
        case .unknown:       return Color.secondary.opacity(0.5)
        }
    }
}
