import AppKit
import SMBKeeperCore

/// The "Add Share" panel.
///
/// The flow mirrors what actually has to be true for a mount to work: name a
/// server and account, optionally save a password to the login keychain, ask
/// the server what it exports, then pick a share. Everything that can block
/// runs off the main thread, so the window never beachballs on an
/// unresponsive server.
final class AddShareWindowController: NSObject, NSWindowDelegate {
    private let engine: Engine
    private var window: NSWindow?

    private let serverField = NSTextField()
    private let accountField = NSTextField()
    private let passwordField = NSSecureTextField()
    private let shareCombo = NSComboBox()
    private let ejectCheck = NSButton(checkboxWithTitle: "Eject before sleep", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let findButton = NSButton()
    private let addButton = NSButton()
    private let spinner = NSProgressIndicator()

    /// Servers we have already written a keychain item for in this session, so
    /// the password is stored once rather than on every action.
    private var storedFor = Set<String>()

    init(engine: Engine) {
        self.engine = engine
        super.init()
    }

    // MARK: Presentation

    func show() {
        if let window = window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Add Share"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.contentView = buildContentView()
        window.center()
        self.window = window
        prefillFromExistingShares()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(serverField)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        storedFor.removeAll()
    }

    private func buildContentView() -> NSView {
        for field in [serverField, accountField, passwordField] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 260).isActive = true
        }
        shareCombo.translatesAutoresizingMaskIntoConstraints = false
        shareCombo.widthAnchor.constraint(equalToConstant: 200).isActive = true
        serverField.placeholderString = "host name or IP address"
        accountField.placeholderString = "user name on the server"
        passwordField.placeholderString = "leave blank if already saved"

        shareCombo.isEditable = true
        shareCombo.completes = true
        shareCombo.placeholderString = "share name"
        shareCombo.usesDataSource = false

        findButton.title = "Find Shares"
        findButton.bezelStyle = .rounded
        findButton.target = self
        findButton.action = #selector(findShares)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 3
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor

        let hint = NSTextField(wrappingLabelWithString: "Saved to your login keychain, so macOS can mount the share the same way Finder does.")
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor
        hint.isSelectable = false
        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.widthAnchor.constraint(equalToConstant: 300).isActive = true

        let shareRow = NSStackView(views: [shareCombo, findButton, spinner])
        shareRow.orientation = .horizontal
        shareRow.spacing = 8

        addButton.title = "Add Share"
        addButton.bezelStyle = .rounded
        addButton.keyEquivalent = "\r"
        addButton.target = self
        addButton.action = #selector(addShare)

        let closeButton = NSButton(title: "Done", target: self, action: #selector(closeWindow))
        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\u{1b}"

        let buttonRow = NSStackView(views: [NSView(), closeButton, addButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        let grid = NSGridView(views: [
            [label("Server:"), serverField],
            [label("Account:"), accountField],
            [label("Password:"), passwordField],
            [NSGridCell.emptyContentView, hint],
            [label("Share:"), shareRow],
            [NSGridCell.emptyContentView, ejectCheck],
        ])
        grid.columnSpacing = 10
        grid.rowSpacing = 8
        grid.column(at: 0).xPlacement = .trailing

        let root = NSStackView(views: [grid, statusLabel, buttonRow])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        root.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            root.topAnchor.constraint(equalTo: container.topAnchor),
            root.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            buttonRow.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -36),
            statusLabel.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -36),
        ])
        return container
    }

    private func label(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.alignment = .right
        return l
    }

    /// Adding a second share from the same server is the common case, so
    /// borrow the server and account already in use.
    private func prefillFromExistingShares() {
        guard let existing = engine.config.shares.last else { return }
        if serverField.stringValue.isEmpty { serverField.stringValue = existing.server }
        if accountField.stringValue.isEmpty { accountField.stringValue = existing.user ?? "" }
    }

    // MARK: Status

    private func say(_ text: String, bad: Bool = false) {
        statusLabel.stringValue = text
        statusLabel.textColor = bad ? .systemRed : .secondaryLabelColor
    }

    private func setBusy(_ busy: Bool) {
        findButton.isEnabled = !busy
        addButton.isEnabled = !busy
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    private var trimmedServer: String { serverField.stringValue.trimmingCharacters(in: .whitespaces) }
    private var trimmedAccount: String { accountField.stringValue.trimmingCharacters(in: .whitespaces) }

    /// Save the typed password, once per server, if one was typed.
    /// Returns nil on success or a message on failure. Blocking, so call it off
    /// the main thread.
    private func storePasswordIfNeeded(server: String, account: String, password: String) -> String? {
        guard !password.isEmpty, !storedFor.contains(server) else { return nil }
        guard !account.isEmpty else { return "an account name is needed to save a password" }
        let rc = Keychain.storeCredential(server: server, account: account, password: password)
        if rc != 0 { return "could not save the password to the keychain (security exited \(rc))" }
        return nil
    }

    // MARK: Actions

    @objc private func findShares() {
        let server = trimmedServer
        let account = trimmedAccount
        let password = passwordField.stringValue
        guard !server.isEmpty else {
            say("Enter a server first.", bad: true)
            return
        }
        setBusy(true)
        say("Asking \(server) what it shares…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            if let problem = self.storePasswordIfNeeded(server: server, account: account, password: password) {
                DispatchQueue.main.async {
                    self.setBusy(false)
                    self.say(problem, bad: true)
                }
                return
            }
            let stored = !password.isEmpty
            let result = ShareBrowser.diskShares(server: server, user: account.isEmpty ? nil : account, timeout: 15)
            DispatchQueue.main.async {
                if stored { self.storedFor.insert(server) }
                self.setBusy(false)
                switch result {
                case .success(let names):
                    let already = Set(self.engine.config.shares
                        .filter { $0.server.caseInsensitiveCompare(server) == .orderedSame }
                        .map { $0.share.lowercased() })
                    let fresh = names.filter { !already.contains($0.lowercased()) }
                    self.shareCombo.removeAllItems()
                    self.shareCombo.addItems(withObjectValues: fresh)
                    if fresh.isEmpty {
                        self.say(names.isEmpty
                            ? "\(server) reported no disk shares."
                            : "All \(names.count) shares on \(server) are already monitored.")
                    } else {
                        self.say("Found \(fresh.count) share\(fresh.count == 1 ? "" : "s") to add. Pick one.")
                        if self.shareCombo.stringValue.isEmpty {
                            self.shareCombo.selectItem(at: 0)
                            self.shareCombo.stringValue = fresh[0]
                        }
                        self.shareCombo.becomeFirstResponder()
                    }
                case .failure(let err):
                    self.say("Could not list shares: \(err.description)", bad: true)
                }
            }
        }
    }

    @objc private func addShare() {
        let server = trimmedServer
        let account = trimmedAccount
        let share = shareCombo.stringValue.trimmingCharacters(in: .whitespaces)
        let password = passwordField.stringValue
        let eject = ejectCheck.state == .on
        guard !server.isEmpty else { say("Enter a server.", bad: true); return }
        guard !share.isEmpty else { say("Enter or choose a share.", bad: true); return }
        guard !share.contains("/") else { say("A share name cannot contain a slash.", bad: true); return }

        setBusy(true)
        say("Adding \(share)…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            if let problem = self.storePasswordIfNeeded(server: server, account: account, password: password) {
                DispatchQueue.main.async {
                    self.setBusy(false)
                    self.say(problem, bad: true)
                }
                return
            }
            let stored = !password.isEmpty
            let config = ShareConfig(name: share, server: server, share: share,
                                     user: account.isEmpty ? nil : account,
                                     mountPoint: nil, enabled: true, ejectOnSleep: eject)
            DispatchQueue.main.async {
                if stored { self.storedFor.insert(server) }
                self.setBusy(false)
                do {
                    try self.engine.addShare(config)
                    self.say("Added \(share). It will be mounted and watched from now on.")
                    self.shareCombo.stringValue = ""
                    let remaining = self.shareCombo.objectValues.compactMap { $0 as? String }.filter { $0 != share }
                    self.shareCombo.removeAllItems()
                    self.shareCombo.addItems(withObjectValues: remaining)
                } catch {
                    let message = (error as? Engine.ShareEditError)?.description ?? "\(error)"
                    self.say(message, bad: true)
                }
            }
        }
    }

    @objc private func closeWindow() {
        window?.performClose(nil)
    }
}
