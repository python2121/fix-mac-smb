import Foundation

public enum UnmountResult: Equatable {
    case unmounted
    /// The tools ran but the mount is still in the table.
    case stillMounted(detail: String)
    /// Every tool hung past its deadline. The mount may or may not be gone.
    case timedOut

    public var description: String {
        switch self {
        case .unmounted: return "unmounted"
        case .stillMounted(let d): return "still mounted: \(d)"
        case .timedOut: return "unmount timed out"
        }
    }
}

public enum Unmounter {
    /// Paths with an unmount still stuck in the kernel. A second `umount` for
    /// the same path would just be another process stuck in the same syscall,
    /// so callers get `.timedOut` straight back until the first one returns.
    private static let inFlightLock = NSLock()
    private static var inFlight = Set<String>()

    static func begin(_ path: String) -> Bool {
        inFlightLock.lock(); defer { inFlightLock.unlock() }
        if inFlight.contains(path) { return false }
        inFlight.insert(path)
        return true
    }

    static func end(_ path: String) {
        inFlightLock.lock(); inFlight.remove(path); inFlightLock.unlock()
    }

    public static func isInFlight(_ path: String) -> Bool {
        inFlightLock.lock(); defer { inFlightLock.unlock() }
        return inFlight.contains(path)
    }

    /// Unmount a volume. With `force` false this is a single clean `umount`,
    /// which fails if any process has files open, exactly like Finder's eject.
    /// With `force` true it runs `umount -f` and then `diskutil unmount force`.
    /// Each step runs in a subprocess with its own deadline so a kernel that
    /// refuses to let go cannot take this process with it.
    ///
    /// `timeout` bounds the whole operation approximately; each step gets a share of it.
    public static func unmount(path: String, force: Bool, timeout: Double, log: Log? = nil, tag: String? = nil) -> UnmountResult {
        guard begin(path) else {
            log?.debug(tag, "an earlier unmount of \(path) is still stuck in the kernel; not starting another")
            return MountTable.isMountPoint(path) ? .timedOut : .unmounted
        }
        // The subprocess may outlive our deadline; release the slot only when
        // it has really exited, on a background thread.
        let release = DispatchSemaphore(value: 0)
        let thread = Thread { release.wait(); end(path) }
        thread.name = "unmount-slot"
        thread.start()
        defer { release.signal() }
        var steps: [(String, [String])] = []
        if force {
            steps.append(("/sbin/umount", ["-f", path]))
            steps.append(("/usr/sbin/diskutil", ["unmount", "force", path]))
        } else {
            steps.append(("/sbin/umount", [path]))
        }

        let perStep = max(3, timeout / Double(steps.count))
        var lastDetail = ""
        var anyTimedOut = false
        for (tool, args) in steps {
            if !MountTable.isMountPoint(path) { return .unmounted }
            let r = Subprocess.run(tool, args, timeout: perStep)
            let detail = (r.stderr + r.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
            log?.debug(tag, "\(tool) \(args.joined(separator: " ")) -> status=\(r.status.map(String.init) ?? "nil") timedOut=\(r.timedOut) \(detail)")
            if r.timedOut { anyTimedOut = true }
            if !MountTable.isMountPoint(path) { return .unmounted }
            lastDetail = detail.isEmpty ? "\(tool) exit \(r.status.map(String.init) ?? "?")" : detail
        }
        if !MountTable.isMountPoint(path) { return .unmounted }
        return anyTimedOut ? .timedOut : .stillMounted(detail: lastDetail)
    }

    /// After a successful unmount NetFS may find an empty leftover directory at the
    /// mount point and mount the share at `<name>-1` instead. Remove such a
    /// directory when it is empty and not a mount point. Errors are ignored.
    public static func removeStaleMountDirectory(_ path: String) {
        guard path.hasPrefix("/Volumes/") else { return }
        if MountTable.isMountPoint(path) { return }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return }
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: path), entries.isEmpty else { return }
        _ = rmdir(path)
    }
}
