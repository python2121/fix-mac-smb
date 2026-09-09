import AppKit
import SMBKeeperCore

/// Menu bar front end. The engine runs inside this process, so the app is the
/// daemon: launchd starts it at login and keeps it alive.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var engine: Engine!
    private let menu = NSMenu()
    private var refreshTimer: Timer?
    private var lastIconKey = ""
    private var addShareWindow: AddShareWindowController?

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
        engine.onStatusChange = { [weak self] _ in
            DispatchQueue.main.async { self?.refreshIcon() }
        }
        engine.start()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageOnly
        menu.delegate = self
        statusItem.menu = menu
        refreshIcon()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refreshIcon() }

        // Debugging aid: open the Add Share panel at launch and log its
        // geometry, so its layout can be checked without clicking the menu.
        if CommandLine.arguments.contains("--dump-menu") {
            menuNeedsUpdate(menu)
            let titles = menu.items.map { item -> String in
                let sub = item.submenu.map { " {" + $0.items.map { $0.isSeparatorItem ? "--" : $0.title }.joined(separator: " | ") + "}" } ?? ""
                return (item.isSeparatorItem ? "--" : item.title) + sub
            }
            Log.shared.info("app", "menu: " + titles.joined(separator: " / "))
        }
        if CommandLine.arguments.contains("--show-add-share") {
            addShare(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                Log.shared.info("app", "add-share layout: \(self?.addShareWindow?.layoutReport() ?? "none")")
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine?.stop()
    }

    // MARK: Icon

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

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let st = engine.status

        if st.shares.isEmpty {
            let none = NSMenuItem(title: "No shares configured — run `smbkeeper add`", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        for share in st.shares {
            let item = NSMenuItem(title: "\(glyph(for: share.state)) \(share.name)  ·  \(share.state.rawValue)", action: nil, keyEquivalent: "")
            // No tooltip: the submenu already opens with this same detail line,
            // and a hover tip that repeats it just gets in the way.
            let sub = NSMenu()
            let detail = NSMenuItem(title: share.detail, action: nil, keyEquivalent: "")
            detail.isEnabled = false
            sub.addItem(detail)
            if let err = share.lastError, share.state != .healthy {
                let e = NSMenuItem(title: "Last error: \(err)", action: nil, keyEquivalent: "")
                e.isEnabled = false
                sub.addItem(e)
            }
            sub.addItem(.separator())
            sub.addItem(action("Mount Now", #selector(mountNow(_:)), share.name))
            sub.addItem(action("Unmount", #selector(unmountNow(_:)), share.name))
            sub.addItem(action("Force Unmount", #selector(forceUnmountNow(_:)), share.name))
            if let path = share.mountPath, share.state == .healthy {
                sub.addItem(action("Reveal in Finder", #selector(reveal(_:)), path))
            }
            sub.addItem(.separator())
            let eject = action("Eject Before Sleep", #selector(toggleEject(_:)), share.name)
            eject.state = (engine.config.share(named: share.name)?.ejectOnSleep ?? false) ? .on : .off
            sub.addItem(eject)
            sub.addItem(.separator())
            sub.addItem(action("Stop Monitoring This Share…", #selector(removeShare(_:)), share.name))
            item.submenu = sub
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(action("Add Share…", #selector(addShare(_:)), nil))
        menu.addItem(action("Check All Now", #selector(checkAll(_:)), nil))
        menu.addItem(action(st.paused ? "Resume" : "Pause", #selector(togglePause(_:)), nil))
        menu.addItem(.separator())
        let login = action("Start at Login", #selector(toggleLogin(_:)), nil)
        login.state = LaunchAgent.isInstalled ? .on : .off
        menu.addItem(login)
        menu.addItem(action("Open Log", #selector(openLog(_:)), nil))
        menu.addItem(.separator())
        menu.addItem(action("Quit SMB Keeper", #selector(quit(_:)), nil))
    }

    private func glyph(for s: ShareState) -> String {
        switch s {
        case .healthy: return "🟢"
        case .stale, .failed: return "🔴"
        case .mounting, .unmounting: return "🟡"
        case .unreachable, .unmounted: return "⚪️"
        case .paused, .unknown: return "⚫️"
        }
    }

    private func action(_ title: String, _ sel: Selector, _ payload: String?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        item.target = self
        item.representedObject = payload
        return item
    }

    // MARK: Actions

    @objc private func mountNow(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, let c = engine.controller(named: name) else { return }
        c.requestMount()
    }

    @objc private func unmountNow(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, let c = engine.controller(named: name) else { return }
        c.requestUnmount(force: false)
    }

    @objc private func forceUnmountNow(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, let c = engine.controller(named: name) else { return }
        c.requestUnmount(force: true)
    }

    @objc private func reveal(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc private func toggleEject(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        let current = engine.config.share(named: name)?.ejectOnSleep ?? false
        engine.setEjectOnSleep(share: name, !current)
    }

    @objc private func checkAll(_ sender: Any?) {
        for c in engine.shareControllers {
            c.resetBackoff(reason: "menu")
            c.releaseHold(reason: "menu check")
            c.schedule(after: 0, reason: "menu check")
        }
    }

    @objc private func togglePause(_ sender: Any?) { engine.setPaused(!engine.paused) }

    @objc private func toggleLogin(_ sender: Any?) {
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

    @objc private func addShare(_ sender: Any?) {
        if addShareWindow == nil { addShareWindow = AddShareWindowController(engine: engine) }
        addShareWindow?.show()
    }

    @objc private func removeShare(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let share = engine.config.share(named: name) else { return }
        let a = NSAlert()
        a.messageText = "Stop monitoring “\(name)”?"
        a.informativeText = "SMB Keeper will no longer check or remount \(share.share) on \(share.server).\n\nThe volume itself is left alone: if it is mounted now, it stays mounted."
        a.addButton(withTitle: "Stop Monitoring")
        a.addButton(withTitle: "Cancel")
        a.buttons.first?.hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        do {
            try engine.removeShare(named: name)
        } catch {
            let message = (error as? Engine.ShareEditError)?.description ?? "\(error)"
            alert("Could not stop monitoring “\(name)”", message)
        }
        refreshIcon()
    }

    @objc private func openLog(_ sender: Any?) { NSWorkspace.shared.open(URL(fileURLWithPath: Paths.logFile)) }
    @objc private func quit(_ sender: Any?) { NSApp.terminate(nil) }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
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
