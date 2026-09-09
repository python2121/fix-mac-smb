import AppKit
import SwiftUI
import SMBKeeperCore

/// Everything the panel needs from the app shell (windows, dialogs).
/// Passing them in as closures keeps the view free of `AppDelegate`.
struct PanelActions {
    var addShare: () -> Void = {}
    var removeShare: (String) -> Void = { _ in }
    var toggleLoginItem: () -> Void = {}
    var isLoginItem: () -> Bool = { false }
    var quit: () -> Void = {}
}

/// The menu bar panel: header strip (title row plus a toolbar with search and
/// add), status-grouped share list with expandable rows, and a footer with the
/// aggregate summary and controls.
struct PanelView: View {
    @ObservedObject var store: ShareStore
    var actions = PanelActions()

    /// Matches the panel width set in `PanelController`.
    private let width: CGFloat = 380
    /// Roughly eleven collapsed rows before the list starts scrolling.
    private let maxListHeight: CGFloat = 400

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            list
            Divider()
            footer
        }
        .frame(width: width)
    }

    // MARK: Header

    private var header: some View {
        let headline = store.headline
        return HStack {
            Text("SMB Keeper")
                .font(.headline)
            Spacer()
            HStack(spacing: 5) {
                Circle()
                    .fill(headline.healthy ? StateStyle.positive : StateStyle.negative)
                    .frame(width: 7, height: 7)
                Text(headline.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    // MARK: List

    @ViewBuilder
    private var list: some View {
        let shares = store.orderedShares
        if shares.isEmpty {
            placeholder
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        // One flat list, ordered worst first. With no sections a
                        // share's name is a stable identity on its own, so a row
                        // that changes state is updated in place instead of the
                        // list briefly holding two of it.
                        ForEach(shares, id: \.name) { share in
                            ShareRowView(store: store, share: share, actions: actions)
                                .id(share.name)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: maxListHeight)
                .scrollBounceBehavior(.basedOnSize)
                // No scrollbar. While the overlay scroller is revealed its live
                // hit strip reaches well in from the edge, over every row's
                // chevron, and a click there goes to the scroller instead of the
                // button: the "first click after opening does nothing" bug.
                // Trackpad and wheel scrolling are untouched.
                .scrollIndicators(.hidden)
                .onChange(of: store.scrollTarget) { _, target in
                    guard let target else { return }
                    proxy.scrollTo(target)
                    store.clearScrollTarget()
                }
            }
        }
    }

    private var placeholder: some View {
        let message = store.shares.isEmpty
            ? "No shares yet. Use + below to add one."
            : "Nothing to show"

        return Text(message)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 28)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Text(store.footerSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            footerButton("arrow.clockwise", help: "Check all now") { store.checkAll() }
            footerButton("doc.text", help: "Open log") { store.openLog() }
            footerButton("plus", help: "Add a share") { actions.addShare() }
            settingsMenu
        }
        .focusEffectDisabled()
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    /// Shared sizing so the footer glyphs read as one control group.
    private static let footerIconFont = Font.system(size: 13, weight: .regular)

    private func footerButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(Self.footerIconFont)
                .padding(2)
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    private var settingsMenu: some View {
        Menu {
            Button("Check all now") { store.checkAll() }
            Divider()
            Button(store.paused ? "Resume watching" : "Pause watching") {
                store.setPaused(!store.paused)
            }
            Button(actions.isLoginItem() ? "Don't start at login" : "Start at login") {
                actions.toggleLoginItem()
            }
            Divider()
            Button("Quit SMB Keeper") { actions.quit() }
        } label: {
            Image(systemName: "gearshape")
                .font(Self.footerIconFont)
                .padding(2)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Settings and actions")
    }
}
