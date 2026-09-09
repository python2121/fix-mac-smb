import Foundation
import os

public enum LogLevel: Int, Comparable, CustomStringConvertible {
    case debug = 0, info, warn, error

    public static func < (a: LogLevel, b: LogLevel) -> Bool { a.rawValue < b.rawValue }

    public var description: String {
        switch self {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .warn: return "WARN"
        case .error: return "ERROR"
        }
    }

    public init?(name: String) {
        switch name.lowercased() {
        case "debug": self = .debug
        case "info": self = .info
        case "warn", "warning": self = .warn
        case "error": self = .error
        default: return nil
        }
    }
}

public struct LogLine: Equatable {
    public let date: Date
    public let level: LogLevel
    public let tag: String?
    public let message: String

    public var formatted: String {
        let ts = LogFormat.timestamp(date)
        let tagPart = tag.map { "[\($0)] " } ?? ""
        return "\(ts) \(level) \(tagPart)\(message)"
    }
}

enum LogFormat {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func timestamp(_ d: Date) -> String {
        // DateFormatter is not thread-safe before iOS 7 / 10.9; it is now, but copy to be safe.
        return formatter.string(from: d)
    }
}

/// Thread-safe logger writing to a rotating file, the unified log, an in-memory
/// ring buffer (for the menu bar app), and optionally stderr.
public final class Log {
    public static let shared = Log()

    private let lock = NSLock()
    private var handle: FileHandle?
    private var filePath: String?
    private var currentSize: UInt64 = 0
    private var ring: [LogLine] = []
    private var listeners: [(LogLine) -> Void] = []
    private let osLog = Logger(subsystem: Paths.bundleID, category: "engine")

    public var minLevel: LogLevel = .info
    public var echoToStderr = false
    public var maxFileBytes: UInt64 = 5 * 1024 * 1024
    public var keepRotations = 3
    public var ringCapacity = 500

    public init() {}

    /// Direct output to a file. Creates parent directories.
    public func configure(filePath: String?, echoToStderr: Bool, minLevel: LogLevel) throws {
        lock.lock(); defer { lock.unlock() }
        self.echoToStderr = echoToStderr
        self.minLevel = minLevel
        handle?.closeFile()
        handle = nil
        self.filePath = filePath
        if let filePath = filePath {
            try openFileLocked(filePath)
        }
    }

    private func openFileLocked(_ path: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: path) {
            fm.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let h = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        currentSize = h.seekToEndOfFile()
        handle = h
    }

    private func rotateLocked() {
        guard let path = filePath else { return }
        handle?.closeFile()
        handle = nil
        let fm = FileManager.default
        // smbkeeper.log.3 is dropped, .2 -> .3, .1 -> .2, .log -> .1
        for i in stride(from: keepRotations, through: 1, by: -1) {
            let dst = "\(path).\(i)"
            let src = i == 1 ? path : "\(path).\(i - 1)"
            try? fm.removeItem(atPath: dst)
            if fm.fileExists(atPath: src) { try? fm.moveItem(atPath: src, toPath: dst) }
        }
        try? openFileLocked(path)
    }

    public func addListener(_ l: @escaping (LogLine) -> Void) {
        lock.lock(); defer { lock.unlock() }
        listeners.append(l)
    }

    public func recent(_ n: Int = 200) -> [LogLine] {
        lock.lock(); defer { lock.unlock() }
        return Array(ring.suffix(n))
    }

    public func log(_ level: LogLevel, tag: String? = nil, _ message: String) {
        let line = LogLine(date: Date(), level: level, tag: tag, message: message)
        var toNotify: [(LogLine) -> Void] = []
        lock.lock()
        if level >= minLevel {
            let text = line.formatted + "\n"
            if let h = handle, let data = text.data(using: .utf8) {
                h.write(data)
                currentSize += UInt64(data.count)
                if currentSize > maxFileBytes { rotateLocked() }
            }
            if echoToStderr { FileHandle.standardError.write(text.data(using: .utf8) ?? Data()) }
            ring.append(line)
            if ring.count > ringCapacity { ring.removeFirst(ring.count - ringCapacity) }
            toNotify = listeners
        }
        lock.unlock()

        let osMessage = (tag.map { "[\($0)] " } ?? "") + message
        switch level {
        case .debug: osLog.debug("\(osMessage, privacy: .public)")
        case .info: osLog.info("\(osMessage, privacy: .public)")
        case .warn: osLog.warning("\(osMessage, privacy: .public)")
        case .error: osLog.error("\(osMessage, privacy: .public)")
        }
        for l in toNotify { l(line) }
    }

    public func debug(_ tag: String? = nil, _ m: String) { log(.debug, tag: tag, m) }
    public func info(_ tag: String? = nil, _ m: String) { log(.info, tag: tag, m) }
    public func warn(_ tag: String? = nil, _ m: String) { log(.warn, tag: tag, m) }
    public func error(_ tag: String? = nil, _ m: String) { log(.error, tag: tag, m) }
}
