import AppKit
import SwiftUI
import SMBKeeperCore

/// One share in the panel list, all of it on screen at once: a state badge, the
/// share's name, how full the volume is, a bar of the same, where it is
/// mounted, and the three buttons that act on it.
struct ShareRowView: View {
    @ObservedObject var store: ShareStore
    let share: ShareStatus
    var actions = PanelActions()

    @State private var hovering = false

    private var isSelected: Bool { store.selectedName == share.name }
    private var tint: Color { StateStyle.color(for: share.state) }
    private var action: Presentation.RowAction { store.rowAction(for: share) }

    var body: some View {
        HStack(spacing: 8) {
            StateBadge(state: share.state)
            VStack(alignment: .leading, spacing: 3) {
                Text(share.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                ProgressGauge(fraction: gaugeFraction, color: tint)
                if let path = share.mountPath {
                    Text(path)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        // A path's useful end is its last component, so drop
                        // characters from the front rather than the middle.
                        .truncationMode(.head)
                        .textSelection(.enabled)
                        .help(path)
                }
            }
            HStack(spacing: 2) {
                primaryAction
                if store.canReveal(share.name) { revealButton }
                stopMonitoringButton
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.accentColor.opacity(highlightAlpha))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { store.select(share.name) }
        .contextMenu { contextMenu }
    }

    private var highlightAlpha: Double {
        if isSelected { return hovering ? 0.45 : 0.32 }
        return hovering ? 0.14 : 0
    }

    /// How full the volume is when it is answering, otherwise whatever the
    /// engine last said about it.
    private var subtitle: String {
        guard share.state == .healthy else { return share.detail }
        if let capacity = share.capacity, capacity.totalBytes > 0 {
            return "\(Format.bytes(capacity.freeBytes)) free of \(Format.bytes(capacity.totalBytes))"
        }
        return share.state.rawValue.capitalized
    }

    /// How full the volume is; a full bar for a healthy share with no figure,
    /// and an empty one for anything not answering.
    private var gaugeFraction: Double {
        if let used = share.capacity?.usedFraction, share.state == .healthy { return used }
        switch share.state {
        case .healthy: return 1
        case .mounting, .unmounting: return 0.5
        default: return 0
        }
    }

    // MARK: Buttons

    /// One button that follows the volume: mount while nothing is attached,
    /// unmount once something is, and force once an unmount has been asked for
    /// and the volume is still there.
    @ViewBuilder
    private var primaryAction: some View {
        switch action {
        case .mount:
            iconButton(stroke: StateStyle.positive, help: "Mount \(share.name)") {
                store.mount(share.name)
            } label: {
                // The eject glyph turned over: the same shape pointing the other
                // way, so the pair reads as one control with two directions.
                Image(systemName: "eject")
                    .font(.system(size: 11, weight: .medium))
                    .rotationEffect(.degrees(180))
                    .foregroundStyle(StateStyle.positive)
            }
        case .unmount:
            iconButton(stroke: Color.secondary, help: "Unmount \(share.name)") {
                store.requestUnmount(share.name)
            } label: {
                Image(systemName: "eject")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.secondary)
            }
        case .forceUnmount:
            iconButton(stroke: StateStyle.negative, help: "Force unmount \(share.name)") {
                store.forceUnmount(share.name)
            } label: {
                // No SF Symbol pairs eject with a warning, so the badge is
                // composed: the glyph stays legible and the red mark reads as
                // "this is the forceful one".
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "eject")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.secondary)
                    Image(systemName: "exclamationmark")
                        .font(.system(size: 7, weight: .black))
                        .foregroundStyle(StateStyle.negative)
                        .offset(x: 4, y: -2)
                }
            }
        }
    }

    private var revealButton: some View {
        iconButton(stroke: Color.secondary, help: "Reveal \(share.name) in Finder") {
            store.reveal(share.name)
        } label: {
            Image(systemName: "folder")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.secondary)
        }
    }

    /// Stop monitoring: an outlined hexagon with a cross through the middle.
    /// `xmark.hexagon` does not exist, so the two glyphs are stacked. No box
    /// around it — the hexagon is its own outline, and a border on top of that
    /// reads as two nested shapes.
    private var stopMonitoringButton: some View {
        Button {
            actions.removeShare(share.name)
        } label: {
            ZStack {
                Image(systemName: "hexagon")
                    .font(.system(size: 15, weight: .light))
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
            }
            .foregroundStyle(StateStyle.negative)
            .frame(width: 26, height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Stop monitoring \(share.name). The volume stays mounted.")
    }

    private func iconButton<Label: View>(stroke: Color, help: String,
                                         action: @escaping () -> Void,
                                         @ViewBuilder label: () -> Label) -> some View {
        Button(action: action) {
            label()
                .frame(width: 26, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(stroke.opacity(0.75), lineWidth: 1)
                )
                // Without this the hit region is the glyph alone: the border is
                // a stroke and the box inside it is empty, so clicks just short
                // of it do nothing and the button feels unreliable.
                .contentShape(RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: Context menu

    @ViewBuilder
    private var contextMenu: some View {
        if action == .mount {
            Button("Mount now") { store.mount(share.name) }
        } else {
            Button("Unmount") { store.requestUnmount(share.name) }
            Button("Force unmount") { store.forceUnmount(share.name) }
        }
        if store.canReveal(share.name) {
            Divider()
            Button("Reveal in Finder") { store.reveal(share.name) }
        }
        Divider()
        Button("Stop monitoring…") { actions.removeShare(share.name) }
    }
}
