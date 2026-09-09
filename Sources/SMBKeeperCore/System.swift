import Foundation

/// Everything the engine does to the outside world goes through this
/// protocol, so the decision logic can be exercised against a scripted fake.
public protocol SystemAdapter: AnyObject {
    func mountTable() -> [MountEntry]
    func probe(path: String, timeout: Double, listing: Bool) -> ProbeResult
    func reachable(host: String, timeout: Double) -> Bool
    func unmount(path: String, force: Bool, timeout: Double) -> UnmountResult
    func removeStaleMountDirectory(_ path: String)
    func mount(url: URL, mountPoint: String?, timeout: Double) -> MountResult
    /// Size and free space of a mounted volume. Declared here, not only in the
    /// extension below: a requirement that lives solely in an extension is
    /// statically dispatched through the existential, so the default would
    /// shadow every implementation.
    func capacity(path: String, timeout: Double) -> VolumeCapacity?
    func now() -> Date
}

public extension SystemAdapter {
    /// Adapters that cannot report capacity return nil and the panel simply
    /// omits the figure.
    func capacity(path: String, timeout: Double) -> VolumeCapacity? { nil }
}

/// The real thing.
public final class LiveSystem: SystemAdapter {
    let log: Log
    public init(log: Log) { self.log = log }

    public func mountTable() -> [MountEntry] { MountTable.snapshot() }

    public func probe(path: String, timeout: Double, listing: Bool) -> ProbeResult {
        Prober.probe(path: path, timeout: timeout, listing: listing)
    }

    private var warnedPolicy = false

    /// The mount gate. A completed TCP handshake is the normal "yes". When the
    /// system refuses to let this process open sockets at all (Local Network
    /// privacy), fall back to ping, and if even that is inconclusive, let the
    /// mount attempt go ahead: NetFS works through the kernel and is not
    /// subject to the gate, and a failed mount costs only a backoff.
    public func reachable(host: String, timeout: Double) -> Bool {
        switch Reachability.tcpProbe(host: host, port: 445, timeout: timeout) {
        case .reachable:
            return true
        case .unreachable:
            return false
        case .blockedByPolicy(let why):
            if Reachability.ping(host: host, timeout: min(timeout, 3)) {
                log.debug("reach", "TCP check to \(host) blocked (\(why)); ping answered")
                return true
            }
            if !warnedPolicy {
                warnedPolicy = true
                log.warn("reach", "TCP check to \(host) blocked by the system (\(why)) and ping did not answer. If SMB Keeper is not allowed under System Settings > Privacy & Security > Local Network, allow it. Proceeding with mount attempts regardless.")
            }
            return true
        }
    }

    public func unmount(path: String, force: Bool, timeout: Double) -> UnmountResult {
        Unmounter.unmount(path: path, force: force, timeout: timeout, log: log, tag: "unmount")
    }

    public func removeStaleMountDirectory(_ path: String) {
        Unmounter.removeStaleMountDirectory(path)
    }

    public func mount(url: URL, mountPoint: String?, timeout: Double) -> MountResult {
        Mounter.mount(url: url, mountPoint: mountPoint, allowUI: false, timeout: timeout)
    }

    public func capacity(path: String, timeout: Double) -> VolumeCapacity? {
        Prober.capacity(path: path, timeout: timeout)
    }

    public func now() -> Date { Date() }
}
