import Foundation

/// A command from the CLI to the running daemon. Delivered as a small JSON
/// file in the commands directory plus a Darwin notification, which avoids
/// any XPC or socket plumbing and survives the daemon being restarted.
public struct Command: Codable, Equatable {
    public enum Kind: String, Codable {
        case evaluate       // re-check all shares now
        case mount          // mount one share (or all when `share` is nil)
        case unmount        // unmount one share (or all)
        case forceUnmount
        case pause
        case resume
        case reload         // re-read config.json
    }
    public var kind: Kind
    public var share: String?
    public var argument: String?
    public var issuedAt: Date

    public init(kind: Kind, share: String? = nil, argument: String? = nil) {
        self.kind = kind
        self.share = share
        self.argument = argument
        self.issuedAt = Date()
    }
}

public enum CommandQueue {
    /// Write a command and nudge the daemon. Returns the file written.
    @discardableResult
    public static func send(_ cmd: Command, dir: String = Paths.commandDir) throws -> String {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(cmd)
        let name = String(format: "%.6f-%@.json", Date().timeIntervalSince1970, UUID().uuidString)
        let path = dir + "/" + name
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        DarwinNotification.post(DarwinNotification.command)
        return path
    }

    /// Read and delete every pending command, oldest first. Files older than
    /// ten minutes are discarded so a stale command from before a reboot does
    /// not fire unexpectedly.
    public static func drain(dir: String = Paths.commandDir) -> [Command] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        var out: [Command] = []
        for name in names.sorted() where name.hasSuffix(".json") {
            let path = dir + "/" + name
            defer { try? FileManager.default.removeItem(atPath: path) }
            guard let data = FileManager.default.contents(atPath: path),
                  let cmd = try? dec.decode(Command.self, from: data) else { continue }
            if Date().timeIntervalSince(cmd.issuedAt) > 600 { continue }
            out.append(cmd)
        }
        return out
    }
}
