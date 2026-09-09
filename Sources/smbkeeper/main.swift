import Foundation
import SMBKeeperCore

// MARK: - Argument helpers

struct Args {
    var positional: [String] = []
    var flags: Set<String> = []
    var options: [String: String] = [:]

    init(_ argv: [String]) {
        var i = 0
        while i < argv.count {
            let a = argv[i]
            if a.hasPrefix("--") {
                let body = String(a.dropFirst(2))
                if let eq = body.firstIndex(of: "=") {
                    options[String(body[..<eq])] = String(body[body.index(after: eq)...])
                } else if i + 1 < argv.count, !argv[i + 1].hasPrefix("--"), Args.takesValue(body) {
                    options[body] = argv[i + 1]
                    i += 1
                } else {
                    flags.insert(body)
                }
            } else {
                positional.append(a)
            }
            i += 1
        }
    }

    static let valued: Set<String> = ["server", "share", "user", "name", "mount-point", "n", "app", "program", "log-level"]
    static func takesValue(_ name: String) -> Bool { valued.contains(name) }
    func has(_ f: String) -> Bool { flags.contains(f) }
    subscript(_ o: String) -> String? { options[o] }
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(("error: " + message + "\n").data(using: .utf8)!)
    exit(code)
}

func print(_ s: String, to: inout FileHandle) { to.write((s + "\n").data(using: .utf8)!) }

let usage = """
smbkeeper - keep SMB network volumes mounted and healthy

usage: smbkeeper <command> [options]

setup
  add --server <host> --share <name> [--user <u>] [--name <id>]
      [--mount-point <path>] [--eject-on-sleep] [--no-keychain]
                       Add a share and store its password (prompts).
  remove <name>        Remove a share from the configuration.
  list                 Show configured shares.
  shares <server> [--user <u>]
                       Ask a server which shares it exports.
  set <name> eject-on-sleep on|off
  config               Print the configuration file path and contents.

running
  daemon [--verbose]   Run the engine in the foreground (what launchd runs).
  install-agent [--app <path-to-SMB Keeper.app>]
                       Start at login via launchd (CLI daemon, or the app).
  uninstall-agent
  status [--json]      Show what the running daemon sees.
  log [--n <lines>] [--follow]

acting on the daemon
  check [name]         Re-check now.
  mount [name]         Mount now (all shares when no name).
  unmount [name] [--force]
  pause | resume
  reload               Re-read config.json.

one-shot (no daemon needed)
  probe [name]         Check once now, without a daemon, and print the result.
  doctor               Diagnose mounts, reachability, keychain, and system knobs.
  keychain <name>      Store the password for a configured share (prompts).

"""

let argv = Array(CommandLine.arguments.dropFirst())
guard let command = argv.first else {
    print(usage)
    exit(2)
}
let args = Args(Array(argv.dropFirst()))
var stderr = FileHandle.standardError

func loadConfig() -> Config {
    do { return try Config.load() } catch { fail("\(error)") }
}

func loadConfigOrEmpty() -> Config {
    do { return try Config.loadOrEmpty() } catch { fail("\(error)") }
}

func send(_ cmd: Command) {
    do {
        _ = try CommandQueue.send(cmd)
    } catch {
        fail("could not queue command: \(error)")
    }
    if let st = EngineStatus.read(), st.daemonAlive {
        print("sent \(cmd.kind.rawValue)\(cmd.share.map { " \($0)" } ?? "") to daemon (pid \(st.pid))")
    } else {
        print("queued \(cmd.kind.rawValue); no daemon is running, it will run when one starts (or use `smbkeeper probe`)")
    }
}

func setupLog(verbose: Bool, level: String) {
    do {
        try Paths.ensureDirectories()
        try Log.shared.configure(filePath: Paths.logFile, echoToStderr: verbose, minLevel: LogLevel(name: level) ?? .info)
    } catch {
        fail("cannot open log: \(error)")
    }
}

func formatStatus(_ s: EngineStatus) -> String {
    let df = DateFormatter()
    df.dateFormat = "HH:mm:ss"
    var lines: [String] = []
    let alive = s.daemonAlive ? "running" : "NOT RUNNING (stale status)"
    lines.append("daemon pid \(s.pid) \(alive)\(s.paused ? ", paused" : "")\(s.asleep ? ", asleep" : ""), updated \(df.string(from: s.updatedAt))")
    let nameWidth = max(6, s.shares.map { $0.name.count }.max() ?? 6)
    for sh in s.shares {
        let name = sh.name.padding(toLength: nameWidth, withPad: " ", startingAt: 0)
        var extra: [String] = []
        if let l = sh.lastHealthyAt { extra.append("last ok \(df.string(from: l))") }
        if sh.consecutiveFailures > 0 { extra.append("failures \(sh.consecutiveFailures)") }
        if let n = sh.nextAttemptAt, n > Date() { extra.append("retry \(df.string(from: n))") }
        let tail = extra.isEmpty ? "" : "  (" + extra.joined(separator: ", ") + ")"
        lines.append("  \(name)  \(sh.state.rawValue.padding(toLength: 11, withPad: " ", startingAt: 0))  \(sh.detail)\(tail)")
    }
    return lines.joined(separator: "\n")
}

switch command {
case "help", "--help", "-h":
    print(usage)

case "add":
    guard let server = args["server"], let share = args["share"] else {
        fail("add requires --server and --share")
    }
    var config = loadConfigOrEmpty()
    let user = args["user"]
    let name = args["name"] ?? share
    if config.share(named: name) != nil { fail("a share named '\(name)' already exists; remove it first") }
    let entry = ShareConfig(name: name, server: server, share: share, user: user,
                            mountPoint: args["mount-point"], enabled: true, ejectOnSleep: args.has("eject-on-sleep"))
    config.shares.append(entry)
    do {
        try Paths.ensureDirectories()
        try config.save()
    } catch { fail("\(error)") }
    print("added \(name): smb://\(user.map { "\($0)@" } ?? "")\(server)/\(share)")
    if !args.has("no-keychain") {
        guard let account = user else {
            print("no --user given; skipping keychain (NetAuthAgent will use an existing keychain item for \(server) if one exists)")
            break
        }
        if Keychain.hasCredential(server: server, account: account) {
            print("keychain already has a password for \(account)@\(server)")
        } else {
            print("storing password for \(account)@\(server) in the login keychain (trusted for NetAuthAgent)")
            let rc = Keychain.storeCredentialInteractively(server: server, account: account)
            if rc != 0 { fail("security exited with \(rc); password not stored", code: rc) }
            print("stored")
        }
    }
    if let st = EngineStatus.read(), st.daemonAlive { send(Command(kind: .reload)) }

case "shares":
    guard let server = args.positional.first else { fail("shares requires a server name") }
    let user = args["user"] ?? (try? Config.loadOrEmpty())?.shares.first(where: { $0.server.caseInsensitiveCompare(server) == .orderedSame })?.user
    switch ShareBrowser.diskShares(server: server, user: user, timeout: 20) {
    case .success(let names):
        if names.isEmpty { print("\(server) exports no mountable disk shares") }
        for n in names { print("  \(n)") }
    case .failure(let e):
        fail("\(e.description)")
    }

case "keychain":
    guard let name = args.positional.first else { fail("keychain requires a share name") }
    let config = loadConfig()
    guard let s = config.share(named: name) else { fail("no share named '\(name)'") }
    guard let account = s.user ?? args["user"] else { fail("share '\(name)' has no user; pass --user") }
    let rc = Keychain.storeCredentialInteractively(server: s.server, account: account)
    if rc != 0 { fail("security exited with \(rc)", code: rc) }
    print("stored password for \(account)@\(s.server)")

case "remove":
    guard let name = args.positional.first else { fail("remove requires a share name") }
    var config = loadConfig()
    guard let idx = config.shares.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { fail("no share named '\(name)'") }
    config.shares.remove(at: idx)
    do { try config.save() } catch { fail("\(error)") }
    print("removed \(name)")
    if let st = EngineStatus.read(), st.daemonAlive { send(Command(kind: .reload)) }

case "list":
    let config = loadConfigOrEmpty()
    if config.shares.isEmpty { print("no shares configured"); break }
    for s in config.shares {
        let flags = [s.enabled ? nil : "disabled", s.ejectOnSleep ? "eject-on-sleep" : nil].compactMap { $0 }
        print("  \(s.name): smb://\(s.user.map { "\($0)@" } ?? "")\(s.server)/\(s.share) -> \(s.expectedMountPoint)\(flags.isEmpty ? "" : "  [" + flags.joined(separator: ", ") + "]")")
    }

case "set":
    guard args.positional.count == 3, args.positional[1] == "eject-on-sleep" else { fail("usage: set <name> eject-on-sleep on|off") }
    let on: Bool
    switch args.positional[2].lowercased() {
    case "on", "true", "yes", "1": on = true
    case "off", "false", "no", "0": on = false
    default: fail("expected on or off")
    }
    var config = loadConfig()
    guard let idx = config.shares.firstIndex(where: { $0.name.caseInsensitiveCompare(args.positional[0]) == .orderedSame }) else { fail("no share named '\(args.positional[0])'") }
    config.shares[idx].ejectOnSleep = on
    do { try config.save() } catch { fail("\(error)") }
    print("\(config.shares[idx].name): eject-on-sleep \(on ? "on" : "off")")
    if let st = EngineStatus.read(), st.daemonAlive { send(Command(kind: .reload)) }

case "config":
    print(Paths.configFile)
    if let text = try? String(contentsOfFile: Paths.configFile, encoding: .utf8) { print(text) } else { print("(no configuration file yet)") }

case "daemon":
    let config = loadConfig()
    setupLog(verbose: args.has("verbose"), level: args["log-level"] ?? config.settings.logLevel)
    if let st = EngineStatus.read(), st.daemonAlive, st.pid != getpid() {
        fail("another daemon is already running (pid \(st.pid))")
    }
    let engine = Engine(config: config, log: Log.shared)
    engine.start()
    signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
    let sigQueue = DispatchQueue(label: "signals")
    let sources = [SIGINT, SIGTERM].map { sig -> DispatchSourceSignal in
        let s = DispatchSource.makeSignalSource(signal: sig, queue: sigQueue)
        s.setEventHandler { engine.stop(); exit(0) }
        s.resume()
        return s
    }
    _ = sources
    RunLoop.main.run()

case "install-agent":
    let program: String
    let arguments: [String]
    if let app = args["app"] {
        let exe = app + "/Contents/MacOS/SMBKeeperApp"
        guard FileManager.default.isExecutableFile(atPath: exe) else { fail("no executable at \(exe)") }
        program = exe
        arguments = []
    } else {
        program = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath().path
        arguments = ["daemon"]
    }
    _ = loadConfig()
    do {
        let path = try LaunchAgent.install(program: program, arguments: arguments)
        print("installed \(path)\n  runs: \(program) \(arguments.joined(separator: " "))")
        if let pid = LaunchAgent.loadedPID() { print("  running as pid \(pid)") }
    } catch { fail("\(error.localizedDescription)") }

case "uninstall-agent":
    print(LaunchAgent.uninstall() ? "launch agent removed" : "no launch agent was installed")

case "status":
    guard let st = EngineStatus.read() else { fail("no status yet; is the daemon running? (`smbkeeper install-agent` or `smbkeeper daemon`)") }
    if args.has("json") {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try! enc.encode(st), as: UTF8.self))
    } else {
        print(formatStatus(st))
    }

case "log":
    let n = Int(args["n"] ?? "40") ?? 40
    guard FileManager.default.fileExists(atPath: Paths.logFile) else { fail("no log at \(Paths.logFile)") }
    let tailArgs = args.has("follow") ? ["-n", String(n), "-F", Paths.logFile] : ["-n", String(n), Paths.logFile]
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
    p.arguments = tailArgs
    try? p.run()
    p.waitUntilExit()

case "check":
    send(Command(kind: .evaluate, share: args.positional.first))
case "mount":
    send(Command(kind: .mount, share: args.positional.first))
case "unmount":
    send(Command(kind: args.has("force") ? .forceUnmount : .unmount, share: args.positional.first))
case "pause":
    send(Command(kind: .pause))
case "resume":
    send(Command(kind: .resume))
case "reload":
    send(Command(kind: .reload))

case "probe":
    let config = loadConfig()
    setupLog(verbose: true, level: args["log-level"] ?? "info")
    let system = LiveSystem(log: Log.shared)
    let targets = args.positional.first.map { n in config.shares.filter { $0.name.caseInsensitiveCompare(n) == .orderedSame } } ?? config.shares
    if targets.isEmpty { fail("no matching share") }
    for share in targets {
        let c = ShareController(config: share, settings: config.settings, system: system, log: Log.shared)
        c.evaluateSync(reason: "probe command")
        let s = c.currentStatus
        print("\(s.name): \(s.state.rawValue) - \(s.detail)")
    }

case "doctor":
    let config = try? Config.load()
    for line in Doctor.run(config: config) {
        let mark: String
        switch line.ok {
        case .some(true): mark = "ok  "
        case .some(false): mark = "WARN"
        case .none: mark = "    "
        }
        print("\(mark) \(line.text)")
    }

default:
    fail("unknown command '\(command)'\n\n" + usage, code: 2)
}
