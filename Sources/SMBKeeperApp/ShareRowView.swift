import AppKit
import SwiftUI
import SMBKeeperCore

/// One share in the panel list: a compact header (state badge, name, subtitle,
/// slim state-coloured bar, primary action, chevron) that expands in place into
/// quick actions plus a details grid.
struct ShareRowView: View {
    @ObservedObject var store: ShareStore
    let share: ShareStatus
    var actions = PanelActions()

    @State private var hovering = false

    private var isSelected: Bool { store.selectedName == share.name }
    private var isExpanded: Bool { store.expandedNames.contains(share.name) }
    private var tint: Color { StateStyle.color(for: share.state) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded { expandedBody }
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
        .animation(.easeInOut(duration: 0.1), value: isExpanded)
    }

    private var highlightAlpha: Double {
        if isSelected { return hovering ? 0.45 : 0.32 }
        return hovering ? 0.14 : 0
    }

    // MARK: Header

    private var header: some View {
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
            }
            // Tighter than the row's 8pt rhythm: the chevron's target is 30
            // wide around a 10pt glyph, so the whitespace is already inside it.
            HStack(spacing: 2) {
                primaryAction
                if store.canReveal(share.name) { revealButton }
                chevron
            }
        }
    }

    /// Capacity when the share is answering, otherwise whatever the engine last
    /// said about it. Latency is not here at all: it belongs to the expanded
    /// grid, where there is room to label it.
    private var subtitle: String {
        guard share.state == .healthy else { return share.detail }
        if let capacity = share.capacity, capacity.totalBytes > 0 {
            return "\(Format.bytes(capacity.freeBytes)) free of \(Format.bytes(capacity.totalBytes))"
        }
        return share.mountPath ?? share.detail
    }

    /// Reveal sits beside the primary action rather than inside the expanded
    /// body: opening the volume is the thing most often wanted, and it should
    /// not need a disclosure first.
    private var revealButton: some View {
        outlineButton(symbol: "folder", color: nil, help: "Reveal \(share.name) in Finder") {
            store.reveal(share.name)
        }
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

    /// Mount (green) when it is not mounted, Unmount (plain) when it is
    /// healthy, and a red ✕ to force-unmount one that has stopped answering.
    @ViewBuilder
    private var primaryAction: some View {
        switch share.state {
        case .healthy:
            outlineButton(title: "Unmount", color: nil, help: "Unmount \(share.name)") {
                store.unmount(share.name)
            }
        case .stale, .failed:
            outlineButton(symbol: "xmark", color: StateStyle.negative, help: "Force unmount") {
                store.forceUnmount(share.name)
            }
        case .paused:
            outlineButton(title: "Resume", color: StateStyle.positive, help: "Resume watching") {
                store.setPaused(false)
            }
        default:
            outlineButton(title: "Mount", color: StateStyle.positive, help: "Mount now") {
                store.mount(share.name)
            }
        }
    }

    private func outlineButton(title: String? = nil, symbol: String? = nil,
                               color: Color?, help: String = "",
                               action: @escaping () -> Void) -> some View {
        let stroke = color ?? Color.secondary
        return Button(action: action) {
            Group {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 10, weight: .bold))
                } else {
                    Text(title ?? "").font(.system(size: 11))
                }
            }
            .foregroundStyle(stroke)
            .frame(minWidth: symbol == nil ? 44 : 20, minHeight: 18)
            .padding(.horizontal, symbol == nil ? 4 : 2)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(stroke.opacity(0.75), lineWidth: 1)
            )
            // Without this the hit region is the glyph alone: the border is a
            // stroke and the box inside it is empty, so clicks just short of
            // the label do nothing and the button feels unreliable.
            .contentShape(RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// The glyph stays 10pt; the target around it is deliberately much bigger,
    /// because a miss does not do nothing, it lands on the row and selects.
    private var chevron: some View {
        Button {
            store.toggleExpanded(share.name)
        } label: {
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 30)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "Collapse" : "Show details")
    }

    // MARK: Expanded body

    private var expandedBody: some View {
        VStack(alignment: .leading, spacing: 2) {
            actionBar
            Divider().padding(.vertical, 4)
            detailGrid
        }
        .padding(.leading, 34)
        .padding(.trailing, 6)
        .padding(.top, 6)
    }

    /// The operations on the left as a group of bordered glyphs, and the one
    /// destructive action set apart on the right.
    private var actionBar: some View {
        HStack(spacing: 6) {
            if share.state != .healthy {
                borderedIcon(help: "Mount \(share.name) now", stroke: StateStyle.positive) {
                    store.mount(share.name)
                } label: {
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(StateStyle.positive)
                }
            }
            borderedIcon(help: "Unmount \(share.name)", stroke: Color.secondary) {
                store.unmount(share.name)
            } label: {
                Image(systemName: "eject")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.secondary)
            }
            borderedIcon(help: "Force unmount \(share.name), for a mount that has stopped answering", stroke: StateStyle.negative) {
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
            Spacer(minLength: 8)
            stopMonitoringButton
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 2)
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

    /// A glyph in the same outlined box as the row's primary action, so the
    /// expanded controls read as part of the same family.
    private func borderedIcon<Label: View>(help: String, stroke: Color,
                                           action: @escaping () -> Void,
                                           @ViewBuilder label: () -> Label) -> some View {
        Button(action: action) {
            label()
                .frame(width: 26, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(stroke.opacity(0.75), lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// Six quick facts in two columns of three.
    private var detailGrid: some View {
        let pairs: [(String, String)] = [
            ("Status", share.state.rawValue.capitalized),
            ("Server", share.server),
            ("Share", share.share),
            ("Mounted", share.mountPath ?? "—"),
            ("Latency", share.lastProbeLatencyMs.map { Format.latency(milliseconds: $0) } ?? "—"),
            ("Last ok", share.lastHealthyAt.map { Format.relative($0) } ?? "never"),
        ]
        return HStack(alignment: .top, spacing: 12) {
            detailColumn(Array(pairs[0..<3]))
            detailColumn(Array(pairs[3..<6]))
        }
        .padding(.horizontal, 6)
    }

    private func detailColumn(_ pairs: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(pairs, id: \.0) { key, value in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(key)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 46, alignment: .leading)
                    Text(value)
                        .font(.caption2)
                        .lineLimit(1)
                        // A path's useful end is its last component, so drop
                        // characters from the front rather than the middle:
                        // "…olumes/Andrew" beats "/Vol…drew".
                        .truncationMode(value.hasPrefix("/") ? .head : .middle)
                        .textSelection(.enabled)
                        .help(value)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Context menu

    @ViewBuilder
    private var contextMenu: some View {
        if share.state != .healthy {
            Button("Mount now") { store.mount(share.name) }
        }
        Button("Unmount") { store.unmount(share.name) }
        Button("Force unmount") { store.forceUnmount(share.name) }
        if store.canReveal(share.name) {
            Divider()
            Button("Reveal in Finder") { store.reveal(share.name) }
        }
        Divider()
        Button("Stop monitoring…") { actions.removeShare(share.name) }
    }
}
