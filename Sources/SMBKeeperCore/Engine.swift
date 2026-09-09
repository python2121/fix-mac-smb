import Foundation

/// Owns the share controllers and wires them to the triggers: a periodic tick,
/// sleep/wake, network path changes, and kernel mount-table changes. One engine
/// runs per user session, inside the menu bar app.
public final class Engine {
    public private(set) var config: Config
    public let log: Log
    private let system: SystemAdapter
    private let configPath: String
    private let statusPath: String

    private let lock = NSLock()
    private var controllers: [ShareController] = []
    private var pausedFlag = false
    private var asleepFlag = false
    private var sleptAt: Date?
    private let startedAt = Date()

    private let timerQueue = DispatchQueue(label: Paths.bundleID + ".engine")
    private var tick: DispatchSourceTimer?
    private var power: PowerMonitor?
    private var network: NetworkMonitor?
    private var vfsMount: DarwinNotification?
    private var vfsUnmount: DarwinNotification?
    private var statusWrite: DispatchWorkItem?
    private var running = false

    /// Called after any status change, on an arbitrary queue.
    public var onStatusChange: ((EngineStatus) -> Void)?

    public init(config: Config, log: Log, system: SystemAdapter? = nil,
                configPath: String = Paths.configFile, statusPath: String = Paths.statusFile) {
        self.config = config
        self.log = log
        self.system = system ?? LiveSystem(log: log)
        self.configPath = configPath
        self.statusPath = statusPath
        rebuildControllers()
    }

    // MARK: Accessors

    public var paused: Bool { lock.withLock { pausedFlag } }
    public var asleep: Bool { lock.withLock { asleepFlag } }

    public var shareControllers: [ShareController] { lock.withLock { controllers } }

    public func controller(named name: String) -> ShareController? {
        shareControllers.first { $0.config.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    public var status: EngineStatus {
        let cs = shareControllers
        return EngineStatus(pid: getpid(), paused: paused, asleep: asleep,
                            startedAt: startedAt, updatedAt: Date(), shares: cs.map { $0.currentStatus })
    }

    // MARK: Lifecycle

    public func start() {
        lock.withLock { running = true }
        log.info("engine", "starting: shares=\(shareControllers.map { $0.config.name }.joined(separator: ","))")

        let t = DispatchSource.makeTimerSource(queue: timerQueue)
        let interval = config.settings.tickSeconds
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(2))
        t.setEventHandler { [weak self] in self?.onTick() }
        t.resume()
        tick = t

        let pm = PowerMonitor(log: log) { [weak self] ev in self?.onPower(ev) }
        pm.start()
        power = pm

        let nm = NetworkMonitor { [weak self] snap, prev in self?.onNetwork(snap, prev) }
        nm.start()
        network = nm

        vfsMount = DarwinNotification(name: DarwinNotification.vfsMount, queue: timerQueue) { [weak self] in
            self?.log.debug("engine", "kernel: mount table changed (mount)")
            self?.scheduleAll(after: 1.5, reason: "mount table changed")
        }
        vfsUnmount = DarwinNotification(name: DarwinNotification.vfsUnmount, queue: timerQueue) { [weak self] in
            self?.log.debug("engine", "kernel: mount table changed (unmount)")
            self?.scheduleAll(after: 1.5, reason: "mount table changed")
        }
        // Give Finder's own login-item mounts a head start so we never race
        // them into a duplicate "<share>-1" mount.
        scheduleAll(after: config.settings.settleAfterStartupSeconds, reason: "startup")
        writeStatusSoon()
    }

    public func stop() {
        lock.withLock { running = false }
        tick?.cancel(); tick = nil
        power?.stop(); power = nil
        network?.stop(); network = nil
        vfsMount = nil; vfsUnmount = nil
        log.info("engine", "stopped")
    }

    // MARK: Controllers

    /// Build the controller list for the current configuration, keeping the
    /// existing controller for any share whose settings did not change. That
    /// preserves what each one has learned, in particular whether it has ever
    /// seen its mount answer, so editing one share cannot reset another.
    private func rebuildControllers() {
        let settings = config.settings
        let (previous, isPaused) = lock.withLock { (controllers, pausedFlag) }
        var reused: [ObjectIdentifier] = []
        let new = config.shares.map { share -> ShareController in
            if let keep = previous.first(where: { $0.config == share && $0.isActive }) {
                keep.updateSettings(settings)
                reused.append(ObjectIdentifier(keep))
                return keep
            }
            let c = ShareController(config: share, settings: settings, system: system, log: log)
            c.onChange = { [weak self] _ in self?.writeStatusSoon() }
            if isPaused { c.paused = true }
            return c
        }
        lock.withLock { controllers = new }
        for old in previous where !reused.contains(ObjectIdentifier(old)) {
            old.deactivate()
        }
    }

    // MARK: Editing shares

    public enum ShareEditError: Error, CustomStringConvertible {
        case duplicateName(String)
        case duplicateShare(name: String, server: String, share: String)
        case notFound(String)
        case invalid(String)

        public var description: String {
            switch self {
            case .duplicateName(let n): return "a share named '\(n)' is already being monitored"
            case .duplicateShare(let n, let server, let share):
                return "'\(n)' already monitors \(share) on \(server)"
            case .notFound(let n): return "no share named '\(n)'"
            case .invalid(let m): return m
            }
        }
    }

    /// Add a share to the monitored set and save the configuration.
    public func addShare(_ share: ShareConfig) throws {
        var next = lock.withLock { config }
        if next.shares.contains(where: { $0.name.caseInsensitiveCompare(share.name) == .orderedSame }) {
            throw ShareEditError.duplicateName(share.name)
        }
        if let clash = next.shares.first(where: {
            $0.server.caseInsensitiveCompare(share.server) == .orderedSame &&
            $0.share.caseInsensitiveCompare(share.share) == .orderedSame
        }) {
            throw ShareEditError.duplicateShare(name: clash.name, server: share.server, share: share.share)
        }
        next.shares.append(share)
        do {
            try next.validate()
        } catch {
            throw ShareEditError.invalid("\(error)")
        }
        log.info("engine", "adding share \(share.name): smb://\(share.user.map { "\($0)@" } ?? "")\(share.server)/\(share.share)")
        apply(config: next, persist: true)
    }

    /// Stop monitoring a share and save the configuration. The volume itself
    /// is left exactly as it is, mounted or not.
    @discardableResult
    public func removeShare(named name: String) throws -> ShareConfig {
        var next = lock.withLock { config }
        guard let idx = next.shares.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw ShareEditError.notFound(name)
        }
        let removed = next.shares.remove(at: idx)
        log.info("engine", "no longer monitoring \(removed.name); leaving the volume as it is")
        apply(config: next, persist: true)
        return removed
    }

    /// Re-read the configuration file. Shares that changed get fresh controllers.
    public func reload() {
        do {
            let fresh = try Config.load(from: configPath)
            apply(config: fresh)
            log.info("engine", "configuration reloaded (\(fresh.shares.count) shares)")
        } catch {
            log.error("engine", "reload failed: \(error)")
        }
    }

    /// Replace the configuration in memory (and on disk when `persist`).
    public func apply(config new: Config, persist: Bool = false) {
        let old = lock.withLock { config }
        lock.withLock { config = new }
        if persist {
            do { try new.save(to: configPath) } catch { log.error("engine", "could not save config: \(error)") }
        }
        if old.shares != new.shares {
            rebuildControllers()
            if lock.withLock({ running }) { scheduleAll(after: 0, reason: "config changed") }
        } else {
            for c in shareControllers { c.updateSettings(new.settings) }
        }
        if old.settings.tickSeconds != new.settings.tickSeconds, let t = tick {
            let i = new.settings.tickSeconds
            t.schedule(deadline: .now() + i, repeating: i, leeway: .seconds(2))
        }
        writeStatusSoon()
    }

    public func setEjectOnSleep(share name: String, _ value: Bool) {
        var c = lock.withLock { config }
        guard let idx = c.shares.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { return }
        c.shares[idx].ejectOnSleep = value
        apply(config: c, persist: true)
    }

    public func setPaused(_ p: Bool) {
        lock.withLock { pausedFlag = p }
        log.info("engine", p ? "paused" : "resumed")
        for c in shareControllers { c.paused = p }
        writeStatusSoon()
    }

    // MARK: Triggers

    public func scheduleAll(after: Double, reason: String) {
        for c in shareControllers { c.schedule(after: after, reason: reason) }
    }

    /// Whether a "we are asleep" flag should be discarded when a tick fires.
    ///
    /// The timer firing at all is evidence the CPU is running. Wake
    /// notifications are known to be missed on some hardware, and a stuck flag
    /// would silently stop every check for as long as the machine stayed up,
    /// so the flag is only trusted briefly.
    public static func sleepFlagIsStale(sleptAt: Date?, now: Date, tickSeconds: Double, secondsSinceUserInput: Double) -> Bool {
        if secondsSinceUserInput < 60 { return true }
        guard let sleptAt = sleptAt else { return true }
        return now.timeIntervalSince(sleptAt) > max(120, tickSeconds * 2)
    }

    private func onTick() {
        if asleep {
            let slept = lock.withLock { sleptAt }
            if Engine.sleepFlagIsStale(sleptAt: slept, now: Date(), tickSeconds: config.settings.tickSeconds,
                                       secondsSinceUserInput: PowerMonitor.secondsSinceUserInput()) {
                log.warn("engine", "a tick fired while flagged asleep, so the wake notification was missed; resuming checks")
                lock.withLock { asleepFlag = false; sleptAt = nil }
                for c in shareControllers { c.resetBackoff(reason: "missed wake"); c.releaseHold(reason: "missed wake") }
            } else {
                log.debug("engine", "tick skipped: asleep")
                return
            }
        }
        scheduleAll(after: 0, reason: "tick")
        writeStatusSoon()
    }

    private func onPower(_ ev: PowerEvent) {
        switch ev {
        case .willSleep:
            let already = lock.withLock { () -> Bool in
                let was = asleepFlag
                asleepFlag = true
                sleptAt = Date()
                return was
            }
            if already { return }
            ejectForSleep()
            writeStatusSoon()
        case .didWake:
            let was = lock.withLock { () -> Bool in
                let w = asleepFlag
                asleepFlag = false
                return w
            }
            let slept = lock.withLock { sleptAt }.map { Int(Date().timeIntervalSince($0)) }
            if was || slept != nil {
                log.info("engine", "wake after \(slept.map { "\($0) s" } ?? "unknown duration"); checking shares in \(Int(config.settings.settleAfterWakeSeconds)) s")
            }
            lock.withLock { sleptAt = nil }
            for c in shareControllers { c.resetBackoff(reason: "wake"); c.releaseHold(reason: "wake") }
            scheduleAll(after: config.settings.settleAfterWakeSeconds, reason: "wake")
            writeStatusSoon()
        }
    }

    private func ejectForSleep() {
        let targets = shareControllers.filter { $0.config.ejectOnSleep && $0.config.enabled }
        guard !targets.isEmpty else { return }
        // IOKit gives us ~30 s in total before it sleeps anyway.
        let overall = Stopwatch()
        let budget = 24.0
        for c in targets {
            let remaining = budget - overall.elapsed
            if remaining < 3 { log.warn("engine", "out of time ejecting before sleep; skipping \(c.config.name)"); continue }
            c.unmountForSleep(deadline: min(remaining, 12))
        }
    }

    private func onNetwork(_ snap: NetworkMonitor.Snapshot, _ prev: NetworkMonitor.Snapshot?) {
        guard let prev = prev else {
            log.info("network", "initial path: \(snap.description)")
            return
        }
        log.info("network", "path changed: \(prev.description) -> \(snap.description)")
        if asleep { return }
        if snap.satisfied {
            for c in shareControllers { c.resetBackoff(reason: "network change") }
            scheduleAll(after: config.settings.settleAfterNetworkSeconds, reason: "network change")
        }
    }

    // MARK: Status file

    private func writeStatusSoon() {
        timerQueue.async { [weak self] in
            guard let self = self else { return }
            self.statusWrite?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                let s = self.status
                do { try s.write(to: self.statusPath) } catch { self.log.error("engine", "status write failed: \(error)") }
                self.onStatusChange?(s)
            }
            self.statusWrite = item
            self.timerQueue.asyncAfter(deadline: .now() + 0.3, execute: item)
        }
    }
}
