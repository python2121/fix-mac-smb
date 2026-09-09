import Foundation

/// One network share to keep alive.
public struct ShareConfig: Codable, Equatable {
    /// Short identifier used on the command line and in the menu. Defaults to `share`.
    public var name: String
    /// Host to mount from: an IP address (recommended), a DNS name, or a Bonjour
    /// service instance such as `fileserver._smb._tcp.local`.
    public var server: String
    /// Share name on the server, as shown by `smbutil view`.
    public var share: String
    /// Account name embedded in the mount URL. Optional; when nil, NetAuthAgent
    /// picks the keychain entry for the server.
    public var user: String?
    /// Explicit mount point. When nil, macOS chooses `/Volumes/<share>`.
    public var mountPoint: String?
    /// When false the share is ignored entirely.
    public var enabled: Bool
    /// Cleanly unmount this share when the Mac is about to sleep, so no zombie
    /// mount exists on wake. Costs open file handles across sleep.
    public var ejectOnSleep: Bool

    public init(name: String? = nil, server: String, share: String, user: String? = nil,
                mountPoint: String? = nil, enabled: Bool = true, ejectOnSleep: Bool = false) {
        self.name = name ?? share
        self.server = server
        self.share = share
        self.user = user
        self.mountPoint = mountPoint
        self.enabled = enabled
        self.ejectOnSleep = ejectOnSleep
    }

    enum CodingKeys: String, CodingKey { case name, server, share, user, mountPoint, enabled, ejectOnSleep }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let share = try c.decode(String.self, forKey: .share)
        self.share = share
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? share
        self.server = try c.decode(String.self, forKey: .server)
        self.user = try c.decodeIfPresent(String.self, forKey: .user)
        self.mountPoint = try c.decodeIfPresent(String.self, forKey: .mountPoint)
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.ejectOnSleep = try c.decodeIfPresent(Bool.self, forKey: .ejectOnSleep) ?? false
    }

    /// The `smb://` URL NetFS will mount.
    public var url: URL? {
        var comps = URLComponents()
        comps.scheme = "smb"
        comps.host = server
        if let user = user, !user.isEmpty { comps.user = user }
        comps.path = "/" + share
        return comps.url
    }

    /// Where the volume is expected to appear when mounted.
    public var expectedMountPoint: String {
        mountPoint ?? "/Volumes/" + share
    }
}

/// Tunables for the engine. Every value has a default so a config file only needs
/// to mention what it changes.
public struct Settings: Codable, Equatable {
    /// Seconds between periodic health checks. Each check is also a keepalive touch.
    public var tickSeconds: Double
    /// How long a filesystem probe may block before the mount is declared hung.
    /// A session that is merely reconnecting can take several seconds to answer,
    /// so this is deliberately longer than a healthy round trip.
    public var probeTimeoutSeconds: Double
    /// How long a mount may stay hung before it is force-unmounted (recover mode).
    ///
    /// Deliberately patient. The kernel gives a dead session up to 600 s
    /// (`net.smb.fs.kern_hard_deadtimer`) before it force-unmounts the volume
    /// itself, and that path works while `umount -f` from user space often
    /// blocks. Acting too early interrupts a reconnect that would have
    /// succeeded, so the default sits between the soft (60 s) and hard (600 s)
    /// timers and lets the kernel try first.
    public var staleGraceSeconds: Double
    /// Delay after the daemon starts before the first check, so Finder's own
    /// login-item mounts finish first.
    public var settleAfterStartupSeconds: Double
    /// Delay after a wake notification before the first check, so Wi-Fi can come up.
    public var settleAfterWakeSeconds: Double
    /// Delay after a network change before checking.
    public var settleAfterNetworkSeconds: Double
    /// TCP connect timeout for the port 445 reachability gate.
    public var reachabilityTimeoutSeconds: Double
    /// Retry interval while the server is unreachable.
    public var unreachableRetrySeconds: Double
    /// Maximum time to wait for NetFS to complete a mount.
    public var mountTimeoutSeconds: Double
    /// Maximum time to wait for umount / diskutil.
    public var unmountTimeoutSeconds: Double
    /// After this many force-unmount attempts that do not free the mount, stop
    /// retrying quickly and report that a restart is probably needed.
    public var maxForceUnmountAttempts: Int
    /// Exponential backoff after failed mounts: first delay, cap, and multiplier.
    public var backoffMinSeconds: Double
    public var backoffMaxSeconds: Double
    public var backoffMultiplier: Double
    /// Read a few directory entries on every healthy probe to keep the session warm.
    public var keepaliveListing: Bool
    /// Log level: debug, info, warn, error.
    public var logLevel: String

    public static let defaults = Settings(
        tickSeconds: 60, probeTimeoutSeconds: 15, staleGraceSeconds: 240,
        settleAfterStartupSeconds: 10, settleAfterWakeSeconds: 4, settleAfterNetworkSeconds: 3, reachabilityTimeoutSeconds: 3,
        unreachableRetrySeconds: 20, mountTimeoutSeconds: 45, unmountTimeoutSeconds: 20,
        maxForceUnmountAttempts: 5,
        backoffMinSeconds: 5, backoffMaxSeconds: 300, backoffMultiplier: 2, keepaliveListing: true,
        logLevel: "info")

    public init(tickSeconds: Double, probeTimeoutSeconds: Double, staleGraceSeconds: Double,
                settleAfterStartupSeconds: Double, settleAfterWakeSeconds: Double, settleAfterNetworkSeconds: Double,
                reachabilityTimeoutSeconds: Double, unreachableRetrySeconds: Double,
                mountTimeoutSeconds: Double, unmountTimeoutSeconds: Double, maxForceUnmountAttempts: Int,
                backoffMinSeconds: Double, backoffMaxSeconds: Double, backoffMultiplier: Double,
                keepaliveListing: Bool, logLevel: String) {
        self.tickSeconds = tickSeconds
        self.probeTimeoutSeconds = probeTimeoutSeconds
        self.staleGraceSeconds = staleGraceSeconds
        self.settleAfterStartupSeconds = settleAfterStartupSeconds
        self.settleAfterWakeSeconds = settleAfterWakeSeconds
        self.settleAfterNetworkSeconds = settleAfterNetworkSeconds
        self.reachabilityTimeoutSeconds = reachabilityTimeoutSeconds
        self.unreachableRetrySeconds = unreachableRetrySeconds
        self.mountTimeoutSeconds = mountTimeoutSeconds
        self.unmountTimeoutSeconds = unmountTimeoutSeconds
        self.maxForceUnmountAttempts = maxForceUnmountAttempts
        self.backoffMinSeconds = backoffMinSeconds
        self.backoffMaxSeconds = backoffMaxSeconds
        self.backoffMultiplier = backoffMultiplier
        self.keepaliveListing = keepaliveListing
        self.logLevel = logLevel
    }

    enum CodingKeys: String, CodingKey {
        case tickSeconds, probeTimeoutSeconds, staleGraceSeconds, settleAfterStartupSeconds, settleAfterWakeSeconds,
             settleAfterNetworkSeconds, reachabilityTimeoutSeconds, unreachableRetrySeconds,
             mountTimeoutSeconds, unmountTimeoutSeconds, maxForceUnmountAttempts, backoffMinSeconds, backoffMaxSeconds,
             backoffMultiplier, keepaliveListing, logLevel
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings.defaults
        tickSeconds = try c.decodeIfPresent(Double.self, forKey: .tickSeconds) ?? d.tickSeconds
        probeTimeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .probeTimeoutSeconds) ?? d.probeTimeoutSeconds
        staleGraceSeconds = try c.decodeIfPresent(Double.self, forKey: .staleGraceSeconds) ?? d.staleGraceSeconds
        settleAfterStartupSeconds = try c.decodeIfPresent(Double.self, forKey: .settleAfterStartupSeconds) ?? d.settleAfterStartupSeconds
        settleAfterWakeSeconds = try c.decodeIfPresent(Double.self, forKey: .settleAfterWakeSeconds) ?? d.settleAfterWakeSeconds
        settleAfterNetworkSeconds = try c.decodeIfPresent(Double.self, forKey: .settleAfterNetworkSeconds) ?? d.settleAfterNetworkSeconds
        reachabilityTimeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .reachabilityTimeoutSeconds) ?? d.reachabilityTimeoutSeconds
        unreachableRetrySeconds = try c.decodeIfPresent(Double.self, forKey: .unreachableRetrySeconds) ?? d.unreachableRetrySeconds
        mountTimeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .mountTimeoutSeconds) ?? d.mountTimeoutSeconds
        unmountTimeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .unmountTimeoutSeconds) ?? d.unmountTimeoutSeconds
        maxForceUnmountAttempts = try c.decodeIfPresent(Int.self, forKey: .maxForceUnmountAttempts) ?? d.maxForceUnmountAttempts
        backoffMinSeconds = try c.decodeIfPresent(Double.self, forKey: .backoffMinSeconds) ?? d.backoffMinSeconds
        backoffMaxSeconds = try c.decodeIfPresent(Double.self, forKey: .backoffMaxSeconds) ?? d.backoffMaxSeconds
        backoffMultiplier = try c.decodeIfPresent(Double.self, forKey: .backoffMultiplier) ?? d.backoffMultiplier
        keepaliveListing = try c.decodeIfPresent(Bool.self, forKey: .keepaliveListing) ?? d.keepaliveListing
        logLevel = try c.decodeIfPresent(String.self, forKey: .logLevel) ?? d.logLevel
    }

    /// Delay before the next mount attempt after `failures` consecutive failures (>= 1).
    public func backoff(afterFailures failures: Int) -> Double {
        guard failures > 0 else { return 0 }
        let exponent = Double(max(0, failures - 1))
        let raw = backoffMinSeconds * pow(max(1, backoffMultiplier), exponent)
        return min(backoffMaxSeconds, raw)
    }
}

/// Top-level configuration file.
public struct Config: Codable, Equatable {
    public var settings: Settings
    public var shares: [ShareConfig]

    public init(settings: Settings = .defaults, shares: [ShareConfig] = []) {
        self.settings = settings
        self.shares = shares
    }

    enum CodingKeys: String, CodingKey { case settings, shares }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        settings = try c.decodeIfPresent(Settings.self, forKey: .settings) ?? .defaults
        shares = try c.decodeIfPresent([ShareConfig].self, forKey: .shares) ?? []
    }

    public func share(named name: String) -> ShareConfig? {
        shares.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Reject configurations the engine cannot act on safely.
    public func validate() throws {
        var seen = Set<String>()
        for s in shares {
            if s.share.isEmpty { throw ConfigError.invalid("share name is empty for '\(s.name)'") }
            if s.server.isEmpty { throw ConfigError.invalid("server is empty for '\(s.name)'") }
            if s.share.contains("/") { throw ConfigError.invalid("share '\(s.share)' must not contain '/'") }
            if let mp = s.mountPoint, !mp.hasPrefix("/") { throw ConfigError.invalid("mountPoint for '\(s.name)' must be absolute") }
            if s.url == nil { throw ConfigError.invalid("cannot build a URL for '\(s.name)'") }
            let key = s.name.lowercased()
            if seen.contains(key) { throw ConfigError.invalid("duplicate share name '\(s.name)'") }
            seen.insert(key)
        }
        if settings.tickSeconds < 5 { throw ConfigError.invalid("tickSeconds must be >= 5") }
        if settings.probeTimeoutSeconds < 1 { throw ConfigError.invalid("probeTimeoutSeconds must be >= 1") }
        if settings.mountTimeoutSeconds < 5 { throw ConfigError.invalid("mountTimeoutSeconds must be >= 5") }
        if settings.backoffMinSeconds <= 0 || settings.backoffMaxSeconds < settings.backoffMinSeconds {
            throw ConfigError.invalid("backoff range is invalid")
        }
    }

    // MARK: Persistence

    public static func load(from path: String = Paths.configFile) throws -> Config {
        guard FileManager.default.fileExists(atPath: path) else { throw ConfigError.missing(path) }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let decoder = JSONDecoder()
        let config: Config
        do {
            config = try decoder.decode(Config.self, from: data)
        } catch {
            throw ConfigError.invalid("\(path): \(error.localizedDescription)")
        }
        try config.validate()
        return config
    }

    /// Load the config, or return an empty one if none exists yet.
    public static func loadOrEmpty(from path: String = Paths.configFile) throws -> Config {
        do { return try load(from: path) } catch ConfigError.missing { return Config() }
    }

    public func save(to path: String = Paths.configFile) throws {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

public enum ConfigError: Error, CustomStringConvertible {
    case missing(String)
    case invalid(String)

    public var description: String {
        switch self {
        case .missing(let p): return "no configuration at \(p) (run `smbkeeper add` first)"
        case .invalid(let m): return "invalid configuration: \(m)"
        }
    }
}
