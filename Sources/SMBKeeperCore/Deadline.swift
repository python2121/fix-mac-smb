import Foundation

/// Run blocking work on a dedicated thread and give up waiting after a deadline.
///
/// A filesystem call on a dead SMB mount blocks inside the kernel and cannot be
/// interrupted, so the only defence is to never make such a call on a thread we
/// need back. Each call gets its own `Thread` rather than a GCD worker, because
/// GCD's pool is finite and a handful of stuck workers would starve the process.
/// A timed-out thread is simply abandoned; it exits on its own when the kernel
/// eventually returns.
public enum Deadline {
    private final class Box<T> {
        private let lock = NSLock()
        private var value: T?
        func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
        func get() -> T? { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// Returns the work's result, or nil if it did not finish within `seconds`.
    public static func run<T>(seconds: Double, name: String, _ work: @escaping () -> T) -> T? {
        let box = Box<T>()
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            box.set(work())
            done.signal()
        }
        thread.name = "deadline." + name
        thread.stackSize = 512 * 1024
        thread.start()
        if done.wait(timeout: .now() + seconds) == .timedOut {
            return nil
        }
        return box.get()
    }
}

/// Monotonic-ish elapsed time helper for latency measurements.
public struct Stopwatch {
    private let start = DispatchTime.now()
    public init() {}
    public var elapsed: Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
    }
}
