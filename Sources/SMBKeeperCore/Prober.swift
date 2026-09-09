import Foundation

public enum ProbeResult: Equatable {
    /// The mount answered. `latency` is the wall time of the probe in seconds.
    case healthy(latency: Double)
    /// The probe did not return before the timeout; the mount is hung.
    case hung
    /// The probe returned an error. Typical values on a dead mount: ENXIO (6),
    /// EIO (5), ETIMEDOUT (60), ENOTCONN (57), ENOENT (2) if the path vanished.
    case failed(errno: Int32)

    public var isHealthy: Bool { if case .healthy = self { return true } else { return false } }

    public var description: String {
        switch self {
        case .healthy(let l): return String(format: "healthy (%.0f ms)", l * 1000)
        case .hung: return "hung (timed out)"
        case .failed(let e): return "failed: \(String(cString: strerror(e))) (\(e))"
        }
    }
}

/// How full a mounted volume is. Read from the same `statfs` the probe uses.
public struct VolumeCapacity: Equatable, Codable {
    public let totalBytes: UInt64
    public let freeBytes: UInt64

    public init(totalBytes: UInt64, freeBytes: UInt64) {
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
    }

    public var usedBytes: UInt64 { totalBytes > freeBytes ? totalBytes - freeBytes : 0 }

    /// 0-1, or nil when the server reports no size (some shares do).
    public var usedFraction: Double? {
        guard totalBytes > 0 else { return nil }
        return min(1, max(0, Double(usedBytes) / Double(totalBytes)))
    }
}

public enum Prober {
    /// Paths whose probe thread is still stuck inside the kernel.
    ///
    /// A syscall on a dead SMB mount cannot be interrupted, so a timed-out
    /// probe leaves its thread parked until the kernel finally gives up, which
    /// can take ten minutes. Starting a fresh probe every tick would pile up
    /// one parked thread per tick. While a probe is outstanding for a path, the
    /// answer is already known to be "hung", so no new thread is started.
    private static let lock = NSLock()
    private static var inFlight: [String: Date] = [:]

    public static func isProbeStuck(_ path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return inFlight[path] != nil
    }

    /// How long the outstanding probe for `path` has been stuck, if any.
    public static func stuckSince(_ path: String) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return inFlight[path]
    }

    /// Size and free space of a mounted volume, with a hard deadline.
    ///
    /// Called right after a healthy probe, so the mount has just proved it
    /// answers; the deadline is there for the case where it stops answering
    /// between the two calls.
    public static func capacity(path: String, timeout: Double) -> VolumeCapacity? {
        let result: VolumeCapacity?? = Deadline.run(seconds: timeout, name: "capacity") { () -> VolumeCapacity? in
            var st = statfs()
            guard statfs(path, &st) == 0, st.f_blocks > 0 else { return nil }
            let block = UInt64(st.f_bsize)
            return VolumeCapacity(totalBytes: UInt64(st.f_blocks) * block,
                                  freeBytes: UInt64(st.f_bavail) * block)
        }
        return result ?? nil
    }

    /// Probe a mounted volume with a hard deadline.
    ///
    /// `statfs` on an smbfs mount round-trips to the server for free-space
    /// information, which is exactly the kind of call that blocks when the
    /// session is dead. With `listing` on, a handful of directory entries are
    /// also read so the session and directory cache stay warm.
    public static func probe(path: String, timeout: Double, listing: Bool) -> ProbeResult {
        lock.lock()
        if inFlight[path] != nil {
            lock.unlock()
            return .hung
        }
        inFlight[path] = Date()
        lock.unlock()

        let sw = Stopwatch()
        let outcome: Int32? = Deadline.run(seconds: timeout, name: "probe") { () -> Int32 in
            defer {
                lock.lock(); inFlight.removeValue(forKey: path); lock.unlock()
            }
            var st = statfs()
            if statfs(path, &st) != 0 { return errno }
            if listing {
                guard let dir = opendir(path) else { return errno }
                defer { closedir(dir) }
                var seen = 0
                while seen < 8, readdir(dir) != nil { seen += 1 }
            }
            return 0
        }
        guard let code = outcome else { return .hung }
        if code == 0 { return .healthy(latency: sw.elapsed) }
        return .failed(errno: code)
    }
}
