import Foundation

/// One status section of the panel list.
public struct ShareGroup: Equatable {
    public let name: String
    public let shares: [ShareStatus]
    public init(name: String, shares: [ShareStatus]) {
        self.name = name
        self.shares = shares
    }
}

/// The view-model arithmetic behind the panel: which section a share belongs
/// to, what order sections appear in, what the search box matches, and the
/// footer line. Kept out of the SwiftUI layer so it can be tested directly.
public enum Presentation {
    /// Section heading for a state. Several states share a heading, because
    /// what the reader needs to know is "is this one fine, busy, or broken".
    public static func groupName(for state: ShareState) -> String {
        switch state {
        case .stale, .failed: return "Needs attention"
        case .mounting, .unmounting: return "Working"
        case .unreachable: return "Unreachable"
        case .unmounted: return "Not mounted"
        case .unknown: return "Checking"
        case .healthy: return "Healthy"
        case .paused: return "Paused"
        }
    }

    /// Sections are ordered worst first: a problem should never be below the
    /// fold while healthy shares take the top of the list.
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

    /// Free-text match over the share's name, its share name, and its server.
    public static func matches(_ share: ShareStatus, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return true }
        for field in [share.name, share.share, share.server] {
            if field.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil { return true }
        }
        return false
    }

    /// Group the shares into ordered sections, dropping anything the search
    /// filters out. Shares keep their configured order inside a section.
    public static func groups(_ shares: [ShareStatus], matching query: String = "") -> [ShareGroup] {
        let visible = shares.filter { matches($0, query: query) }
        var buckets: [String: [ShareStatus]] = [:]
        var order: [(name: String, rank: Int)] = []
        for share in visible {
            let name = groupName(for: share.state)
            if buckets[name] == nil {
                buckets[name] = []
                order.append((name, rank(share.state)))
            }
            buckets[name]?.append(share)
        }
        return order
            .sorted { $0.rank == $1.rank ? $0.name < $1.name : $0.rank < $1.rank }
            .map { ShareGroup(name: $0.name, shares: buckets[$0.name] ?? []) }
    }

    /// The shares as one flat list, worst first, with each share keeping its
    /// configured position among its equals. The same order the sections gave,
    /// without the headings.
    public static func ordered(_ shares: [ShareStatus], matching query: String = "") -> [ShareStatus] {
        groups(shares, matching: query).flatMap { $0.shares }
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
