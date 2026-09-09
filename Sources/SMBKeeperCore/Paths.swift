import Foundation

/// Filesystem locations used by SMB Keeper.
///
/// Everything lives under the user's home directory. Set `SMBKEEPER_HOME`
/// to relocate the whole tree (the test runner uses this so it never touches
/// the real configuration).
public enum Paths {
    public static let bundleID = "io.github.smbkeeper"
    public static let launchAgentLabel = bundleID

    public static var root: String {
        if let override = ProcessInfo.processInfo.environment["SMBKEEPER_HOME"], !override.isEmpty {
            return override
        }
        return NSHomeDirectory()
    }

    public static var appSupport: String { root + "/Library/Application Support/SMBKeeper" }
    public static var configFile: String { appSupport + "/config.json" }
    public static var statusFile: String { appSupport + "/status.json" }
    public static var commandDir: String { appSupport + "/commands" }
    public static var logDir: String { root + "/Library/Logs/SMBKeeper" }
    public static var logFile: String { logDir + "/smbkeeper.log" }
    public static var launchAgentsDir: String { root + "/Library/LaunchAgents" }
    public static var launchAgentPlist: String { launchAgentsDir + "/\(launchAgentLabel).plist" }

    /// Create every directory the tool writes into. Safe to call repeatedly.
    public static func ensureDirectories() throws {
        let fm = FileManager.default
        for dir in [appSupport, commandDir, logDir, launchAgentsDir] {
            if !fm.fileExists(atPath: dir) {
                try fm.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
        }
    }
}
