import Foundation

/// Installs the per-user launchd agent that starts the app at login and
/// restarts it if it exits.
public enum LaunchAgent {
    public static func plist(program: String, arguments: [String]) -> String {
        var args = [program] + arguments
        args = args.map { $0.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;") }
        let argXML = args.map { "\t\t<string>\($0)</string>" }.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>Label</key>
        \t<string>\(Paths.launchAgentLabel)</string>
        \t<key>ProgramArguments</key>
        \t<array>
        \(argXML)
        \t</array>
        \t<key>RunAtLoad</key>
        \t<true/>
        \t<key>KeepAlive</key>
        \t<true/>
        \t<key>ThrottleInterval</key>
        \t<integer>10</integer>
        \t<key>ProcessType</key>
        \t<string>Interactive</string>
        \t<key>LimitLoadToSessionType</key>
        \t<string>Aqua</string>
        \t<key>StandardOutPath</key>
        \t<string>\(Paths.logDir)/launchd.out.log</string>
        \t<key>StandardErrorPath</key>
        \t<string>\(Paths.logDir)/launchd.err.log</string>
        </dict>
        </plist>

        """
    }

    public static var domain: String { "gui/\(getuid())" }

    /// Write the plist and (re)load it. `program` must be an absolute path.
    public static func install(program: String, arguments: [String]) throws -> String {
        try Paths.ensureDirectories()
        let path = Paths.launchAgentPlist
        let target = "\(domain)/\(Paths.launchAgentLabel)"
        _ = Subprocess.run("/bin/launchctl", ["bootout", target], timeout: 15)
        // launchd tears the old job down asynchronously; bootstrapping before
        // it is gone fails with EIO. Wait for it to vanish.
        for _ in 0..<50 {
            let p = Subprocess.run("/bin/launchctl", ["print", target], timeout: 10)
            if !p.succeeded { break }
            Thread.sleep(forTimeInterval: 0.2)
        }
        try plist(program: program, arguments: arguments).write(toFile: path, atomically: true, encoding: .utf8)
        var last = ""
        for attempt in 0..<5 {
            let r = Subprocess.run("/bin/launchctl", ["bootstrap", domain, path], timeout: 15)
            if r.succeeded { return path }
            last = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            Thread.sleep(forTimeInterval: 0.5 * Double(attempt + 1))
        }
        throw NSError(domain: Paths.bundleID, code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "launchctl bootstrap failed: \(last)"])
    }

    public static func uninstall() -> Bool {
        let path = Paths.launchAgentPlist
        _ = Subprocess.run("/bin/launchctl", ["bootout", "\(domain)/\(Paths.launchAgentLabel)"], timeout: 15)
        guard FileManager.default.fileExists(atPath: path) else { return false }
        try? FileManager.default.removeItem(atPath: path)
        return true
    }

    public static var isInstalled: Bool { FileManager.default.fileExists(atPath: Paths.launchAgentPlist) }
}
