import Foundation
import notify

/// Thin wrapper over Darwin notifications (`notify(3)`).
public final class DarwinNotification {
    private var token: Int32 = NOTIFY_TOKEN_INVALID
    private let queue: DispatchQueue

    public init(name: String, queue: DispatchQueue, handler: @escaping () -> Void) {
        self.queue = queue
        var t: Int32 = 0
        let rc = notify_register_dispatch(name, &t, queue) { _ in handler() }
        if rc == NOTIFY_STATUS_OK { token = t }
    }

    deinit {
        if token != NOTIFY_TOKEN_INVALID { notify_cancel(token) }
    }

    /// Kernel-posted names for mount table changes.
    public static let vfsMount = "com.apple.system.kernel.mount"
    public static let vfsUnmount = "com.apple.system.kernel.unmount"
}
