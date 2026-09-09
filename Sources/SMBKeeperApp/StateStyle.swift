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

/// The slim state-coloured bar under each row's subtitle: 4pt tall over a
/// 19%-alpha track, drawn in a Canvas so it costs one draw call per row.
///
/// For a mounted share the fill is how full the volume is. With no capacity
/// figure it falls back to a full bar when the share is healthy and an empty
/// one when it is not, so the bar always says something true at a glance.
struct ProgressGauge: View {
    /// 0-1, clamped on render.
    let fraction: Double
    let color: Color
    var height: CGFloat = 4

    var body: some View {
        Canvas { context, size in
            let radius = height / 2
            let track = CGRect(x: 0, y: 0, width: size.width, height: height)
            context.fill(Path(roundedRect: track, cornerRadius: radius),
                         with: .color(color.opacity(0.19)))
            let done = min(max(fraction, 0), 1)
            if done > 0 {
                let fill = CGRect(x: 0, y: 0, width: size.width * done, height: height)
                context.fill(Path(roundedRect: fill, cornerRadius: radius), with: .color(color))
            }
        }
        .frame(height: height)
    }
}
