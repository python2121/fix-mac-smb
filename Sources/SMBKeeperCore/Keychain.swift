import Foundation

/// Credential storage compatible with what Finder writes.
///
/// Finder saves a share password as an Internet Password item with protocol
/// `smb ` whose access list trusts NetAuthAgent. Any item shaped the same way
/// is picked up silently by `NetFSMountURLAsync` with the NoUI option, so this
/// tool never needs to read the secret itself.
public enum Keychain {
    static let netAuthAgent = "/System/Library/CoreServices/NetAuthAgent.app"
    static let netAuthSysAgent = "/System/Library/CoreServices/NetAuthAgent.app/Contents/MacOS/NetAuthSysAgent"
    static let security = "/usr/bin/security"

    /// Whether an SMB password item exists for the server (and account, if given).
    /// This does not read the secret, so it never prompts.
    public static func hasCredential(server: String, account: String?) -> Bool {
        var args = ["find-internet-password", "-s", server, "-r", "smb "]
        if let a = account, !a.isEmpty { args += ["-a", a] }
        let r = Subprocess.run(security, args, timeout: 10)
        return r.succeeded
    }

    private static var storeArguments: [String] {
        ["add-internet-password", "-r", "smb ", "-D", "Network Password",
         "-T", netAuthAgent, "-T", netAuthSysAgent, "-U", "-w"]
    }

    /// Store (or update) a password for `server`/`account`, trusting
    /// NetAuthAgent so mounts authenticate without a dialog.
    ///
    /// The secret is never passed as an argument, where any local process
    /// could read it from the process list. `security` is invoked with a bare
    /// `-w`, which makes it prompt, and the prompt is answered on the
    /// terminal this process inherits. Use this from the command line only.
    ///
    /// Returns the exit status of `security`.
    @discardableResult
    public static func storeCredentialInteractively(server: String, account: String) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: security)
        p.arguments = ["add-internet-password", "-a", account, "-s", server, "-l", server] + storeArguments
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// Store a password without a terminal, for the GUI.
    ///
    /// `security` asks for the password and then for a confirmation, and reads
    /// both from standard input, so the secret is written down a pipe rather
    /// than placed in `argv`.
    @discardableResult
    public static func storeCredential(server: String, account: String, password: String) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: security)
        p.arguments = ["add-internet-password", "-a", account, "-s", server, "-l", server] + storeArguments
        let input = Pipe()
        p.standardInput = input
        p.standardOutput = FileHandle.nullDevice
        let err = Pipe()
        p.standardError = err
        do { try p.run() } catch { return -1 }
        // Answer both the prompt and its confirmation.
        if let data = "\(password)\n\(password)\n".data(using: .utf8) {
            input.fileHandleForWriting.write(data)
        }
        try? input.fileHandleForWriting.close()
        _ = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// Remove the item written by `storeCredential`.
    @discardableResult
    public static func deleteCredential(server: String, account: String) -> Int32 {
        let r = Subprocess.run(security, ["delete-internet-password", "-a", account, "-s", server, "-r", "smb "], timeout: 10)
        return r.status ?? -1
    }
}
