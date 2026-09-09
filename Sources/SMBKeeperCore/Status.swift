import Foundation

/// Coarse state of one share, as shown in the panel.
public enum ShareState: String, Codable {
    /// Not evaluated yet.
    case unknown
    /// Mounted and answering.
    case healthy
    /// Mounted but probes hang or fail.
    case stale
    /// Not mounted: ejected on purpose, or waiting for a retry.
    case unmounted
    /// Server does not answer on port 445.
    case unreachable
    /// A mount is in progress.
    case mounting
    /// An unmount is in progress.
    case unmounting
    /// Last mount attempt failed; waiting out the backoff.
    case failed
    /// Disabled in config or paused by the user.
    case paused
}

public struct ShareStatus: Codable, Equatable {
    public var name: String
    public var server: String
    public var share: String
    public var state: ShareState
    public var detail: String
    public var mountPath: String?
    public var mountedFrom: String?
    public var lastProbeLatencyMs: Double?
    public var lastHealthyAt: Date?
    public var lastMountAt: Date?
    public var lastError: String?
    public var consecutiveFailures: Int
    public var nextAttemptAt: Date?
    public var updatedAt: Date

    public init(config: ShareConfig) {
        name = config.name
        server = config.server
        share = config.share
        state = config.enabled ? .unknown : .paused
        detail = config.enabled ? "not checked yet" : "disabled"
        consecutiveFailures = 0
        updatedAt = Date()
    }
}

public struct EngineStatus: Codable, Equatable {
    public var pid: Int32
    public var paused: Bool
    public var asleep: Bool
    public var startedAt: Date
    public var updatedAt: Date
    public var shares: [ShareStatus]

    public init(pid: Int32, paused: Bool, asleep: Bool, startedAt: Date, updatedAt: Date, shares: [ShareStatus]) {
        self.pid = pid
        self.paused = paused
        self.asleep = asleep
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.shares = shares
    }

    /// Reads the file the daemon writes. Returns nil when no daemon has run yet.
    public static func read(from path: String = Paths.statusFile) -> EngineStatus? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(EngineStatus.self, from: data)
    }

    public func write(to path: String = Paths.statusFile) throws {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(self)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// True when the daemon that wrote this status is still running.
    public var daemonAlive: Bool {
        kill(pid, 0) == 0
    }
}
