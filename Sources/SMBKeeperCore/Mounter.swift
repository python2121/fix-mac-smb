import Foundation
import NetFS

public enum MountResult: Equatable {
    case mounted(paths: [String])
    case failed(status: Int32, message: String)
    case timedOut

    public var description: String {
        switch self {
        case .mounted(let p): return "mounted at \(p.joined(separator: ", "))"
        case .failed(let s, let m): return "failed (\(s)): \(m)"
        case .timedOut: return "mount timed out"
        }
    }
}

public enum Mounter {
    /// Only one NetFS mount runs at a time process-wide. Mounting two shares from
    /// the same server concurrently has been reported to panic recent kernels.
    private static let serial = DispatchSemaphore(value: 1)

    /// The queue handed to `NetFSMountURLAsync` must outlive the request.
    /// NetAuth does not retain it: passing a freshly created queue as the
    /// argument expression lets it be released as soon as the call returns,
    /// and NetAuth then crashes in `__NAConnectToServerStart_block_invoke`
    /// when it tries to dispatch the reply. Observed as EXC_BAD_ACCESS on
    /// macOS 27 beta. Keeping one static queue for the process avoids it.
    private static let queue = DispatchQueue(label: Paths.bundleID + ".netfs")

    /// Human-readable text for a NetFSMountURLAsync status.
    public static func describe(status: Int32) -> String {
        switch status {
        case 0: return "ok"
        case -128: return "cancelled"
        case -5998: return "no shares available"
        case -6600: return "NetAuth internal error (check option types)"
        case -6602: return "NetAuth mount failed"
        case -6003: return "server not found"
        case 2: return "mount point does not exist"
        case 13: return "permission denied (authentication?)"
        case 17: return "already mounted"
        case 22: return "invalid argument"
        case 60: return "operation timed out"
        case 64: return "host is down"
        case 65: return "no route to host"
        case 61: return "connection refused"
        default:
            if status > 0 { return String(cString: strerror(status)) }
            return "OSStatus \(status)"
        }
    }

    /// Mount `url` through NetFS, the same path Finder uses, so the login
    /// keychain supplies the password. With `allowUI` false the call fails
    /// silently rather than prompting. The mount is always soft.
    public static func mount(url: URL, mountPoint: String?, allowUI: Bool, timeout: Double) -> MountResult {
        serial.wait()
        defer { serial.signal() }

        let open = NSMutableDictionary()
        open[kNAUIOptionKey as String] = allowUI ? (kNAUIOptionAllowUI as String) : (kNAUIOptionNoUI as String)
        let mountOpts = NSMutableDictionary()
        mountOpts[kNetFSSoftMountKey as String] = true
        var mountPath: CFURL?
        if let mp = mountPoint {
            mountOpts[kNetFSMountAtMountDirKey as String] = true
            mountPath = URL(fileURLWithPath: mp) as CFURL
        }

        final class State {
            let lock = NSLock()
            var finished = false
            var result: MountResult?
        }
        let state = State()
        let done = DispatchSemaphore(value: 0)
        var requestID: AsyncRequestID? = nil

        let rc = NetFSMountURLAsync(url as CFURL, mountPath, nil, nil, open, mountOpts, &requestID, queue) { status, _, mountpoints in
            state.lock.lock()
            defer { state.lock.unlock() }
            if state.finished { return }
            state.finished = true
            if status == 0 {
                let paths = (mountpoints as? [String]) ?? []
                state.result = .mounted(paths: paths)
            } else {
                state.result = .failed(status: status, message: describe(status: status))
            }
            done.signal()
        }
        if rc != 0 {
            return .failed(status: rc, message: describe(status: rc))
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            state.lock.lock()
            let alreadyDone = state.finished
            state.finished = true
            state.lock.unlock()
            if !alreadyDone {
                if let id = requestID { _ = NetFSMountURLCancel(id) }
                return .timedOut
            }
        }
        state.lock.lock()
        let r = state.result ?? .timedOut
        state.lock.unlock()
        return r
    }
}
