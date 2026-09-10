import Foundation

public struct SubprocessResult {
    public let status: Int32?
    public let stdout: String
    public let stderr: String
    public let timedOut: Bool

    public var succeeded: Bool { !timedOut && status == 0 }
}

public enum Subprocess {
    /// Run an executable with a hard deadline. On timeout the process is sent
    /// SIGTERM, then SIGKILL two seconds later. Output is captured
    /// asynchronously so a chatty child cannot deadlock on a full pipe.
    public static func run(_ path: String, _ args: [String], timeout: Double) -> SubprocessResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice

        let lock = NSLock()
        var outData = Data(), errData = Data()
        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            lock.lock(); outData.append(d); lock.unlock()
        }
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            lock.lock(); errData.append(d); lock.unlock()
        }

        do {
            try p.run()
        } catch {
            return SubprocessResult(status: nil, stdout: "", stderr: "failed to launch \(path): \(error)", timedOut: false)
        }

        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            p.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(p.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 2)
            }
        }
        // Drain whatever is left and stop the handlers.
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        let restOut = out.fileHandleForReading.readDataToEndOfFile()
        let restErr = err.fileHandleForReading.readDataToEndOfFile()
        lock.lock()
        outData.append(restOut); errData.append(restErr)
        let o = String(decoding: outData, as: UTF8.self)
        let e = String(decoding: errData, as: UTF8.self)
        lock.unlock()
        let status: Int32? = p.isRunning ? nil : p.terminationStatus
        return SubprocessResult(status: status, stdout: o, stderr: e, timedOut: timedOut)
    }
}
