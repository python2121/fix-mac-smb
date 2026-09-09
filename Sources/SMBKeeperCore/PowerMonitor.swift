import Foundation
import IOKit
import IOKit.pwr_mgt
import AppKit
import CoreGraphics

public enum PowerEvent {
    case willSleep
    case didWake
}

/// System sleep/wake notifications from IOKit, with NSWorkspace as a second
/// opinion. IOKit's `kIOMessageSystemHasPoweredOn` is not delivered for dark
/// wakes (Power Nap), which is what we want: a remount during a dark wake would
/// only die again seconds later.
///
/// The `willSleep` handler runs synchronously on the monitor's thread and must
/// return quickly; IOKit gives about 30 seconds before it proceeds regardless.
public final class PowerMonitor {
    // iokit_common_msg(x) = sys_iokit (0xE0000000) | sub_iokit_common (0) | x.
    // The macros do not import into Swift, so the values are spelled out.
    static let sysIOKit: UInt32 = 0xE000_0000
    static let canSystemSleep = sysIOKit | 0x270
    static let systemWillSleep = sysIOKit | 0x280
    static let systemWillNotSleep = sysIOKit | 0x290
    static let systemHasPoweredOn = sysIOKit | 0x300
    static let systemWillPowerOn = sysIOKit | 0x320

    private let handler: (PowerEvent) -> Void
    private let log: Log
    private var rootPort: io_connect_t = 0
    private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var workspaceObservers: [NSObjectProtocol] = []

    public init(log: Log, handler: @escaping (PowerEvent) -> Void) {
        self.log = log
        self.handler = handler
    }

    public func start() {
        let t = Thread { [self] in
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            var port: IONotificationPortRef?
            var notifierObj: io_object_t = 0
            let callback: IOServiceInterestCallback = { refcon, _, messageType, argument in
                guard let refcon = refcon else { return }
                let monitor = Unmanaged<PowerMonitor>.fromOpaque(refcon).takeUnretainedValue()
                monitor.handle(messageType: messageType, argument: argument)
            }
            let root = IORegisterForSystemPower(refcon, &port, callback, &notifierObj)
            if root == 0 || port == nil {
                log.error("power", "IORegisterForSystemPower failed; sleep/wake detection via NSWorkspace only")
                return
            }
            rootPort = root
            notifyPort = port
            notifier = notifierObj
            runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .defaultMode)
            log.debug("power", "IOKit power notifications registered")
            CFRunLoopRun()
        }
        t.name = "power-monitor"
        t.start()
        thread = t

        let nc = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.log.debug("power", "NSWorkspace didWake")
            self?.handler(.didWake)
        })
        workspaceObservers.append(nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [weak self] _ in
            self?.log.debug("power", "NSWorkspace willSleep")
            self?.handler(.willSleep)
        })
    }

    public func stop() {
        for o in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        workspaceObservers.removeAll()
        if let rl = runLoop { CFRunLoopStop(rl) }
        if notifier != 0 { IODeregisterForSystemPower(&notifier) }
        if rootPort != 0 { IOServiceClose(rootPort) }
        if let p = notifyPort { IONotificationPortDestroy(p) }
        notifier = 0; rootPort = 0; notifyPort = nil
    }

    private func handle(messageType: UInt32, argument: UnsafeMutableRawPointer?) {
        let ack = Int(bitPattern: argument)
        switch messageType {
        case PowerMonitor.canSystemSleep:
            IOAllowPowerChange(rootPort, ack)
        case PowerMonitor.systemWillSleep:
            log.info("power", "system will sleep")
            handler(.willSleep)
            IOAllowPowerChange(rootPort, ack)
        case PowerMonitor.systemHasPoweredOn:
            log.info("power", "system has powered on")
            handler(.didWake)
        case PowerMonitor.systemWillPowerOn:
            log.debug("power", "system will power on")
        case PowerMonitor.systemWillNotSleep:
            log.debug("power", "sleep cancelled")
            handler(.didWake)
        default:
            break
        }
    }

    /// Seconds since the last keyboard, mouse, or trackpad event in this session.
    /// Used as a safety valve: if this is small, the user is present and any
    /// stale "asleep" flag is wrong.
    public static func secondsSinceUserInput() -> Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }
}
