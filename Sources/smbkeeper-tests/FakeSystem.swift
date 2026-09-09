import Foundation
import SMBKeeperCore

/// A scripted stand-in for the operating system. Tests set what the mount
/// table contains and what each call should answer, then inspect the calls the
/// engine made and in what order.
final class FakeSystem: SystemAdapter {
    private let lock = NSLock()

    var table: [MountEntry] = []
    var probeResults: [String: ProbeResult] = [:]      // keyed by mount path
    /// Ordered answers per path; each probe consumes one, the last one sticks.
    var probeQueue: [String: [ProbeResult]] = [:]
    var defaultProbe: ProbeResult = .healthy(latency: 0.002)
    var reachableHosts: Set<String> = []
    var unmountResult: UnmountResult = .unmounted
    var unmountRemovesEntry = true
    var mountResult: MountResult = .mounted(paths: [])
    var mountAddsEntry = true
    var clock = Date(timeIntervalSince1970: 1_700_000_000)
    var probeDelay: Double = 0
    var capacityByPath: [String: VolumeCapacity] = [:]

    private(set) var calls: [String] = []

    func entry(host: String = "nas.test", user: String = "tester", share: String, on: String? = nil) -> MountEntry {
        MountEntry(fsType: "smbfs", from: "//\(user)@\(host)/\(share)", on: on ?? "/Volumes/\(share)", flags: 0x18, owner: 501)
    }

    private func record(_ s: String) { lock.lock(); calls.append(s); lock.unlock() }

    func clearCalls() { lock.lock(); calls.removeAll(); lock.unlock() }

    func advance(_ seconds: Double) { lock.lock(); clock = clock.addingTimeInterval(seconds); lock.unlock() }

    // MARK: SystemAdapter

    func mountTable() -> [MountEntry] {
        lock.lock(); defer { lock.unlock() }
        return table
    }

    func probe(path: String, timeout: Double, listing: Bool) -> ProbeResult {
        record("probe \(path)")
        if probeDelay > 0 { Thread.sleep(forTimeInterval: probeDelay) }
        lock.lock(); defer { lock.unlock() }
        if var q = probeQueue[path], !q.isEmpty {
            let r = q.removeFirst()
            probeQueue[path] = q.isEmpty ? [r] : q
            return r
        }
        return probeResults[path] ?? defaultProbe
    }

    func reachable(host: String, timeout: Double) -> Bool {
        record("reach \(host)")
        lock.lock(); defer { lock.unlock() }
        return reachableHosts.contains(host)
    }

    func unmount(path: String, force: Bool, timeout: Double) -> UnmountResult {
        record("unmount\(force ? " -f" : "") \(path)")
        lock.lock(); defer { lock.unlock() }
        if case .unmounted = unmountResult, unmountRemovesEntry {
            table.removeAll { $0.on == path }
        }
        return unmountResult
    }

    func removeStaleMountDirectory(_ path: String) {
        record("rmdir \(path)")
    }

    func mount(url: URL, mountPoint: String?, timeout: Double) -> MountResult {
        record("mount \(url.absoluteString)")
        lock.lock(); defer { lock.unlock() }
        if case .mounted(let paths) = mountResult, mountAddsEntry {
            let share = (url.path as NSString).lastPathComponent
            let on = paths.first ?? mountPoint ?? "/Volumes/\(share)"
            table.append(MountEntry(fsType: "smbfs", from: "//\(url.user ?? "")@\(url.host ?? "")/\(share)", on: on, flags: 0x18, owner: 501))
            return .mounted(paths: [on])
        }
        return mountResult
    }

    func capacity(path: String, timeout: Double) -> VolumeCapacity? {
        record("capacity \(path)")
        lock.lock(); defer { lock.unlock() }
        return capacityByPath[path]
    }

    func now() -> Date { lock.lock(); defer { lock.unlock() }; return clock }
}
