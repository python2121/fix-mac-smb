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
    /// Unmount a volume. With `force` false this is a single clean `umount`,
    /// which fails if any process has files open, exactly like Finder's eject.
    /// With `force` true it runs `umount -f` and then `diskutil unmount force`.
    /// Each step runs in a subprocess with its own deadline so a kernel that
    /// refuses to let go cannot take this process with it.
    ///
    /// `timeout` bounds the whole operation approximately; each step gets a
    /// share of it. Calls for one share are serialised by its controller, and
    /// force-unmount retries back off, so attempts never stack up.
    public static func unmount(path: String, force: Bool, timeout: Double, log: Log? = nil, tag: String? = nil) -> UnmountResult {
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
