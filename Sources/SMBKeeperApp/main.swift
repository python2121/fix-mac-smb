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
            alert("SMB Keeper is already running", "Another instance (pid \(st.pid)) is active. Quit it first, or use `smbkeeper` to control it.")
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

        panel = PanelController(store: store, statusItem: statusItem, actions: panelActions())

        refreshIcon()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshIcon() }
        }

        // Debugging aids, for checking layout without clicking the menu bar.
        if CommandLine.arguments.contains("--show-panel") {
            panel.open()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                MainActor.assumeIsolated {
                    Log.shared.info("app", "panel layout: \(self?.panel.layoutReport() ?? "none")")
                }
            }
        }
        if let idx = CommandLine.arguments.firstIndex(of: "--snapshot"),
           idx + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[idx + 1]
            panel.open()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                MainActor.assumeIsolated {
                    let ok = self?.panel.snapshot(to: path) ?? false
                    Log.shared.info("app", "snapshot to \(path): \(ok ? "written" : "failed")")
                    NSApp.terminate(nil)
                }
            }
        }
        if CommandLine.arguments.contains("--show-add-share") {
            showAddShare()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                MainActor.assumeIsolated {
                    Log.shared.info("app", "add-share layout: \(self?.addShareWindow?.layoutReport() ?? "none")")
                }
            }
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

    private func symbol(_ name: String, fallback: String) -> NSImage? {
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "SMB Keeper")
            ?? NSImage(systemSymbolName: fallback, accessibilityDescription: "SMB Keeper")
        img?.isTemplate = true
        return img
    }

    private func refreshIcon() {
        guard let engine = engine, let button = statusItem?.button else { return }
        let st = engine.status
        let states = st.shares.filter { $0.state != .paused }.map { $0.state }
        let name: String
        let tip: String
        if engine.paused {
            name = "externaldrive.badge.minus"; tip = "SMB Keeper: paused"
        } else if states.contains(.mounting) || states.contains(.unmounting) {
            name = "externaldrive.badge.timemachine"; tip = "SMB Keeper: working"
        } else if states.contains(.stale) || states.contains(.failed) {
            name = "externaldrive.badge.exclamationmark"; tip = "SMB Keeper: a share needs attention"
        } else if states.contains(.unreachable) || states.contains(.unmounted) {
            name = "externaldrive.badge.xmark"; tip = "SMB Keeper: a share is not mounted"
        } else if states.isEmpty {
            name = "externaldrive"; tip = "SMB Keeper: no shares configured"
        } else {
            name = "externaldrive.badge.checkmark"; tip = "SMB Keeper: all shares healthy"
        }
        if name != lastIconKey {
            lastIconKey = name
            if let img = symbol(name, fallback: "externaldrive") {
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
