import Foundation
import Network

/// Reports when the network path changes in a way that matters for a mount:
/// connectivity gained or lost, or a different set of interfaces in use.
public final class NetworkMonitor {
    public struct Snapshot: Equatable {
        public let satisfied: Bool
        public let interfaces: [String]
        public let description: String
    }

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: Paths.bundleID + ".network")
    private let handler: (Snapshot, Snapshot?) -> Void
    private var last: Snapshot?

    /// `handler(new, previous)`; `previous` is nil for the first report.
    public init(handler: @escaping (Snapshot, Snapshot?) -> Void) {
        self.handler = handler
    }

    public func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            let names = Array(Set(path.availableInterfaces.map { "\($0.name)(\(NetworkMonitor.kind($0.type)))" })).sorted()
            let snap = Snapshot(
                satisfied: path.status == .satisfied,
                interfaces: names,
                description: "\(path.status == .satisfied ? "up" : "down") via \(names.joined(separator: ","))"
            )
            let prev = self.last
            if prev == snap { return }
            self.last = snap
            self.handler(snap, prev)
        }
        monitor.start(queue: queue)
    }

    public func stop() { monitor.cancel() }

    static func kind(_ t: NWInterface.InterfaceType) -> String {
        switch t {
        case .wifi: return "wifi"
        case .wiredEthernet: return "wired"
        case .cellular: return "cell"
        case .loopback: return "lo"
        case .other: return "other"
        @unknown default: return "?"
        }
    }
}
