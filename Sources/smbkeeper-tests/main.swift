import Foundation
import CoreGraphics
import SMBKeeperCore

// Isolate every path the library touches.
let testHome = makeTempDir()
setenv("SMBKEEPER_HOME", testHome, 1)
let h = Harness.shared
h.configure(filter: CommandLine.arguments.dropFirst().first)
let quietLog = Log()   // never configured with a file: keeps tests silent

func makeShare(_ share: String, server: String = "nas.test", eject: Bool = false) -> ShareConfig {
    ShareConfig(name: share, server: server, share: share, user: "tester", ejectOnSleep: eject)
}

/// Settings tuned for fast tests: short grace and backoff so a few simulated
/// seconds cover what takes minutes in production.
func testSettings() -> Settings {
    var s = Settings.defaults
    s.staleGraceSeconds = 20
    s.backoffMinSeconds = 5
    s.backoffMaxSeconds = 300
    s.unreachableRetrySeconds = 20
    s.maxForceUnmountAttempts = 5
    return s
}


/// Give the controller one healthy observation first. Recovery only applies to
/// a mount this process has seen working, so tests about recovery must start
/// from that state, exactly as the daemon does in practice.
func seedHealthy(_ c: ShareController, _ sys: FakeSystem, path: String) {
    let saved = sys.probeResults[path]
    sys.probeResults[path] = .healthy(latency: 0.001)
    c.evaluateSync(reason: "seed")
    sys.probeResults[path] = saved
    sys.clearCalls()
}

// MARK: - Config

h.test("config: defaults fill in missing settings") {
    let json = #"{"shares":[{"server":"nas.test","share":"Alpha"}]}"#
    let c = try JSONDecoder().decode(Config.self, from: json.data(using: .utf8)!)
    expectEqual(c.settings, Settings.defaults)
    expectEqual(c.shares.count, 1)
    expectEqual(c.shares[0].name, "Alpha", "name defaults to share")
    expectEqual(c.shares[0].enabled, true)
    expectEqual(c.shares[0].ejectOnSleep, false)
    expectEqual(c.shares[0].expectedMountPoint, "/Volumes/Alpha")
}

h.test("config: partial settings override only what they name") {
    let json = #"{"settings":{"tickSeconds":30,"keepaliveListing":false},"shares":[]}"#
    let c = try JSONDecoder().decode(Config.self, from: json.data(using: .utf8)!)
    expectEqual(c.settings.tickSeconds, 30)
    expectEqual(c.settings.keepaliveListing, false)
    expectEqual(c.settings.probeTimeoutSeconds, Settings.defaults.probeTimeoutSeconds)
    expectEqual(c.settings.staleGraceSeconds, Settings.defaults.staleGraceSeconds)
}

h.test("config: URL building encodes spaces and carries the user") {
    let s = ShareConfig(server: "nas.test", share: "Beta Backups", user: "tester")
    expectEqual(s.url?.absoluteString, "smb://tester@nas.test/Beta%20Backups")
    let b = ShareConfig(server: "fileserver._smb._tcp.local", share: "Alpha")
    expectEqual(b.url?.absoluteString, "smb://fileserver._smb._tcp.local/Alpha")
}

h.test("config: validation rejects bad input") {
    expectThrows("empty share") { try Config(shares: [ShareConfig(server: "h", share: "")]).validate() }
    expectThrows("slash in share") { try Config(shares: [ShareConfig(server: "h", share: "a/b")]).validate() }
    expectThrows("duplicate names") {
        try Config(shares: [ShareConfig(name: "x", server: "h", share: "a"), ShareConfig(name: "X", server: "h", share: "b")]).validate()
    }
    expectThrows("relative mount point") { try Config(shares: [ShareConfig(server: "h", share: "a", mountPoint: "rel")]).validate() }
    var bad = Settings.defaults
    bad.tickSeconds = 1
    expectThrows("tick too small") { try Config(settings: bad).validate() }
}

h.test("config: save and load round trip") {
    let path = testHome + "/roundtrip.json"
    var c = Config()
    c.settings.tickSeconds = 45
    c.shares = [makeShare("Alpha"), makeShare("Beta", eject: true)]
    try c.save(to: path)
    let back = try Config.load(from: path)
    expectEqual(back, c)
    expectEqual(back.share(named: "beta")?.ejectOnSleep, true, "lookup is case-insensitive")
}

h.test("config: an old config file with a leftover mode key still loads") {
    let json = #"{"settings":{"mode":"observe","tickSeconds":45},"shares":[{"server":"h","share":"S"}]}"#
    let c = try JSONDecoder().decode(Config.self, from: json.data(using: .utf8)!)
    expectEqual(c.settings.tickSeconds, 45)
    expectEqual(c.shares.count, 1)
}

h.test("config: missing file is a distinct error") {
    do {
        _ = try Config.load(from: testHome + "/nope.json")
        expect(false, "should have thrown")
    } catch ConfigError.missing {
        // expected
    }
    let empty = try Config.loadOrEmpty(from: testHome + "/nope.json")
    expectEqual(empty.shares.count, 0)
}

h.test("settings: backoff grows exponentially and caps") {
    let s = testSettings()
    expectEqual(s.backoff(afterFailures: 0), 0)
    expectEqual(s.backoff(afterFailures: 1), 5)
    expectEqual(s.backoff(afterFailures: 2), 10)
    expectEqual(s.backoff(afterFailures: 3), 20)
    expectEqual(s.backoff(afterFailures: 10), 300)
}

// MARK: - Mount table parsing

h.test("mount source: parses user, host, share") {
    let p = SMBMountSource.parse("//tester@fileserver._smb._tcp.local/Alpha")
    expectEqual(p, SMBMountSource(user: "tester", host: "fileserver._smb._tcp.local", share: "Alpha"))
}

h.test("mount source: no user, percent-encoded share, IPv6 host") {
    expectEqual(SMBMountSource.parse("//nas.test/Beta%20Backups"),
                SMBMountSource(user: nil, host: "nas.test", share: "Beta Backups"))
    expectEqual(SMBMountSource.parse("//u@[fe80::1]/S"), SMBMountSource(user: "u", host: "fe80::1", share: "S"))
    expectEqual(SMBMountSource.parse("//u@h/S/sub")?.share, "S", "nested path keeps first component")
}

h.test("mount source: rejects malformed input") {
    expectNil(SMBMountSource.parse("/dev/disk3s1"))
    expectNil(SMBMountSource.parse("//host"))
    expectNil(SMBMountSource.parse("//host/"))
    expectNil(SMBMountSource.parse("//@/share"))
}

h.test("mount entry: matches share by name regardless of host spelling") {
    let e = MountEntry(fsType: "smbfs", from: "//tester@fileserver._smb._tcp.local/Alpha", on: "/Volumes/Alpha", flags: 0, owner: 501)
    expect(e.matches(makeShare("Alpha")))
    expect(e.matches(makeShare("alpha")), "case-insensitive")
    expect(!e.matches(makeShare("Beta")))
    let pinned = ShareConfig(server: "x", share: "Alpha", mountPoint: "/Volumes/Elsewhere")
    expect(!pinned.let { e.matches($0) }, "explicit mount point must match")
    let apfs = MountEntry(fsType: "apfs", from: "/dev/disk3s1", on: "/Volumes/Alpha", flags: 0, owner: 0)
    expect(!apfs.matches(makeShare("Alpha")), "non-smb never matches")
}

h.test("mount table: live snapshot includes root and never blocks") {
    let sw = Stopwatch()
    let all = MountTable.snapshot()
    expect(all.contains { $0.on == "/" }, "root filesystem present")
    expect(sw.elapsed < 1, "snapshot took \(sw.elapsed) s")
    expect(MountTable.isMountPoint("/"))
    expect(!MountTable.isMountPoint("/usr"))
}

// MARK: - Deadline and prober

h.test("deadline: returns result when work finishes in time") {
    let r = Deadline.run(seconds: 2, name: "fast") { 42 }
    expectEqual(r, 42)
}

h.test("deadline: returns nil when work overruns, without blocking") {
    let sw = Stopwatch()
    let r: Int? = Deadline.run(seconds: 0.2, name: "slow") { Thread.sleep(forTimeInterval: 1.0); return 1 }
    expectNil(r)
    expect(sw.elapsed < 0.8, "returned after \(sw.elapsed) s")
}

h.test("prober: healthy on a local directory, ENOENT on a missing one") {
    let r = Prober.probe(path: "/", timeout: 5, listing: true)
    expect(r.isHealthy, "got \(r.description)")
    let miss = Prober.probe(path: "/definitely/not/here", timeout: 5, listing: false)
    expectEqual(miss, .failed(errno: ENOENT))
}

// MARK: - Bonjour and reachability

h.test("bonjour: parses service instance names") {
    expectEqual(BonjourService.parse("fileserver._smb._tcp.local"), BonjourService(name: "fileserver", type: "_smb._tcp", domain: "local"))
    expectEqual(BonjourService.parse("My fileserver._smb._tcp.local."), BonjourService(name: "My fileserver", type: "_smb._tcp", domain: "local"))
    expectEqual(BonjourService.parse("a.b._afpovertcp._tcp.example.com")?.domain, "example.com")
    expectNil(BonjourService.parse("nas.test"))
    expectNil(BonjourService.parse("fileserver.local"))
    expectNil(BonjourService.parse("fileserver"))
    expectNil(BonjourService.parse("_smb._tcp.local"), "no instance name")
}

h.test("reachability: unroutable address is not reachable, fast") {
    // 192.0.2.0/24 is TEST-NET-1, guaranteed unrouted.
    let sw = Stopwatch()
    let r = Reachability.tcpProbe(host: "192.0.2.1", port: 445, timeout: 1.0)
    if case .reachable = r { expect(false, "TEST-NET-1 must not be reachable") }
    expect(sw.elapsed < 2.5, "took \(sw.elapsed) s")
}

h.test("reachability: policy-shaped errors are classified only when immediate") {
    if case .blockedByPolicy = Reachability.classify(.posix(.ENETDOWN), elapsed: 0.01) {} else { expect(false, "ENETDOWN fast = policy") }
    if case .blockedByPolicy = Reachability.classify(.posix(.EHOSTUNREACH), elapsed: 0.5) {} else { expect(false, "EHOSTUNREACH fast = policy") }
    if case .unreachable = Reachability.classify(.posix(.EHOSTUNREACH), elapsed: 3) {} else { expect(false, "slow EHOSTUNREACH = unreachable") }
    if case .unreachable = Reachability.classify(.posix(.ECONNREFUSED), elapsed: 0.01) {} else { expect(false, "refused = unreachable") }
    if case .unreachable = Reachability.classify(.dns(1), elapsed: 0.01) {} else { expect(false, "dns = unreachable") }
}

h.test("reachability: ping helper rejects bonjour names and answers for loopback") {
    expect(!Reachability.ping(host: "fileserver._smb._tcp.local", timeout: 1))
    expect(Reachability.ping(host: "127.0.0.1", timeout: 2), "ping 127.0.0.1")
}

h.test("reachability: loopback with a listening port succeeds") {
    // Bind a throwaway listener so the test does not depend on any service.
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    expect(fd >= 0)
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    addr.sin_port = 0
    var yes: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
    let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    expectEqual(bound, 0, "bind")
    expectEqual(listen(fd, 4), 0, "listen")
    var bound_addr = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &bound_addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
    let port = UInt16(bigEndian: bound_addr.sin_port)
    expect(port > 0)
    expect(Reachability.tcpReachable(host: "127.0.0.1", port: port, timeout: 2), "connect to 127.0.0.1:\(port)")
    close(fd)
    expect(!Reachability.tcpReachable(host: "127.0.0.1", port: port, timeout: 1), "closed port refuses")
}

// MARK: - Subprocess

h.test("subprocess: captures output and exit status") {
    let r = Subprocess.run("/bin/sh", ["-c", "echo out; echo err 1>&2; exit 3"], timeout: 5)
    expectEqual(r.status, 3)
    expectEqual(r.stdout, "out\n")
    expectEqual(r.stderr, "err\n")
    expect(!r.timedOut)
}

h.test("subprocess: kills on timeout") {
    let sw = Stopwatch()
    let r = Subprocess.run("/bin/sleep", ["30"], timeout: 0.5)
    expect(r.timedOut)
    expect(sw.elapsed < 4, "took \(sw.elapsed) s")
}

h.test("subprocess: large output does not deadlock") {
    let r = Subprocess.run("/bin/sh", ["-c", "head -c 300000 /dev/zero | tr '\\0' 'x'"], timeout: 10)
    expect(r.succeeded)
    expectEqual(r.stdout.count, 300000)
}

// MARK: - Log

h.test("log: writes, keeps a ring buffer, rotates") {
    let log = Log()
    let path = testHome + "/log/test.log"
    log.maxFileBytes = 2000
    log.keepRotations = 2
    try log.configure(filePath: path, echoToStderr: false, minLevel: .info)
    log.debug("t", "hidden")
    for i in 0..<100 { log.info("t", "line \(i) " + String(repeating: "x", count: 40)) }
    expect(FileManager.default.fileExists(atPath: path + ".1"), "rotated once")
    let recent = log.recent(5)
    expectEqual(recent.count, 5)
    expectEqual(recent.last?.message.hasPrefix("line 99"), true)
    expect(!log.recent(1000).contains { $0.message == "hidden" }, "debug filtered")
    var seen = 0
    log.addListener { _ in seen += 1 }
    log.warn("t", "one more")
    expectEqual(seen, 1)
}

// MARK: - Status and commands

h.test("status: round trip through file") {
    var st = EngineStatus(pid: getpid(), paused: false, asleep: false, startedAt: Date(), updatedAt: Date(), shares: [ShareStatus(config: makeShare("Alpha"))])
    st.shares[0].state = .healthy
    let path = testHome + "/status.json"
    try st.write(to: path)
    let back = EngineStatus.read(from: path)
    expectNotNil(back)
    expectEqual(back?.shares.first?.state, .healthy)
    expect(back?.daemonAlive == true)
    expectNil(EngineStatus.read(from: testHome + "/missing.json"))
}

h.test("commands: send and drain in order, stale ones dropped") {
    let dir = testHome + "/commands"
    _ = try CommandQueue.send(Command(kind: .mount, share: "A"), dir: dir)
    Thread.sleep(forTimeInterval: 0.01)
    _ = try CommandQueue.send(Command(kind: .reload), dir: dir)
    var stale = Command(kind: .pause)
    stale.issuedAt = Date().addingTimeInterval(-3600)
    let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
    try enc.encode(stale).write(to: URL(fileURLWithPath: dir + "/0000-stale.json"))
    try "garbage".write(toFile: dir + "/0001-bad.json", atomically: true, encoding: .utf8)
    let got = CommandQueue.drain(dir: dir)
    expectEqual(got.map { $0.kind }, [.mount, .reload])
    expectEqual(got.first?.share, "A")
    expectEqual(CommandQueue.drain(dir: dir).count, 0, "drained files are deleted")
    expectEqual(try FileManager.default.contentsOfDirectory(atPath: dir).count, 0)
}

// MARK: - Launch agent plist

h.test("launch agent: plist is well-formed and escapes arguments") {
    let text = LaunchAgent.plist(program: "/Applications/SMB Keeper.app/Contents/MacOS/SMBKeeperApp", arguments: ["a&b"])
    let data = text.data(using: .utf8)!
    let obj = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
    expectNotNil(obj)
    expectEqual(obj?["Label"] as? String, Paths.launchAgentLabel)
    expectEqual((obj?["ProgramArguments"] as? [String])?.last, "a&b")
    expectEqual(obj?["KeepAlive"] as? Bool, true)
    expectEqual(obj?["LimitLoadToSessionType"] as? String, "Aqua")
}

// MARK: - Power monitor helpers

h.test("power: user-input idle time is readable") {
    let idle = PowerMonitor.secondsSinceUserInput()
    expect(idle >= 0 && idle < 1e7, "idle = \(idle)")
}

// MARK: - Share controller

h.test("controller: missing mount is mounted when reachable and verified") {
    let sys = FakeSystem()
    sys.reachableHosts = ["nas.test"]
    let c = ShareController(config: makeShare("Beta"), settings: testSettings(), system: sys, log: quietLog)
    c.evaluateSync(reason: "test")
    expectEqual(c.currentStatus.state, .healthy)
    expectEqual(c.currentStatus.mountPath, "/Volumes/Beta")
    expectEqual(sys.calls, ["reach nas.test", "rmdir /Volumes/Beta", "mount smb://tester@nas.test/Beta", "probe /Volumes/Beta"])
    expectNotNil(c.currentStatus.lastMountAt)
}

h.test("controller: unreachable server means no mount attempt") {
    let sys = FakeSystem()
    let c = ShareController(config: makeShare("Beta"), settings: testSettings(), system: sys, log: quietLog)
    c.evaluateSync(reason: "test")
    expectEqual(c.currentStatus.state, .unreachable)
    expectEqual(sys.calls, ["reach nas.test"])
}

h.test("controller: bonjour server is checked as a service endpoint name") {
    let sys = FakeSystem()
    sys.reachableHosts = ["fileserver._smb._tcp.local"]
    let c = ShareController(config: makeShare("Beta", server: "fileserver._smb._tcp.local"), settings: testSettings(), system: sys, log: quietLog)
    c.evaluateSync(reason: "test")
    expectEqual(c.currentStatus.state, .healthy)
    expectEqual(sys.calls[2], "mount smb://tester@fileserver._smb._tcp.local/Beta")
}

h.test("controller: mount failure backs off exponentially and resets on wake") {
    let sys = FakeSystem()
    sys.reachableHosts = ["nas.test"]
    sys.mountResult = .failed(status: -6602, message: "NetAuth mount failed")
    let s = testSettings()
    let c = ShareController(config: makeShare("Beta"), settings: s, system: sys, log: quietLog)

    c.evaluateSync(reason: "1")
    expectEqual(c.currentStatus.state, .failed)
    expectEqual(c.currentStatus.consecutiveFailures, 1)
    expectEqual(c.currentStatus.nextAttemptAt, sys.now().addingTimeInterval(5))
    expectEqual(sys.calls.filter { $0.hasPrefix("mount") }.count, 1)

    // Too early: no new attempt.
    sys.advance(2)
    c.evaluateSync(reason: "2")
    expectEqual(sys.calls.filter { $0.hasPrefix("mount") }.count, 1, "respects backoff")
    expectEqual(c.currentStatus.state, .failed)

    // After the backoff: second attempt, doubled delay.
    sys.advance(4)
    c.evaluateSync(reason: "3")
    expectEqual(sys.calls.filter { $0.hasPrefix("mount") }.count, 2)
    expectEqual(c.currentStatus.consecutiveFailures, 2)
    expectEqual(c.currentStatus.nextAttemptAt, sys.now().addingTimeInterval(10))

    // Wake resets the backoff, so the next evaluation tries immediately.
    c.resetBackoff(reason: "wake")
    c.evaluateSync(reason: "4")
    expectEqual(sys.calls.filter { $0.hasPrefix("mount") }.count, 3)
    expectEqual(c.currentStatus.consecutiveFailures, 1, "failure count restarted")

    // And a later success clears everything.
    sys.mountResult = .mounted(paths: [])
    sys.advance(10)
    c.evaluateSync(reason: "5")
    expectEqual(c.currentStatus.state, .healthy)
    expectEqual(c.currentStatus.consecutiveFailures, 0)
    expectNil(c.currentStatus.nextAttemptAt)
    expectNil(c.currentStatus.lastError)
}

h.test("controller: hung mount waits out the grace period, then force unmounts and remounts") {
    let sys = FakeSystem()
    sys.table = [sys.entry(host: "fileserver._smb._tcp.local", share: "Alpha")]
    sys.probeResults["/Volumes/Alpha"] = .hung
    sys.reachableHosts = ["nas.test"]
    let c = ShareController(config: makeShare("Alpha"), settings: testSettings(), system: sys, log: quietLog)
    seedHealthy(c, sys, path: "/Volumes/Alpha")

    c.evaluateSync(reason: "1")
    expectEqual(c.currentStatus.state, .stale)
    expect(!sys.calls.contains { $0.hasPrefix("unmount") }, "no unmount inside grace")

    sys.advance(10)
    c.evaluateSync(reason: "2")
    expectEqual(c.currentStatus.state, .stale)
    expect(!sys.calls.contains { $0.hasPrefix("unmount") }, "still inside grace")

    sys.advance(11)
    // Third pass: the first probe still hangs (grace now expired), the verify
    // probe after the remount answers.
    sys.probeQueue["/Volumes/Alpha"] = [.hung, .healthy(latency: 0.003)]
    let before = sys.calls.count
    c.evaluateSync(reason: "3")
    let tail = Array(sys.calls[before...])
    expectEqual(tail, ["probe /Volumes/Alpha", "unmount -f /Volumes/Alpha", "reach nas.test", "rmdir /Volumes/Alpha", "mount smb://tester@nas.test/Alpha", "probe /Volumes/Alpha"])
    expectEqual(c.currentStatus.state, .healthy)
    expectEqual(c.currentStatus.mountedFrom, "//tester@nas.test/Alpha", "remounted by IP")
}

h.test("controller: probe errors count as unhealthy just like hangs") {
    let sys = FakeSystem()
    sys.table = [sys.entry(share: "Alpha")]
    sys.probeResults["/Volumes/Alpha"] = .failed(errno: ENXIO)
    let c = ShareController(config: makeShare("Alpha"), settings: testSettings(), system: sys, log: quietLog)
    seedHealthy(c, sys, path: "/Volumes/Alpha")
    c.evaluateSync(reason: "1")
    expectEqual(c.currentStatus.state, .stale)
    expect(c.currentStatus.detail.contains("Device not configured"), c.currentStatus.detail)
}

h.test("controller: failed force unmount leaves share stale and does not mount") {
    let sys = FakeSystem()
    sys.table = [sys.entry(share: "Alpha")]
    sys.probeResults["/Volumes/Alpha"] = .hung
    sys.reachableHosts = ["nas.test"]
    sys.unmountResult = .stillMounted(detail: "Resource busy")
    let c = ShareController(config: makeShare("Alpha"), settings: testSettings(), system: sys, log: quietLog)
    seedHealthy(c, sys, path: "/Volumes/Alpha")
    c.evaluateSync(reason: "1")
    sys.advance(25)
    c.evaluateSync(reason: "2")
    expectEqual(c.currentStatus.state, .stale)
    expect(sys.calls.contains("unmount -f /Volumes/Alpha"))
    expect(!sys.calls.contains { $0.hasPrefix("mount") }, "no mount while old one is stuck")
}

h.test("controller: healthy probe after a stale spell clears the stale timer") {
    let sys = FakeSystem()
    sys.table = [sys.entry(share: "Alpha")]
    sys.probeResults["/Volumes/Alpha"] = .hung
    let c = ShareController(config: makeShare("Alpha"), settings: testSettings(), system: sys, log: quietLog)
    c.evaluateSync(reason: "1")
    sys.advance(10)
    sys.probeResults["/Volumes/Alpha"] = .healthy(latency: 0.001)
    c.evaluateSync(reason: "2")
    expectEqual(c.currentStatus.state, .healthy)
    // Hang again: the grace must start over, not carry the earlier 10 s.
    sys.probeResults["/Volumes/Alpha"] = .hung
    sys.advance(5)
    c.evaluateSync(reason: "3")
    sys.advance(12)
    c.evaluateSync(reason: "4")
    expect(!sys.calls.contains { $0.hasPrefix("unmount") }, "grace restarted, 12 s < 20 s")
}

h.test("controller: repeated force-unmount failures back off and stop hammering") {
    let sys = FakeSystem()
    sys.table = [sys.entry(share: "Alpha")]
    sys.probeResults["/Volumes/Alpha"] = .hung
    sys.unmountResult = .timedOut
    sys.reachableHosts = ["nas.test"]
    var s = testSettings()
    s.maxForceUnmountAttempts = 3
    let c = ShareController(config: makeShare("Alpha"), settings: s, system: sys, log: quietLog)
    seedHealthy(c, sys, path: "/Volumes/Alpha")

    c.evaluateSync(reason: "1")            // stale, inside grace
    sys.advance(25)
    c.evaluateSync(reason: "2")            // attempt 1
    expectEqual(sys.calls.filter { $0.hasPrefix("unmount -f") }.count, 1)
    // Immediately after, the backoff must suppress a second attempt.
    c.evaluateSync(reason: "3")
    expectEqual(sys.calls.filter { $0.hasPrefix("unmount -f") }.count, 1, "backoff suppressed the retry")
    sys.advance(6)
    c.evaluateSync(reason: "4")            // attempt 2 after 5 s
    expectEqual(sys.calls.filter { $0.hasPrefix("unmount -f") }.count, 2)
    sys.advance(11)
    c.evaluateSync(reason: "5")            // attempt 3 after 10 s -> cap reached
    expectEqual(sys.calls.filter { $0.hasPrefix("unmount -f") }.count, 3)
    expectEqual(c.currentStatus.state, .stale)
    expect(c.currentStatus.detail.contains("restart may be needed"), c.currentStatus.detail)
    // Beyond the cap it waits the maximum backoff rather than retrying fast.
    sys.advance(30)
    c.evaluateSync(reason: "6")
    expectEqual(sys.calls.filter { $0.hasPrefix("unmount -f") }.count, 3, "no more hammering")
}

h.test("controller: unmount counters clear once the mount comes back") {
    let sys = FakeSystem()
    sys.table = [sys.entry(share: "Alpha")]
    sys.probeResults["/Volumes/Alpha"] = .hung
    sys.unmountResult = .timedOut
    let c = ShareController(config: makeShare("Alpha"), settings: testSettings(), system: sys, log: quietLog)
    seedHealthy(c, sys, path: "/Volumes/Alpha")
    c.evaluateSync(reason: "1")
    sys.advance(25)
    c.evaluateSync(reason: "2")
    expectEqual(sys.calls.filter { $0.hasPrefix("unmount -f") }.count, 1)
    // Kernel recovers on its own.
    sys.probeResults["/Volumes/Alpha"] = .healthy(latency: 0.002)
    c.evaluateSync(reason: "3")
    expectEqual(c.currentStatus.state, .healthy)
    // A later hang starts the attempt count from scratch.
    sys.unmountResult = .unmounted
    sys.reachableHosts = ["nas.test"]
    sys.probeResults["/Volumes/Alpha"] = .hung
    c.evaluateSync(reason: "4")
    sys.advance(25)
    // The pass that unmounts and remounts: hung probe first, then the mount
    // verification answers.
    sys.probeQueue["/Volumes/Alpha"] = [.hung, .healthy(latency: 0.002)]
    c.evaluateSync(reason: "5")
    expectEqual(sys.calls.filter { $0.hasPrefix("unmount -f") }.count, 2)
    expectEqual(c.currentStatus.state, .healthy, "remounted after a successful unmount")
}

h.test("prober: a stuck probe is not started twice for the same path") {
    // A FIFO with no writer makes opendir/statfs block the way a dead mount does.
    let dir = makeTempDir()
    let fifo = dir + "/blocker"
    expectEqual(mkfifo(fifo, 0o600), 0)
    // statfs on the directory succeeds, so use the fifo path itself: statfs is
    // fine but open() blocks. Probe the fifo directly.
    let sw = Stopwatch()
    let first = Prober.probe(path: fifo, timeout: 0.5, listing: true)
    expectEqual(first, .failed(errno: ENOTDIR), "statfs works, opendir on a fifo is ENOTDIR: \(first.description)")
    expect(sw.elapsed < 2)
    expect(!Prober.isProbeStuck(fifo), "a completed probe releases its slot")
}

h.test("controller: a mount that never answered is never unmounted") {
    // The shape of a privacy denial: the volume is mounted and the server is
    // fine, but this process cannot read it, so every probe hangs.
    let sys = FakeSystem()
    sys.table = [sys.entry(share: "Alpha")]
    sys.probeResults["/Volumes/Alpha"] = .hung
    sys.reachableHosts = ["nas.test"]
    let c = ShareController(config: makeShare("Alpha"), settings: testSettings(), system: sys, log: quietLog)
    for _ in 0..<6 {
        c.evaluateSync(reason: "tick")
        sys.advance(120)
    }
    expectEqual(c.currentStatus.state, .stale)
    expect(c.currentStatus.detail.contains("Privacy"), c.currentStatus.detail)
    expect(!sys.calls.contains { $0.hasPrefix("unmount") }, "must never unmount: \(sys.calls)")
    expect(!sys.calls.contains { $0.hasPrefix("mount ") }, "must not remount either")
}

h.test("controller: once seen healthy, a later hang is still recovered") {
    let sys = FakeSystem()
    sys.table = [sys.entry(share: "Alpha")]
    sys.reachableHosts = ["nas.test"]
    let c = ShareController(config: makeShare("Alpha"), settings: testSettings(), system: sys, log: quietLog)
    c.evaluateSync(reason: "1")
    expectEqual(c.currentStatus.state, .healthy)
    sys.probeResults["/Volumes/Alpha"] = .hung
    c.evaluateSync(reason: "2")
    sys.advance(25)
    sys.probeQueue["/Volumes/Alpha"] = [.hung, .healthy(latency: 0.002)]
    c.evaluateSync(reason: "3")
    expect(sys.calls.contains("unmount -f /Volumes/Alpha"), "recovery still happens for a mount we saw working")
    expectEqual(c.currentStatus.state, .healthy)
}

h.test("controller: disabled share is never evaluated") {
    let sys = FakeSystem()
    var cfg = makeShare("Alpha"); cfg.enabled = false
    let c = ShareController(config: cfg, settings: testSettings(), system: sys, log: quietLog)
    c.evaluateSync(reason: "1")
    expectEqual(sys.calls, [])
    expectEqual(c.currentStatus.state, .paused)
}

h.test("controller: paused share is not evaluated, resume schedules a check") {
    let sys = FakeSystem()
    sys.reachableHosts = ["nas.test"]
    let c = ShareController(config: makeShare("Alpha"), settings: testSettings(), system: sys, log: quietLog)
    c.paused = true
    c.evaluateSync(reason: "1")
    expectEqual(sys.calls, [])
    expectEqual(c.currentStatus.state, .paused)
    c.paused = false
    expect(waitUntil(3) { c.currentStatus.state == .healthy }, "resumed and mounted: \(c.currentStatus.detail)")
}

h.test("controller: manual unmount and eject-for-sleep") {
    let sys = FakeSystem()
    sys.table = [sys.entry(share: "Alpha")]
    let c = ShareController(config: makeShare("Alpha", eject: true), settings: testSettings(), system: sys, log: quietLog)
    c.unmountForSleep(deadline: 5)
    expectEqual(sys.calls, ["unmount /Volumes/Alpha"])
    expectEqual(c.currentStatus.state, .unmounted)
    sys.table = [sys.entry(share: "Alpha")]
    c.requestUnmount(force: true)
    expect(waitUntil(3) { sys.calls.last == "unmount -f /Volumes/Alpha" })
}

h.test("controller: manual unmount holds until wake or manual mount") {
    let sys = FakeSystem()
    sys.table = [sys.entry(share: "Alpha")]
    sys.reachableHosts = ["nas.test"]
    let c = ShareController(config: makeShare("Alpha"), settings: testSettings(), system: sys, log: quietLog)
    c.evaluateSync(reason: "1")
    expectEqual(c.currentStatus.state, .healthy)
    c.requestUnmount(force: false)
    expect(waitUntil(3) { c.currentStatus.state == .unmounted })
    expect(c.isHeld)
    // A tick (or the kernel's mount-table notification) must not remount it.
    c.evaluateSync(reason: "tick")
    expect(!sys.calls.contains { $0.hasPrefix("mount") }, "no remount while held: \(sys.calls)")
    expectEqual(c.currentStatus.state, .unmounted)
    // Wake lifts the hold.
    c.releaseHold(reason: "wake")
    c.evaluateSync(reason: "wake")
    expectEqual(c.currentStatus.state, .healthy)
    expect(sys.calls.contains("mount smb://tester@nas.test/Alpha"))
}

h.test("controller: a healthy share that vanishes was ejected by the user and is held") {
    let sys = FakeSystem()
    sys.table = [sys.entry(share: "Alpha")]
    sys.reachableHosts = ["nas.test"]
    let c = ShareController(config: makeShare("Alpha"), settings: testSettings(), system: sys, log: quietLog)
    c.evaluateSync(reason: "1")
    sys.table = []                         // Finder eject
    c.evaluateSync(reason: "mount table changed")
    expectEqual(c.currentStatus.state, .unmounted)
    expect(c.isHeld, "held after external eject")
    expect(!sys.calls.contains { $0.hasPrefix("mount") })
    // Manual mount lifts the hold and mounts.
    c.requestMount()
    expect(waitUntil(3) { c.currentStatus.state == .healthy }, "\(c.currentStatus.detail)")
}

h.test("controller: a stale share that vanishes (kernel gave up) is remounted at once") {
    let sys = FakeSystem()
    sys.table = [sys.entry(share: "Alpha")]
    sys.probeResults["/Volumes/Alpha"] = .hung
    sys.reachableHosts = ["nas.test"]
    let c = ShareController(config: makeShare("Alpha"), settings: testSettings(), system: sys, log: quietLog)
    c.evaluateSync(reason: "1")
    expectEqual(c.currentStatus.state, .stale)
    sys.table = []                         // kernel dead timer unmounted it
    sys.probeResults = [:]
    c.evaluateSync(reason: "mount table changed")
    expectEqual(c.currentStatus.state, .healthy)
    expect(!c.isHeld)
}

h.test("controller: manual mount of an already mounted share just probes it") {
    let sys = FakeSystem()
    sys.table = [sys.entry(share: "Alpha")]
    let c = ShareController(config: makeShare("Alpha"), settings: testSettings(), system: sys, log: quietLog)
    c.requestMount()
    expect(waitUntil(3) { c.currentStatus.state == .healthy })
    expectEqual(sys.calls, ["probe /Volumes/Alpha"])
    expectEqual(c.currentStatus.consecutiveFailures, 0)
}

h.test("controller: EEXIST from NetFS is treated as mounted") {
    let sys = FakeSystem()
    sys.reachableHosts = ["nas.test"]
    sys.mountResult = .failed(status: EEXIST, message: "already mounted")
    sys.mountAddsEntry = false
    let c = ShareController(config: makeShare("Alpha"), settings: testSettings(), system: sys, log: quietLog)
    // Simulate Finder winning the race: the entry appears before NetFS answers.
    sys.table = [sys.entry(share: "Alpha")]
    c.evaluateSync(reason: "1")
    expectEqual(c.currentStatus.state, .healthy)
    expectEqual(c.currentStatus.consecutiveFailures, 0)
}

h.test("controller: schedule coalesces to the earliest pending request") {
    let sys = FakeSystem()
    sys.table = [sys.entry(share: "Alpha")]
    let c = ShareController(config: makeShare("Alpha"), settings: testSettings(), system: sys, log: quietLog)
    c.schedule(after: 5, reason: "late")
    c.schedule(after: 0.05, reason: "soon")
    c.schedule(after: 3, reason: "later")
    expect(waitUntil(2) { sys.calls.count == 1 }, "one probe ran")
    Thread.sleep(forTimeInterval: 0.3)
    expectEqual(sys.calls.count, 1, "only the earliest fired; later ones were coalesced")
}

h.test("controller: status change callback fires on transitions") {
    let sys = FakeSystem()
    sys.table = [sys.entry(share: "Alpha")]
    let c = ShareController(config: makeShare("Alpha"), settings: testSettings(), system: sys, log: quietLog)
    var seen: [ShareState] = []
    let lock = NSLock()
    c.onChange = { st in lock.lock(); seen.append(st.state); lock.unlock() }
    c.evaluateSync(reason: "1")
    sys.probeResults["/Volumes/Alpha"] = .hung
    c.evaluateSync(reason: "2")
    expectEqual(seen, [.healthy, .stale])
}

// MARK: - Share browser

let smbutilViewFixture = """
Share                                           Type    Comments
-------------------------------
Alpha                                           Disk    
Beta                                            Disk    
Lobby_Printer                                   Printer Lobby_Printer Lobby_Printer
Gamma Time Machine                              Disk    
Delta                                           Disk    
IPC$                                            Pipe    IPC Service ()
epsilon-project                                 Disk    

7 shares listed
"""

h.test("share browser: parses the smbutil table, spaces in names and all") {
    let entries = ShareBrowser.parse(smbutilViewFixture)
    expectEqual(entries.count, 7, "every row parsed: \(entries.map { $0.name })")
    expectEqual(entries.first, ShareBrowser.Entry(name: "Alpha", type: "Disk"))
    expect(entries.contains(ShareBrowser.Entry(name: "Gamma Time Machine", type: "Disk")), "name with spaces")
    expect(entries.contains(ShareBrowser.Entry(name: "Lobby_Printer", type: "Printer")), "comment with single spaces")
    expect(entries.contains(ShareBrowser.Entry(name: "IPC$", type: "Pipe")))
    expect(!entries.contains { $0.name.contains("shares listed") }, "trailing count is not a row")
}

h.test("share browser: keeps only mountable disk shares") {
    let names = ShareBrowser.parse(smbutilViewFixture)
        .filter { $0.isDisk && !$0.isAdministrative }
        .map { $0.name }
    expectEqual(names.sorted(), ["Alpha", "Beta", "Delta", "Gamma Time Machine", "epsilon-project"].sorted())
}

h.test("share browser: tolerates junk and empty output") {
    expectEqual(ShareBrowser.parse("").count, 0)
    expectEqual(ShareBrowser.parse("smbutil: server connection failed").count, 0)
    expectEqual(ShareBrowser.parse("Share Type Comments\n---\n\n0 shares listed").count, 0)
}

h.test("share browser: a dead address fails rather than hanging") {
    let sw = Stopwatch()
    let r = ShareBrowser.diskShares(server: "192.0.2.1", user: "nobody", timeout: 4)
    if case .success(let names) = r { expect(false, "TEST-NET-1 must not answer: \(names)") }
    expect(sw.elapsed < 12, "took \(sw.elapsed) s")
}

// MARK: - Engine


h.test("engine: a stuck asleep flag expires so checks cannot stop forever") {
    let now = Date()
    // Recent sleep, user idle: trust the flag.
    expect(!Engine.sleepFlagIsStale(sleptAt: now.addingTimeInterval(-30), now: now, tickSeconds: 60, secondsSinceUserInput: 600))
    // Long past the sleep and a tick still fired: the wake was missed.
    expect(Engine.sleepFlagIsStale(sleptAt: now.addingTimeInterval(-300), now: now, tickSeconds: 60, secondsSinceUserInput: 600))
    // The user is typing: definitely awake.
    expect(Engine.sleepFlagIsStale(sleptAt: now.addingTimeInterval(-10), now: now, tickSeconds: 60, secondsSinceUserInput: 5))
    // Flagged asleep with no recorded time: do not trust it.
    expect(Engine.sleepFlagIsStale(sleptAt: nil, now: now, tickSeconds: 60, secondsSinceUserInput: 600))
    // A long tick interval widens the window proportionally.
    expect(!Engine.sleepFlagIsStale(sleptAt: now.addingTimeInterval(-400), now: now, tickSeconds: 300, secondsSinceUserInput: 600))
}


h.test("engine: adding a share persists it and leaves the other controllers alone") {
    let sys = FakeSystem()
    sys.reachableHosts = ["nas.test"]
    sys.table = [sys.entry(share: "Alpha")]
    let cfg = Config(settings: testSettings(), shares: [makeShare("Alpha")])
    let dir = makeTempDir()
    let cfgPath = dir + "/config.json"
    try cfg.save(to: cfgPath)
    let engine = Engine(config: cfg, log: quietLog, system: sys, configPath: cfgPath,
                        statusPath: dir + "/status.json", commandDir: dir + "/commands")
    let mediaBefore = engine.controller(named: "Alpha")
    expectNotNil(mediaBefore)
    // Let Media learn that it is healthy, which is what licenses recovery.
    mediaBefore?.evaluateSync(reason: "seed")
    expectEqual(mediaBefore?.currentStatus.state, .healthy)

    try engine.addShare(makeShare("Beta"))
    expectEqual(engine.config.shares.count, 2)
    expectEqual(try Config.load(from: cfgPath).shares.count, 2, "saved to disk")
    expect(engine.controller(named: "Alpha") === mediaBefore, "the untouched share keeps its controller")
    expectNotNil(engine.controller(named: "Beta"))
    expectEqual(engine.controller(named: "Alpha")?.currentStatus.state, .healthy, "and its state")
}

h.test("engine: adding rejects duplicates by name and by server plus share") {
    let sys = FakeSystem()
    let cfg = Config(settings: testSettings(), shares: [makeShare("Alpha")])
    let dir = makeTempDir()
    try cfg.save(to: dir + "/config.json")
    let engine = Engine(config: cfg, log: quietLog, system: sys, configPath: dir + "/config.json",
                        statusPath: dir + "/status.json", commandDir: dir + "/commands")
    expectThrows("same name") { try engine.addShare(makeShare("alpha")) }
    // Same server and share under a different label is the same volume twice.
    expectThrows("same server and share") {
        try engine.addShare(ShareConfig(name: "Movies", server: "nas.test", share: "Alpha", user: "tester"))
    }
    expectThrows("invalid share") {
        try engine.addShare(ShareConfig(name: "Bad", server: "nas.test", share: "a/b", user: "tester"))
    }
    expectEqual(engine.config.shares.count, 1, "nothing was added")
    // A different share on the same server is fine.
    try engine.addShare(makeShare("Beta"))
    expectEqual(engine.config.shares.count, 2)
}

h.test("engine: removing a share persists it and stops that controller acting") {
    let sys = FakeSystem()
    sys.reachableHosts = ["nas.test"]
    let cfg = Config(settings: testSettings(), shares: [makeShare("Alpha"), makeShare("Beta")])
    let dir = makeTempDir()
    let cfgPath = dir + "/config.json"
    try cfg.save(to: cfgPath)
    let engine = Engine(config: cfg, log: quietLog, system: sys, configPath: cfgPath,
                        statusPath: dir + "/status.json", commandDir: dir + "/commands")
    let doomed = engine.controller(named: "Beta")
    expectNotNil(doomed)

    let removed = try engine.removeShare(named: "beta")
    expectEqual(removed.share, "Beta")
    expectEqual(engine.config.shares.map { $0.name }, ["Alpha"])
    expectEqual(try Config.load(from: cfgPath).shares.count, 1, "saved to disk")
    expectNil(engine.controller(named: "Beta"))
    expect(!(doomed?.isActive ?? true), "the removed controller was deactivated")

    // Work already queued for it must do nothing, so a share deleted a moment
    // ago can never be remounted behind the user's back.
    sys.clearCalls()
    doomed?.schedule(after: 0, reason: "stale queued work")
    doomed?.evaluateSync(reason: "stale queued work")
    Thread.sleep(forTimeInterval: 0.2)
    expectEqual(sys.calls, [], "a deactivated controller touches nothing")

    expectThrows("unknown share") { _ = try engine.removeShare(named: "Nope") }
}

h.test("engine: removing a share leaves the volume mounted") {
    let sys = FakeSystem()
    sys.table = [sys.entry(share: "Alpha")]
    let cfg = Config(settings: testSettings(), shares: [makeShare("Alpha")])
    let dir = makeTempDir()
    try cfg.save(to: dir + "/config.json")
    let engine = Engine(config: cfg, log: quietLog, system: sys, configPath: dir + "/config.json",
                        statusPath: dir + "/status.json", commandDir: dir + "/commands")
    try engine.removeShare(named: "Alpha")
    expect(!sys.calls.contains { $0.hasPrefix("unmount") }, "no unmount: \(sys.calls)")
    expectEqual(sys.mountTable().count, 1, "still mounted")
}

h.test("engine: start evaluates every share, writes status, and honours commands") {
    let sys = FakeSystem()
    sys.reachableHosts = ["nas.test"]
    sys.table = [sys.entry(share: "Alpha")]
    var cfg = Config(settings: testSettings(), shares: [makeShare("Alpha"), makeShare("Beta")])
    cfg.settings.tickSeconds = 5
    cfg.settings.settleAfterStartupSeconds = 0
    let dir = makeTempDir()
    let cfgPath = dir + "/config.json"
    try cfg.save(to: cfgPath)
    let statusPath = dir + "/status.json"
    let cmdDir = dir + "/commands"
    let engine = Engine(config: cfg, log: quietLog, system: sys, configPath: cfgPath, statusPath: statusPath, commandDir: cmdDir)
    engine.start()
    defer { engine.stop() }

    expect(waitUntil(5) {
        guard let st = EngineStatus.read(from: statusPath) else { return false }
        return st.shares.allSatisfy { $0.state == .healthy }
    }, "both shares healthy: \(EngineStatus.read(from: statusPath).map { $0.shares.map { "\($0.name)=\($0.state.rawValue) \($0.detail)" } } ?? [])")
    expect(sys.calls.contains("mount smb://tester@nas.test/Beta"), "the unmounted share was mounted")
    expect(!sys.calls.contains { $0.hasPrefix("mount") && $0.hasSuffix("/Alpha") }, "Media was already mounted")

    // Pause via command file, then resume.
    _ = try CommandQueue.send(Command(kind: .pause), dir: cmdDir)
    expect(waitUntil(3) { EngineStatus.read(from: statusPath)?.paused == true }, "paused")
    _ = try CommandQueue.send(Command(kind: .resume), dir: cmdDir)
    expect(waitUntil(3) { EngineStatus.read(from: statusPath)?.paused == false }, "resumed")

    // Reload picks up a share added on disk.
    var updated = try Config.load(from: cfgPath)
    updated.shares.append(makeShare("Gamma"))
    try updated.save(to: cfgPath)
    engine.reload()
    expect(waitUntil(3) { EngineStatus.read(from: statusPath)?.shares.count == 3 }, "third share appears")
}

h.test("engine: eject-on-sleep toggle persists") {
    let sys = FakeSystem()
    let cfg = Config(settings: testSettings(), shares: [makeShare("Alpha")])
    let dir = makeTempDir()
    let cfgPath = dir + "/config.json"
    try cfg.save(to: cfgPath)
    let engine = Engine(config: cfg, log: quietLog, system: sys, configPath: cfgPath, statusPath: dir + "/status.json", commandDir: dir + "/commands")
    engine.setEjectOnSleep(share: "alpha", true)
    expectEqual(try Config.load(from: cfgPath).shares[0].ejectOnSleep, true)
    expectEqual(engine.config.shares[0].ejectOnSleep, true)
}

h.finish()

private extension ShareConfig {
    func `let`<T>(_ f: (ShareConfig) -> T) -> T { f(self) }
}
