import Foundation

/// The view-model arithmetic behind the panel: the order shares are listed
/// in, what the row's button offers, and the header line. Kept out of the
/// SwiftUI layer so it can be tested directly.
public enum Presentation {
    /// Shares are listed worst first: a problem should never be below the
    /// fold while healthy shares take the top of the list. States with the
    /// same rank are equally bad and keep their configured order.
    public static func rank(_ state: ShareState) -> Int {
        switch state {
        case .stale, .failed: return 0
        case .mounting, .unmounting: return 1
        case .unreachable: return 2
        case .unmounted: return 3
        case .unknown: return 4
        case .healthy: return 5
        case .paused: return 6
        }
    }

    /// The shares worst first, each keeping its configured position among
    /// its equals. A stable sort by rank.
    public static func ordered(_ shares: [ShareStatus]) -> [ShareStatus] {
        shares.enumerated()
            .sorted { a, b in
                let ra = rank(a.element.state), rb = rank(b.element.state)
                return ra == rb ? a.offset < b.offset : ra < rb
            }
            .map { $0.element }
    }

    /// Whether a share currently has a volume attached. `failed` is a mount
    /// attempt that did not happen, so it counts as not mounted; `stale` is a
    /// mount that is present but not answering, so it counts as mounted.
    public static func isMounted(_ state: ShareState) -> Bool {
        switch state {
        case .healthy, .stale, .unmounting: return true
        case .unmounted, .unreachable, .failed, .mounting, .unknown, .paused: return false
        }
    }

    /// What the row's one action button offers.
    public enum RowAction: Equatable {
        case mount
        case unmount
        /// Offered once an unmount has been asked for and the volume is still
        /// there, and for a mount that has stopped answering, which is the only
        /// kind that needs forcing.
        case forceUnmount
    }

    /// The button follows the volume, not the request: it offers to mount while
    /// nothing is attached, to unmount once something is, and escalates to force
    /// only while an unmount is outstanding or the mount has gone unresponsive.
    public static func rowAction(state: ShareState, unmountRequested: Bool) -> RowAction {
        guard isMounted(state) else { return .mount }
        if unmountRequested || state == .unmounting || state == .stale { return .forceUnmount }
        return .unmount
    }

    /// One-line state for the header: the dot's meaning.
    public static func headline(_ shares: [ShareStatus], paused: Bool) -> (text: String, healthy: Bool) {
        if paused { return ("Paused", false) }
        let watched = shares.filter { $0.state != .paused }
        if watched.isEmpty { return ("No shares", false) }
        if watched.contains(where: { $0.state == .stale || $0.state == .failed }) {
            return ("Needs attention", false)
        }
        if watched.contains(where: { $0.state == .unreachable }) { return ("Unreachable", false) }
        if watched.allSatisfy({ $0.state == .healthy }) { return ("All mounted", true) }
        if watched.contains(where: { $0.state == .mounting || $0.state == .unmounting }) {
            return ("Working", false)
        }
        return ("Checking", false)
    }
}
