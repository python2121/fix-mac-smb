import Foundation

/// Keeps one share alive.
///
/// All evaluation runs on a private serial queue, so at most one blocking
/// operation is in flight per share, and different shares proceed
/// independently. The controller is deliberately synchronous inside
/// `evaluate`: every step has its own deadline, so the total time of one pass
/// is bounded (roughly probe + unmount + mount + verify).
public final class ShareController {
    public let config: ShareConfig
    private(set) var settings: Settings
    private let system: SystemAdapter
    private let log: Log
    private let queue: DispatchQueue

    private let lock = NSLock()
    private var status: ShareStatus
    private var staleSince: Date?
    private var failures = 0
    private var unmountFailures = 0
    private var nextUnmountAt: Date?
    private var nextAttemptAt: Date?
    private var pending: DispatchWorkItem?
    private var pendingAt: Date?
    private var pausedFlag = false
    /// Set when the share was unmounted on purpose (by request, or by the user
    /// in Finder while it was healthy). While held, the controller will not
    /// remount until the next wake, a manual mount, or an explicit check.
    private var held: String?
    /// True once this process has seen this mount answer a probe. A mount that
    /// has never answered is never force-unmounted: the far likelier
    /// explanation is that this process is not allowed to read it (macOS
    /// privacy gating on network volumes blocks the call rather than failing
    /// it), and unmounting a healthy volume over a permissions problem is the
    /// worst thing this tool could do.
    private var everHealthy = false
    /// Cleared when the share is removed from the configuration. Pending work
    /// then does nothing, so a share deleted a moment ago can never be
    /// remounted by an evaluation that was already scheduled.
    private var active = true

    /// Called on the controller's queue after every status change.
    public var onChange: ((ShareStatus) -> Void)?

    public init(config: ShareConfig, settings: Settings, system: SystemAdapter, log: Log) {
        self.config = config
        self.settings = settings
        self.system = system
        self.log = log
        self.queue = DispatchQueue(label: Paths.bundleID + ".share." + config.name)
        self.status = ShareStatus(config: config)
    }

    private var tag: String { config.name }

    public var currentStatus: ShareStatus {
        lock.lock(); defer { lock.unlock() }
        return status
    }

    public var paused: Bool {
        get { lock.lock(); defer { lock.unlock() }; return pausedFlag }
        set {
            lock.lock(); pausedFlag = newValue; lock.unlock()
            if newValue {
                update(.paused, "paused")
            } else {
                releaseHold(reason: "resumed")
                schedule(after: 0, reason: "resumed")
            }
        }
    }

    public func updateSettings(_ s: Settings) {
        lock.lock(); settings = s; lock.unlock()
    }

    // MARK: Scheduling

    /// Ask for an evaluation `after` seconds from now. Requests are coalesced:
    /// if one is already pending sooner, it is kept; otherwise it is replaced.
    public func schedule(after seconds: Double, reason: String) {
        let when = system.now().addingTimeInterval(seconds)
        lock.lock()
        if let at = pendingAt, pending != nil, at <= when {
            lock.unlock()
            return
        }
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            self.pending = nil
            self.pendingAt = nil
            self.lock.unlock()
            self.evaluate(reason: reason)
        }
        pending = item
        pendingAt = when
        lock.unlock()
        queue.asyncAfter(deadline: .now() + max(0, seconds), execute: item)
    }

    /// Forget the backoff so the next evaluation may mount immediately. Used
    /// after wake and network changes, when conditions have changed.
    public func resetBackoff(reason: String) {
        lock.lock()
        let had = nextAttemptAt != nil || failures > 0
        nextAttemptAt = nil
        failures = 0
        lock.unlock()
        if had { log.debug(tag, "backoff reset (\(reason))") }
    }

    /// Lift a hold placed by an intentional unmount. Called on wake, manual
    /// mount, resume, and explicit checks.
    public func releaseHold(reason: String) {
        let had = lock.withLock { () -> Bool in
            let h = held != nil
            held = nil
            return h
        }
        if had { log.info(tag, "hold released (\(reason)); will remount when possible") }
    }

    public var isHeld: Bool { lock.withLock { held != nil } }

    public var isActive: Bool { lock.withLock { active } }

    /// Detach this controller: cancel pending work and ignore everything after.
    public func deactivate() {
        lock.lock()
        active = false
        pending?.cancel()
        pending = nil
        pendingAt = nil
        lock.unlock()
    }

    /// Run a full evaluation synchronously on the calling thread. Only for
    /// tests; everything else goes through `schedule`.
    public func evaluateSync(reason: String) {
        queue.sync { self.evaluate(reason: reason) }
    }

    /// Explicit user request: mount now regardless of backoff. If the share is
    /// already mounted this is just a health check.
    public func requestMount() {
        resetBackoff(reason: "manual mount")
        releaseHold(reason: "manual mount")
        queue.async {
            if self.currentEntry() != nil {
                self.evaluate(reason: "manual mount (already mounted)")
            } else {
                self.attemptMount(reason: "manual")
            }
        }
    }

    /// Explicit user request: unmount now, and stay unmounted until asked.
    public func requestUnmount(force: Bool) {
        queue.async {
            guard let entry = self.currentEntry() else {
                self.update(.unmounted, "not mounted")
                return
            }
            self.update(.unmounting, force ? "force unmounting" : "unmounting")
            let r = self.system.unmount(path: entry.on, force: force, timeout: self.settings.unmountTimeoutSeconds)
            self.log.info(self.tag, "manual unmount of \(entry.on): \(r.description)")
            switch r {
            case .unmounted:
                self.lock.withLock { self.held = "unmounted by request"; self.staleSince = nil }
                self.update(.unmounted, "unmounted by request; will remount on wake, or when you press mount") { st in
                    st.mountPath = nil; st.mountedFrom = nil
                }
            default:
                self.update(.stale, r.description)
            }
        }
    }

    /// Unmount before sleep. Runs synchronously with a bounded deadline. This
    /// is a clean unmount only: open files make it fail, and the mount is then
    /// left for the normal stale handling after wake.
    public func unmountForSleep(deadline: Double) {
        queue.sync {
            guard let entry = self.currentEntry() else { return }
            self.update(.unmounting, "ejecting for sleep")
            let r = self.system.unmount(path: entry.on, force: false, timeout: deadline)
            self.log.info(self.tag, "eject for sleep \(entry.on): \(r.description)")
            switch r {
            case .unmounted:
                self.lock.withLock { self.staleSince = nil }
                self.update(.unmounted, "ejected for sleep") { st in st.mountPath = nil; st.mountedFrom = nil }
            default:
                self.update(.stale, "eject for sleep: \(r.description)")
            }
        }
    }

    // MARK: Evaluation

    private func currentEntry() -> MountEntry? {
        system.mountTable().first { $0.matches(config) }
    }

    private func update(_ state: ShareState, _ detail: String, mutate: ((inout ShareStatus) -> Void)? = nil) {
        lock.lock()
        var s = status
        s.state = state
        s.detail = detail
        s.consecutiveFailures = failures
        s.nextAttemptAt = nextAttemptAt
        s.updatedAt = system.now()
        mutate?(&s)
        let changed = s != status
        status = s
        lock.unlock()
        if changed { onChange?(s) }
    }

    func evaluate(reason: String) {
        guard lock.withLock({ active }) else { return }
        guard config.enabled else { return }
        if paused { return }
        let s = lock.withLock { settings }
        log.debug(tag, "evaluate (\(reason))")

        guard let entry = currentEntry() else {
            handleNotMounted(settings: s, reason: reason)
            return
        }

        let result = system.probe(path: entry.on, timeout: s.probeTimeoutSeconds, listing: s.keepaliveListing)
        switch result {
        case .healthy(let latency):
            let wasStale = lock.withLock { staleSince != nil }
            let previousState = currentStatus.state
            lock.withLock { staleSince = nil; failures = 0; nextAttemptAt = nil; unmountFailures = 0; nextUnmountAt = nil; everHealthy = true }
            let ms = latency * 1000
            if wasStale {
                log.info(tag, "recovered: \(entry.on) answering again (\(Int(ms)) ms)")
            } else if previousState == .healthy {
                log.debug(tag, "probe ok \(Int(ms)) ms")
            } else {
                log.info(tag, "healthy: \(entry.on) (\(Int(ms)) ms)")
            }
            update(.healthy, String(format: "mounted at %@ (%.0f ms)", entry.on, ms)) { st in
                st.mountPath = entry.on
                st.mountedFrom = entry.from
                st.lastProbeLatencyMs = ms
                st.lastHealthyAt = self.system.now()
                st.lastError = nil
            }

        case .hung, .failed:
            handleUnhealthy(entry: entry, result: result, settings: s)
        }
    }

    private func handleUnhealthy(entry: MountEntry, result: ProbeResult, settings s: Settings) {
        let now = system.now()
        var since: Date
        lock.lock()
        if let existing = staleSince {
            since = existing
        } else {
            since = now
            staleSince = now
        }
        lock.unlock()
        let staleFor = now.timeIntervalSince(since)

        if staleFor == 0 {
            log.warn(tag, "\(entry.on) is \(result.description)")
        } else {
            log.warn(tag, "\(entry.on) still \(result.description); stale for \(Int(staleFor)) s")
        }

        if !lock.withLock({ everHealthy }) {
            // Never seen working in this process: report, never unmount.
            log.warn(tag, "\(entry.on) has not answered since this process started. If the volume works in Finder, SMB Keeper is probably being denied access to network volumes: allow it under System Settings > Privacy & Security > Files and Folders (or grant Full Disk Access). Not unmounting anything.")
            update(.stale, "\(result.description); never answered since startup, so not unmounting. Check Privacy & Security > Files and Folders.") { st in
                st.mountPath = entry.on; st.mountedFrom = entry.from; st.lastError = result.description
            }
            schedule(after: max(60, s.tickSeconds), reason: "permission watch")
            return
        }

        if staleFor < s.staleGraceSeconds {
            let remaining = s.staleGraceSeconds - staleFor
            update(.stale, "\(result.description); force unmount in \(Int(remaining.rounded(.up))) s") { st in
                st.mountPath = entry.on; st.mountedFrom = entry.from; st.lastError = result.description
            }
            schedule(after: remaining, reason: "stale grace expired")
            return
        }

        // Wait out the backoff between force-unmount attempts. Each attempt that
        // hangs leaves a process parked in the kernel, so they must not stack up.
        if let next = lock.withLock({ nextUnmountAt }), now < next {
            let wait = next.timeIntervalSince(now)
            update(.stale, "\(result.description); retrying force unmount in \(Int(wait.rounded(.up))) s") { st in
                st.mountPath = entry.on; st.mountedFrom = entry.from; st.lastError = result.description
            }
            schedule(after: wait, reason: "unmount backoff expired")
            return
        }

        update(.unmounting, "force unmounting hung mount") { st in
            st.mountPath = entry.on; st.mountedFrom = entry.from; st.lastError = result.description
        }
        log.warn(tag, "force unmounting \(entry.on) after \(Int(staleFor)) s stale")
        let u = system.unmount(path: entry.on, force: true, timeout: s.unmountTimeoutSeconds)
        log.info(tag, "force unmount: \(u.description)")
        switch u {
        case .unmounted:
            lock.withLock { staleSince = nil; unmountFailures = 0; nextUnmountAt = nil }
            attemptMount(reason: "remount after force unmount")
        case .stillMounted, .timedOut:
            let count = lock.withLock { () -> Int in unmountFailures += 1; return unmountFailures }
            let capped = count >= s.maxForceUnmountAttempts
            // Past the cap, wait the maximum backoff between attempts: the gate
            // and the reschedule must agree, or a later trigger retries early.
            let delay = capped ? max(s.backoff(afterFailures: count), s.backoffMaxSeconds)
                               : s.backoff(afterFailures: count)
            lock.withLock { nextUnmountAt = now.addingTimeInterval(delay) }
            if capped {
                // The kernel will not let go. Nothing in user space can fix
                // this; say so instead of hammering it forever.
                log.error(tag, "force unmount of \(entry.on) has failed \(count) times (\(u.description)); the kernel is holding the mount. A restart may be needed to clear it.")
                update(.stale, "hung and will not unmount after \(count) attempts; a restart may be needed") { st in
                    st.lastError = u.description
                }
                schedule(after: delay, reason: "wedged mount recheck")
            } else {
                update(.stale, "hung; \(u.description); retry \(count + 1) in \(Int(delay)) s") { st in st.lastError = u.description }
                schedule(after: delay, reason: "retry unmount")
            }
        }
    }

    private func handleNotMounted(settings s: Settings, reason: String) {
        let previous = currentStatus
        lock.withLock { staleSince = nil; unmountFailures = 0; nextUnmountAt = nil }
        // A share that was healthy at the last look and is now simply gone was
        // ejected by the user (Finder, or another tool), not by a dead session:
        // a dying session shows up as a hung probe first. Respect the eject.
        if previous.state == .healthy, previous.mountPath != nil {
            lock.withLock { held = "ejected outside SMB Keeper" }
            log.info(tag, "\(previous.mountPath!) was ejected outside SMB Keeper; holding until wake or a mount from the panel")
        }
        if let why = lock.withLock({ held }) {
            update(.unmounted, "\(why); will remount on wake, or when you press mount") { st in
                st.mountPath = nil; st.mountedFrom = nil
            }
            return
        }
        attemptMount(reason: reason)
    }

    /// Mount if allowed by backoff and reachability. Runs on the queue.
    private func attemptMount(reason: String) {
        guard lock.withLock({ active }) else { return }
        let s = lock.withLock { settings }
        let now = system.now()

        if let next = lock.withLock({ nextAttemptAt }), now < next {
            let wait = next.timeIntervalSince(now)
            update(.failed, "waiting \(Int(wait.rounded(.up))) s before retry") { st in st.mountPath = nil }
            schedule(after: wait, reason: "backoff expired")
            return
        }

        if !system.reachable(host: config.server, timeout: s.reachabilityTimeoutSeconds) {
            log.info(tag, "\(config.server) not reachable on port 445; will retry in \(Int(s.unreachableRetrySeconds)) s")
            update(.unreachable, "\(config.server) not reachable on TCP 445") { st in st.mountPath = nil; st.mountedFrom = nil }
            schedule(after: s.unreachableRetrySeconds, reason: "unreachable retry")
            return
        }

        guard let url = config.url else {
            update(.failed, "invalid URL")
            return
        }
        system.removeStaleMountDirectory(config.expectedMountPoint)
        update(.mounting, "mounting \(url.absoluteString)") { st in st.mountPath = nil }
        log.info(tag, "mounting \(url.absoluteString) (\(reason))")
        var m = system.mount(url: url, mountPoint: config.mountPoint, timeout: s.mountTimeoutSeconds)
        if case .failed(let status, _) = m, status == EEXIST, let existing = currentEntry() {
            // Someone else (Finder, a login item) mounted it while we were looking.
            m = .mounted(paths: [existing.on])
        }
        switch m {
        case .mounted(let paths):
            let path = paths.first ?? currentEntry()?.on ?? config.expectedMountPoint
            let verify = system.probe(path: path, timeout: s.probeTimeoutSeconds, listing: false)
            lock.withLock { failures = 0; nextAttemptAt = nil; staleSince = nil }
            if case .healthy(let latency) = verify {
                log.info(tag, "mounted at \(path) and verified (\(Int(latency * 1000)) ms)")
                update(.healthy, String(format: "mounted at %@ (%.0f ms)", path, latency * 1000)) { st in
                    st.mountPath = path
                    st.mountedFrom = self.currentEntry()?.from
                    st.lastMountAt = self.system.now()
                    st.lastHealthyAt = self.system.now()
                    st.lastProbeLatencyMs = latency * 1000
                    st.lastError = nil
                }
            } else {
                log.warn(tag, "mounted at \(path) but verification \(verify.description)")
                update(.stale, "mounted but \(verify.description)") { st in
                    st.mountPath = path; st.lastMountAt = self.system.now(); st.lastError = verify.description
                }
                schedule(after: 5, reason: "verify after mount")
            }
        case .failed, .timedOut:
            let count = lock.withLock { () -> Int in failures += 1; return failures }
            let delay = s.backoff(afterFailures: count)
            let next = now.addingTimeInterval(delay)
            lock.withLock { nextAttemptAt = next }
            log.error(tag, "mount \(m.description); attempt \(count), retry in \(Int(delay)) s")
            update(.failed, "\(m.description); retry in \(Int(delay)) s") { st in
                st.lastError = m.description; st.mountPath = nil
            }
            schedule(after: delay, reason: "backoff expired")
        }
    }
}

extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
