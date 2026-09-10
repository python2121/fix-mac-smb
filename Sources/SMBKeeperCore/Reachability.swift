import Foundation
import Network

/// A parsed Bonjour service instance such as `fileserver._smb._tcp.local`.
public struct BonjourService: Equatable {
    public let name: String
    public let type: String
    public let domain: String

    public init(name: String, type: String, domain: String) {
        self.name = name
        self.type = type
        self.domain = domain
    }

    /// Recognises `<instance>._<service>._tcp[.<domain>][.]`. Returns nil for
    /// ordinary host names and IP addresses.
    public static func parse(_ host: String) -> BonjourService? {
        var h = host
        if h.hasSuffix(".") { h.removeLast() }
        // Labels look like ["NAS", "_smb", "_tcp", "local"]; the type is the
        // "_service._tcp" pair, the instance is everything before it.
        let labels = h.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard labels.count >= 3 else { return nil }
        guard let protoIdx = labels.lastIndex(where: { $0 == "_tcp" || $0 == "_udp" }), protoIdx >= 2 else { return nil }
        let typeLabel = labels[protoIdx - 1]
        guard typeLabel.hasPrefix("_") else { return nil }
        let name = labels[0..<(protoIdx - 1)].joined(separator: ".")
        guard !name.isEmpty else { return nil }
        let domainLabels = labels[(protoIdx + 1)...]
        let domain = domainLabels.isEmpty ? "local" : domainLabels.joined(separator: ".")
        return BonjourService(name: name, type: "\(typeLabel).\(labels[protoIdx])", domain: domain)
    }
}

/// Outcome of the TCP gate.
public enum ReachabilityResult: Equatable {
    /// A TCP handshake to the port completed.
    case reachable
    /// Nothing answered before the deadline, or the connection was refused.
    case unreachable(String)
    /// The system refused to even try, which on macOS 15 and later is what
    /// the Local Network privacy setting looks like from inside a denied
    /// process: an immediate "Network is down" or "No route to host" while
    /// the network path is up. The kernel SMB client is not subject to that
    /// setting, so a mount can still succeed.
    case blockedByPolicy(String)

    public var description: String {
        switch self {
        case .reachable: return "reachable"
        case .unreachable(let why): return "not reachable (\(why))"
        case .blockedByPolicy(let why): return "check blocked by system policy (\(why))"
        }
    }
}

public enum Reachability {
    /// Attempt a TCP connection to the SMB port with a deadline. Used as a gate
    /// before mounting so credentials are never offered to a host that is not
    /// answering, and so remounts do not fire before Wi-Fi is back.
    public static func tcpProbe(host: String, port: UInt16 = 445, timeout: Double) -> ReachabilityResult {
        let endpoint: NWEndpoint
        if let svc = BonjourService.parse(host) {
            endpoint = .service(name: svc.name, type: svc.type, domain: svc.domain, interface: nil)
        } else {
            guard let nwPort = NWEndpoint.Port(rawValue: port) else { return .unreachable("bad port") }
            endpoint = .hostPort(host: NWEndpoint.Host(host), port: nwPort)
        }
        let params = NWParameters.tcp
        params.prohibitExpensivePaths = false
        let conn = NWConnection(to: endpoint, using: params)
        let done = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var outcome: ReachabilityResult?
        var lastWait: String?
        let started = Date()
        let queue = DispatchQueue(label: Paths.bundleID + ".reach")
        conn.stateUpdateHandler = { state in
            lock.lock(); defer { lock.unlock() }
            if outcome != nil { return }
            switch state {
            case .ready:
                outcome = .reachable
                done.signal()
            case .failed(let err):
                outcome = classify(err, elapsed: Date().timeIntervalSince(started))
                done.signal()
            case .cancelled:
                outcome = .unreachable("cancelled")
                done.signal()
            case .waiting(let err):
                // No route yet (Wi-Fi still associating) is a legitimate wait;
                // a policy refusal shows up here too, instantly.
                if case .blockedByPolicy = classify(err, elapsed: Date().timeIntervalSince(started)) {
                    outcome = classify(err, elapsed: Date().timeIntervalSince(started))
                    done.signal()
                } else {
                    lastWait = "\(err)"
                }
            default:
                break
            }
        }
        conn.start(queue: queue)
        _ = done.wait(timeout: .now() + timeout)
        lock.lock()
        let result = outcome ?? .unreachable(lastWait.map { "timed out; last state: \($0)" } ?? "timed out")
        if outcome == nil { outcome = result }
        lock.unlock()
        conn.cancel()
        return result
    }

    /// Errors that mean "the system would not let this process try", as opposed
    /// to "the host did not answer". Only trusted when they arrive quickly.
    public static func classify(_ err: NWError, elapsed: Double) -> ReachabilityResult {
        if case .posix(let code) = err {
            switch code {
            case .ENETDOWN, .EHOSTUNREACH, .EPERM, .EACCES:
                if elapsed < 1.5 { return .blockedByPolicy("\(err)") }
                return .unreachable("\(err)")
            default:
                return .unreachable("\(err)")
            }
        }
        return .unreachable("\(err)")
    }

    /// ICMP echo through the system `ping` tool. Used as a second opinion when
    /// the TCP probe was refused by policy, since `ping` is a platform binary
    /// that is not subject to the same gate.
    public static func ping(host: String, timeout: Double) -> Bool {
        let target = BonjourService.parse(host) != nil ? nil : host
        guard let target = target else { return false }
        let ms = Int(max(1, timeout) * 1000)
        let r = Subprocess.run("/sbin/ping", ["-c", "1", "-W", String(ms), "-q", target], timeout: timeout + 2)
        return r.succeeded
    }
}
