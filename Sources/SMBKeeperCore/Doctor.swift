import Foundation

/// One-shot diagnostics: what is mounted, whether it answers, whether the
/// servers are reachable, and which system knobs are set the way they are.
public enum Doctor {
    public struct Line {
        public let ok: Bool?
        public let text: String
    }

    public static func run(config: Config?) -> [Line] {
        var out: [Line] = []
        func add(_ ok: Bool?, _ t: String) { out.append(Line(ok: ok, text: t)) }

        let ver = ProcessInfo.processInfo.operatingSystemVersionString
        add(nil, "macOS \(ver)")

        // Mounted SMB volumes and their health.
        let smb = MountTable.smbMounts()
        if smb.isEmpty {
            add(nil, "no smbfs volumes mounted")
        }
        for m in smb {
            let r = Prober.probe(path: m.on, timeout: 8, listing: true)
            add(r.isHealthy, "\(m.on) <- \(m.from): \(r.description)")
            let st = Subprocess.run("/usr/bin/smbutil", ["statshares", "-m", m.on, "-f", "JSON"], timeout: 8)
            if st.succeeded, let data = st.stdout.data(using: .utf8),
               let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], let d = arr.first {
                func field(_ key: String) -> String {
                    guard let v = d[key], !(v is NSNull) else { return "off" }
                    return "\(v)"
                }
                let ver = field("SMB_VERSION")
                let rc = field("SESSION_RECONNECT_COUNT")
                let rt = field("SESSION_RECONNECT_TIME")
                let sign = field("SMB_CURR_SIGN_ALGORITHM")
                let enc = field("SMB_CURR_ENCRYPT_ALGORITHM")
                add(nil, "   \(ver), signing \(sign), encryption \(enc), session reconnects \(rc) (last \(rt))")
            } else if st.timedOut {
                add(false, "   smbutil statshares hung (session is not answering)")
            }
        }

        // Configured shares.
        if let cfg = config {
            for s in cfg.shares {
                let probe = Reachability.tcpProbe(host: s.server, timeout: cfg.settings.reachabilityTimeoutSeconds)
                switch probe {
                case .reachable:
                    add(true, "\(s.name): \(s.server) port 445 reachable")
                case .unreachable(let why):
                    add(false, "\(s.name): \(s.server) port 445 NOT reachable (\(why))")
                case .blockedByPolicy(let why):
                    let pinged = Reachability.ping(host: s.server, timeout: 3)
                    add(pinged ? nil : false, "\(s.name): \(s.server) TCP check refused by the system (\(why)); ping \(pinged ? "answers" : "does not answer"). This terminal or app is probably denied under System Settings > Privacy & Security > Local Network. Mounts still work; the daemon proceeds without the gate.")
                }
                let bonjour = BonjourService.parse(s.server) != nil
                if bonjour || s.server.hasSuffix(".local") {
                    add(false, "   \(s.server) resolves via mDNS/Bonjour; an IP address or DNS name survives sleep better")
                }
                let cred = Keychain.hasCredential(server: s.server, account: s.user)
                add(cred, "   keychain item for \(s.user.map { "\($0)@" } ?? "")\(s.server): \(cred ? "present" : "MISSING (run `smbkeeper add` to store it)")")
                let mounted = smb.first { $0.matches(s) }
                add(mounted != nil, "   \(mounted.map { "mounted at \($0.on)" } ?? "not mounted")")
            }
        } else {
            add(false, "no configuration; run `smbkeeper add --server <ip> --share <name> --user <user>`")
        }

        // System knobs.
        var sawNsmb = false
        for f in ["/etc/nsmb.conf", NSHomeDirectory() + "/Library/Preferences/nsmb.conf"] {
            if let text = try? String(contentsOfFile: f, encoding: .utf8) {
                sawNsmb = true
                let lines = text.split(separator: "\n").filter { !$0.hasPrefix("#") && !$0.isEmpty }
                add(nil, "\(f): \(lines.joined(separator: "; "))")
            }
        }
        if !sawNsmb {
            add(nil, "no nsmb.conf. With the defaults, a dead server keeps a mount hung for up to 10 minutes and even `umount -f` blocks. Adding `soft=yes` under `[default]` in /etc/nsmb.conf cuts that to about a minute (needs sudo, and a remount to take effect).")
        }
        let sys = Subprocess.run("/usr/sbin/sysctl", ["net.smb.fs.kern_deadtimer", "net.smb.fs.kern_soft_deadtimer", "net.smb.fs.kern_hard_deadtimer"], timeout: 5)
        if sys.succeeded {
            add(nil, "kernel dead timers: " + sys.stdout.split(separator: "\n").map { $0.replacingOccurrences(of: "net.smb.fs.", with: "") }.joined(separator: ", "))
        }
        let pm = Subprocess.run("/usr/bin/pmset", ["-g"], timeout: 5)
        if pm.succeeded {
            for key in ["powernap", "tcpkeepalive", "sleep", "standby"] {
                if let line = pm.stdout.split(separator: "\n").first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix(key + " ") }) {
                    let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                    if parts.count >= 2 {
                        let val = String(parts[1])
                        var flag: Bool? = nil
                        if key == "powernap" { flag = val == "0" }
                        add(flag, "pmset \(key) = \(val)" + (key == "powernap" && val != "0" ? " (dark wakes every few minutes churn SMB sessions; consider `sudo pmset -a powernap 0`)" : ""))
                    }
                }
            }
        }
        let agent = FileManager.default.fileExists(atPath: Paths.launchAgentPlist)
        add(agent, "launch agent \(agent ? "installed" : "not installed") (\(Paths.launchAgentPlist))")
        if let st = EngineStatus.read() {
            add(st.daemonAlive, "daemon pid \(st.pid) \(st.daemonAlive ? "running" : "not running"); status updated \(st.updatedAt)")
        } else {
            add(false, "daemon has not written a status file yet")
        }
        return out
    }
}
