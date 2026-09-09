import AppKit
import SwiftUI
import SMBKeeperCore

/// The app's one colour and glyph vocabulary for share state.
///
/// The two semantic accents are fixed so a screenshot reads the same in either
/// appearance, while everything neutral comes from macOS's dynamic system
/// colours, so light and dark and the user's accent colour are honoured.
enum StateStyle {
    /// Positive: mounted and answering.
    static let positive = Color(nsColor: NSColor(srgbRed: 0.153, green: 0.682, blue: 0.376, alpha: 1))
    /// Negative: hung, failed, and destructive actions.
    static let negative = Color(nsColor: NSColor(srgbRed: 0.855, green: 0.267, blue: 0.325, alpha: 1))

    static func color(for state: ShareState) -> Color {
        switch state {
        case .healthy: return positive
        case .stale, .failed: return negative
        case .paused: return Color.secondary.opacity(0.65)
        case .unmounted, .unreachable, .unknown: return Color.secondary
        case .mounting, .unmounting: return Color.accentColor
        }
    }

    /// SF Symbol shown in the row's state badge.
    static func symbol(for state: ShareState) -> String {
        switch state {
        case .healthy: return "checkmark"
        case .stale: return "exclamationmark"
        case .failed: return "xmark"
        case .paused: return "pause.fill"
        case .unmounted: return "eject"
        case .unreachable: return "wifi.slash"
        case .mounting: return "arrow.down"
        case .unmounting: return "arrow.up"
        case .unknown: return "clock"
        }
    }
}

/// The state badge: a tinted circle with the state glyph.
struct StateBadge: View {
    let state: ShareState
    var size: CGFloat = 26

    var body: some View {
        let tint = StateStyle.color(for: state)
        return ZStack {
            Circle().fill(tint.opacity(0.18))
            Image(systemName: StateStyle.symbol(for: state))
                .font(.system(size: size * 0.44, weight: .bold))
                .foregroundStyle(tint)
        }
        .frame(width: size, height: size)
    }
}
