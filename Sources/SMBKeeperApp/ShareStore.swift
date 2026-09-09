import AppKit
import Combine
import SwiftUI
import SMBKeeperCore

/// What the panel observes: the engine's status, plus the view state that
/// belongs to the panel itself (search text, selection, which rows are open).
///
/// The engine reports from arbitrary queues, so every published change is
/// hopped to the main actor here and nowhere else.
@MainActor
final class ShareStore: ObservableObject {
    @Published private(set) var shares: [ShareStatus] = []
    @Published private(set) var paused = false
    @Published var selectedName: String?
    @Published var expandedNames: Set<String> = []
    /// Set when keyboard navigation lands on a row that may be scrolled away.
    @Published private(set) var scrollTarget: String?

    private let engine: Engine

    init(engine: Engine) {
        self.engine = engine
        refresh()
        engine.onStatusChange = { [weak self] status in
            Task { @MainActor in self?.apply(status) }
        }
    }

    private func apply(_ status: EngineStatus) {
        shares = status.shares
        paused = status.paused
        let live = Set(status.shares.map { $0.name })
        expandedNames.formIntersection(live)
        if let selected = selectedName, !live.contains(selected) { selectedName = nil }
    }

    func refresh() { apply(engine.status) }

    // MARK: Derived

    /// Worst first, as one flat list.
    var orderedShares: [ShareStatus] { Presentation.ordered(shares) }
    var footerSummary: String { Presentation.footerSummary(shares) }
    var headline: (text: String, healthy: Bool) { Presentation.headline(shares, paused: paused) }

    /// Every visible row, top to bottom, for keyboard navigation.
    var visualOrder: [String] { orderedShares.map { $0.name } }

    func share(named name: String) -> ShareStatus? { shares.first { $0.name == name } }

    func config(for name: String) -> ShareConfig? { engine.config.share(named: name) }

    // MARK: View state

    func select(_ name: String) {
        selectedName = selectedName == name ? nil : name
    }

    func toggleExpanded(_ name: String) {
        if expandedNames.contains(name) { expandedNames.remove(name) } else { expandedNames.insert(name) }
    }

    /// Move the highlight one row down (+1) or up (-1).
    func moveSelection(_ direction: Int) {
        let order = visualOrder
        guard !order.isEmpty else { return }
        guard let current = selectedName, let index = order.firstIndex(of: current) else {
            selectedName = direction > 0 ? order.first : order.last
            scrollTarget = selectedName
            return
        }
        let next = index + direction
        guard next >= 0, next < order.count else { return }
        selectedName = order[next]
        scrollTarget = selectedName
    }

    /// Open (true) or close (false) the highlighted row. Returns whether there
    /// was anything to act on, so the caller can hand the key back.
    func setExpanded(_ expanded: Bool) -> Bool {
        guard let name = selectedName else { return false }
        if expanded {
            if expandedNames.contains(name) { return false }
            expandedNames.insert(name)
        } else {
            if !expandedNames.contains(name) { return false }
            expandedNames.remove(name)
        }
        return true
    }

    func clearScrollTarget() { scrollTarget = nil }
    func clearSelection() { selectedName = nil }

    /// Escape peels back one layer per press: the highlight, then the panel.
    enum EscapeAction { case clearSelection, close }

    func escapeAction() -> EscapeAction {
        selectedName != nil ? .clearSelection : .close
    }

    // MARK: Engine actions

    /// Explicit "check all now": also lifts a hold, because the user asked.
    func checkAll() {
        for c in engine.shareControllers {
            c.resetBackoff(reason: "panel")
            c.releaseHold(reason: "panel check")
            c.schedule(after: 0, reason: "panel check")
        }
    }

    /// Opening the panel refreshes what it shows, but must not undo a share the
    /// user deliberately ejected, so holds are left in place here.
    func refreshOnOpen() {
        refresh()
        for c in engine.shareControllers { c.schedule(after: 0, reason: "panel opened") }
    }

    func mount(_ name: String) { engine.controller(named: name)?.requestMount() }
    func unmount(_ name: String) { engine.controller(named: name)?.requestUnmount(force: false) }
    func forceUnmount(_ name: String) { engine.controller(named: name)?.requestUnmount(force: true) }

    func setPaused(_ value: Bool) { engine.setPaused(value) }

    func setEjectOnSleep(_ name: String, _ value: Bool) {
        engine.setEjectOnSleep(share: name, value)
        refresh()
    }

    func removeShare(_ name: String) throws {
        try engine.removeShare(named: name)
        refresh()
    }

    func canReveal(_ name: String) -> Bool {
        guard let share = share(named: name) else { return false }
        return share.state == .healthy && share.mountPath != nil
    }

    func reveal(_ name: String) {
        guard let path = share(named: name)?.mountPath else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func openLog() { NSWorkspace.shared.open(URL(fileURLWithPath: Paths.logFile)) }
}
