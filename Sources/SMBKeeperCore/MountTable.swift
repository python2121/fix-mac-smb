import Foundation

/// The parsed form of an smbfs `f_mntfromname` such as `//user@fileserver._smb._tcp.local/Share`.
public struct SMBMountSource: Equatable {
    public let user: String?
    public let host: String
    public let share: String

    public init(user: String?, host: String, share: String) {
        self.user = user
        self.host = host
        self.share = share
    }

    /// Parse `//[user@]host/share`. Percent-encoding in the share is decoded.
    /// IPv6 hosts may appear as `[fe80::1]`; brackets are stripped.
    public static func parse(_ from: String) -> SMBMountSource? {
        guard from.hasPrefix("//") else { return nil }
        let body = from.dropFirst(2)
        guard let slash = body.firstIndex(of: "/") else { return nil }
        let authority = String(body[..<slash])
        var share = String(body[body.index(after: slash)...])
        if share.isEmpty { return nil }
        // Some servers export nested paths; keep only the first component as the share name.
        if let nested = share.firstIndex(of: "/") { share = String(share[..<nested]) }
        share = share.removingPercentEncoding ?? share

        var user: String?
        var host = authority
        if let at = authority.lastIndex(of: "@") {
            user = String(authority[..<at]).removingPercentEncoding
            host = String(authority[authority.index(after: at)...])
        }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.isEmpty { return nil }
        return SMBMountSource(user: user, host: host, share: share)
    }
}

/// One row of the kernel mount table.
public struct MountEntry: Equatable {
    public let fsType: String
    public let from: String
    public let on: String
    public let flags: UInt32
    public let owner: uid_t

    public var isSMB: Bool { fsType == "smbfs" }
    public var smbSource: SMBMountSource? { isSMB ? SMBMountSource.parse(from) : nil }

    public init(fsType: String, from: String, on: String, flags: UInt32, owner: uid_t) {
        self.fsType = fsType
        self.from = from
        self.on = on
        self.flags = flags
        self.owner = owner
    }

    /// Does this mount satisfy the share config? Match is by share name
    /// (case-insensitive). The host is deliberately not compared, because
    /// the same share may be mounted by Finder under a Bonjour name while the
    /// config uses an IP; either way it is the volume we want to keep alive.
    public func matches(_ share: ShareConfig) -> Bool {
        guard let src = smbSource else { return false }
        if src.share.caseInsensitiveCompare(share.share) != .orderedSame { return false }
        if let mp = share.mountPoint, mp != on { return false }
        return true
    }
}

public enum MountTable {
    /// Snapshot of all mounts using cached kernel data (`MNT_NOWAIT`). This never
    /// contacts a server, so it cannot hang on a dead mount.
    public static func snapshot() -> [MountEntry] {
        var count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { return [] }
        // Allow for mounts appearing between the two calls.
        count += 8
        var buf: [statfs] = .init(repeating: .init(), count: Int(count))
        let got = buf.withUnsafeMutableBufferPointer { p -> Int32 in
            getfsstat(p.baseAddress, Int32(p.count * MemoryLayout<statfs>.stride), MNT_NOWAIT)
        }
        guard got > 0 else { return [] }
        var result: [MountEntry] = []
        result.reserveCapacity(Int(got))
        for i in 0..<Int(got) {
            var s = buf[i]
            let type = withUnsafePointer(to: &s.f_fstypename) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
            }
            let from = withUnsafePointer(to: &s.f_mntfromname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            let on = withUnsafePointer(to: &s.f_mntonname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            result.append(MountEntry(fsType: type, from: from, on: on, flags: s.f_flags, owner: s.f_owner))
        }
        return result
    }

    public static func smbMounts() -> [MountEntry] { snapshot().filter { $0.isSMB } }

    /// True when `path` is itself a mount point (not merely inside one).
    public static func isMountPoint(_ path: String) -> Bool {
        snapshot().contains { $0.on == path }
    }
}
