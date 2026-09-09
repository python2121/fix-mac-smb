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
