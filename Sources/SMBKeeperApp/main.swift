import AppKit
import Foundation
import SMBKeeperCore

/// Menu bar front end. The engine runs inside this process, so the app is the
/// daemon: launchd starts it at login and keeps it alive.
///
/// Left-clicking the status item opens the panel; right-clicking gives a plain
/// menu, which is the reliable path if the panel itself ever misbehaves.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var engine: Engine!
    private var store: ShareStore!
    private var panel: PanelController!
    private var refreshTimer: Timer?
    private var lastIconKey = ""
    private var appearanceObserver: NSKeyValueObservation?
    private var addShareWindow: AddShareWindowController?

    // Top-level code is nonisolated, so the delegate has to be constructible
    // from there even though everything else about it is main-actor bound.
    nonisolated override init() { super.init() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        do {
            try Paths.ensureDirectories()
            try Log.shared.configure(filePath: Paths.logFile, echoToStderr: false, minLevel: .info)
        } catch {
            alert("SMB Keeper cannot open its log", "\(error)")
        }

        let config: Config
        do {
            config = try Config.load()
        } catch ConfigError.missing {
            config = Config()
            try? config.save()
            Log.shared.info("app", "no configuration; created an empty one at \(Paths.configFile)")
        } catch {
            alert("SMB Keeper configuration error", "\(error)\n\nFix \(Paths.configFile) and relaunch.")
            NSApp.terminate(nil)
            return
        }
        if let st = EngineStatus.read(), st.daemonAlive, st.pid != getpid() {
            alert("SMB Keeper is already running", "Another instance (pid \(st.pid)) is active. Quit it first.")
            NSApp.terminate(nil)
            return
        }
        if let lvl = LogLevel(name: config.settings.logLevel) { Log.shared.minLevel = lvl }

        engine = Engine(config: config, log: Log.shared)
        store = ShareStore(engine: engine)
        engine.start()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        // The icon is not a template image (its badge is coloured), so rebuild
        // it whenever the menu bar switches between light and dark.
        appearanceObserver = statusItem.button?.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in
                self?.lastIconKey = ""
                self?.refreshIcon()
            }
        }

        panel = PanelController(store: store, statusItem: statusItem, actions: panelActions())

        refreshIcon()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshIcon() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine?.stop()
    }

    private func panelActions() -> PanelActions {
        PanelActions(
            addShare: { [weak self] in self?.showAddShare() },
            removeShare: { [weak self] name in self?.confirmRemove(name) },
            toggleLoginItem: { [weak self] in self?.toggleLoginItem() },
            isLoginItem: { LaunchAgent.isInstalled },
            quit: { NSApp.terminate(nil) }
        )
    }

    // MARK: Status item

    /// Builds the status icon. The drive body always takes the label colour, so
    /// it follows light/dark mode and the menu bar tint like a template image
    /// would; only the badge (the small circle in the corner) is coloured.
    /// SF Symbols draw the badge as palette layer 0 and the drive as layer 1.
    private func symbol(_ name: String, badge: NSColor?) -> NSImage? {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: "SMB Keeper")
            ?? NSImage(systemSymbolName: "externaldrive", accessibilityDescription: "SMB Keeper")
        else { return nil }
        guard let badge else {
            base.isTemplate = true
            return base
        }
        let palette = NSImage.SymbolConfiguration(paletteColors: [badge, .labelColor])
        let img = base.withSymbolConfiguration(palette) ?? base
        img.isTemplate = false
        return img
    }

    /// A system colour pulled part of the way toward the label colour, so the
    /// badge reads as a hint of colour rather than a traffic light. Resolved
    /// per appearance, so it stays right in both light and dark menu bars.
    private static func muted(_ tint: NSColor, by fraction: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            var out = tint
            appearance.performAsCurrentDrawingAppearance {
                let t = tint.usingColorSpace(.sRGB) ?? tint
                let label = NSColor.labelColor.usingColorSpace(.sRGB) ?? .labelColor
                out = t.blended(withFraction: fraction, of: label) ?? t
            }
            return out
        }
    }

    private static let healthyBadge = muted(.systemGreen, by: 0.45)
    private static let troubleBadge = muted(.systemRed, by: 0.15)

    private func refreshIcon() {
        guard let engine = engine, let button = statusItem?.button else { return }
        let st = engine.status
        let states = st.shares.filter { $0.state != .paused }.map { $0.state }
        let name: String
        let badge: NSColor?
        let tip: String
        if engine.paused {
            name = "externaldrive.badge.minus"; badge = .secondaryLabelColor
            tip = "SMB Keeper: paused"
        } else if states.contains(.mounting) || states.contains(.unmounting) {
            name = "externaldrive.badge.timemachine"; badge = .labelColor
            tip = "SMB Keeper: working"
        } else if states.contains(.stale) || states.contains(.failed) {
            name = "externaldrive.badge.exclamationmark"; badge = Self.troubleBadge
            tip = "SMB Keeper: a share needs attention"
        } else if states.contains(.unreachable) || states.contains(.unmounted) {
            name = "externaldrive.badge.xmark"; badge = Self.troubleBadge
            tip = "SMB Keeper: a share is not mounted"
        } else if states.isEmpty {
            name = "externaldrive"; badge = nil
            tip = "SMB Keeper: no shares configured"
        } else {
            name = "externaldrive.badge.checkmark"; badge = Self.healthyBadge
            tip = "SMB Keeper: all shares healthy"
        }
        if name != lastIconKey {
            lastIconKey = name
            if let img = symbol(name, badge: badge) {
                button.image = img
                button.title = ""
            } else {
                button.image = nil
                button.title = "SMB"
            }
        }
        button.toolTip = tip
    }

    // MARK: Panel and menu

    @objc private func togglePanel(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
            return
        }
        panel.toggle()
    }

    /// Right-click on the status item: a native menu, assigned only for the
    /// duration of the click so it cannot hijack left-clicks.
    private func showContextMenu() {
        panel.close()

        let menu = NSMenu()
        menu.addItem(item("Show shares", #selector(menuShowPanel(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Add share…", #selector(menuAddShare(_:))))
        menu.addItem(item("Check all now", #selector(menuCheckAll(_:))))
        menu.addItem(item(engine.paused ? "Resume watching" : "Pause watching", #selector(menuTogglePause(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Open log", #selector(menuOpenLog(_:))))
        menu.addItem(item(LaunchAgent.isInstalled ? "Don't start at login" : "Start at login",
                          #selector(menuToggleLogin(_:))))
        menu.addItem(.separator())
        // A local selector rather than NSApplication.terminate(_:): macOS
        // auto-decorates well-known selectors with a system icon and a Cmd-Q
        // hint, and neither is wanted here.
        menu.addItem(item("Quit SMB Keeper", #selector(menuQuit(_:))))
        menu.delegate = self

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        statusItem.menu = nil
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        return entry
    }

    @objc private func menuShowPanel(_ sender: Any?) { panel.open() }
    @objc private func menuAddShare(_ sender: Any?) { showAddShare() }
    @objc private func menuCheckAll(_ sender: Any?) { store.checkAll() }
    @objc private func menuTogglePause(_ sender: Any?) { engine.setPaused(!engine.paused) }
    @objc private func menuOpenLog(_ sender: Any?) { store.openLog() }
    @objc private func menuToggleLogin(_ sender: Any?) { toggleLoginItem() }
    @objc private func menuQuit(_ sender: Any?) { NSApp.terminate(nil) }

    // MARK: Actions

    private func showAddShare() {
        if addShareWindow == nil { addShareWindow = AddShareWindowController(engine: engine) }
        addShareWindow?.show()
    }

    private func confirmRemove(_ name: String) {
        guard let share = engine.config.share(named: name) else { return }
        let a = NSAlert()
        a.messageText = "Stop monitoring “\(name)”?"
        a.informativeText = "SMB Keeper will no longer check or remount \(share.share) on \(share.server).\n\nThe volume itself is left alone: if it is mounted now, it stays mounted."
        a.addButton(withTitle: "Stop Monitoring")
        a.addButton(withTitle: "Cancel")
        a.buttons.first?.hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        do {
            try store.removeShare(name)
        } catch {
            let message = (error as? Engine.ShareEditError)?.description ?? "\(error)"
            alert("Could not stop monitoring “\(name)”", message)
        }
        refreshIcon()
    }

    private func toggleLoginItem() {
        if LaunchAgent.isInstalled {
            _ = LaunchAgent.uninstall()
            Log.shared.info("app", "launch agent removed; SMB Keeper will not start at login")
        } else {
            let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
            do {
                _ = try LaunchAgent.install(program: exe, arguments: [])
                Log.shared.info("app", "launch agent installed for \(exe)")
            } catch {
                alert("Could not install launch agent", error.localizedDescription)
            }
        }
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}

// Register or remove the launch agent and exit, without starting the app.
// `make install` calls these; they run before NSApplication so the
// duplicate-instance check cannot put a modal alert in front of a build script.
if CommandLine.arguments.contains("--install-agent") {
    let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
    do {
        let path = try LaunchAgent.install(program: exe, arguments: [])
        print("installed \(path)")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("install-agent failed: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}
if CommandLine.arguments.contains("--uninstall-agent") {
    print(LaunchAgent.uninstall() ? "launch agent removed" : "no launch agent was installed")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

// launchd stops us with SIGTERM; turn that into a normal quit so the engine
// stops cleanly and the status file reflects it.
signal(SIGTERM, SIG_IGN)
let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termSource.setEventHandler { NSApp.terminate(nil) }
termSource.resume()

app.run()
