import AppKit
import SwiftUI
import SMBKeeperCore

/// Borderless panel that can still become key, so the SwiftUI controls inside
/// receive clicks and keystrokes without activating the accessory app.
final class KeyablePanel: NSPanel {
    /// Invoked on Escape (or Cmd+.) — a borderless panel has no close button,
    /// so this is the keyboard dismissal path.
    var onCancel: (() -> Void)?

    /// Invoked on Up (-1) / Down (+1) to walk the list.
    var onMove: ((_ direction: Int) -> Void)?

    override var canBecomeKey: Bool { true }

    // Arrow keys drive the list. Intercepted in sendEvent rather than keyDown
    // so that whichever view is first responder cannot swallow (and beep at)
    // them before the window sees them.
    override func sendEvent(_ event: NSEvent) {
        let arrows: Set<UInt16> = [125, 126]   // down, up
        let claimed: NSEvent.ModifierFlags = [.command, .option, .control]
        if event.type == .keyDown, arrows.contains(event.keyCode),
           event.modifierFlags.intersection(claimed).isEmpty {
            onMove?(event.keyCode == 125 ? 1 : -1)
            return
        }
        super.sendEvent(event)
    }

    // Esc reaches the window as cancelOperation(_:) via the responder chain
    // when no view inside claims it.
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    // Fallback: if a responder swallows the cancel selector but lets the raw
    // key event bubble, still treat Esc as dismiss rather than beeping.
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
            return
        }
        super.keyDown(with: event)
    }
}

/// Owns the panel: its vibrant background, its position under the status item,
/// and its open and close animation.
@MainActor
final class PanelController {
    private let store: ShareStore
    private let statusItem: NSStatusItem
    private var panel: KeyablePanel!
    private var hostingController: NSHostingController<PanelView>!
    private var sizeObservation: NSKeyValueObservation?
    private var clickMonitor: Any?

    // Visual and motion tuning.
    private let panelWidth: CGFloat = 304
    private let cornerRadius: CGFloat = 12
    private let tintOpacity: CGFloat = 0.7
    private let slideDistance: CGFloat = 8
    private let openDuration: TimeInterval = 0.16
    private let closeDuration: TimeInterval = 0.12

    var isVisible: Bool { panel?.isVisible ?? false }

    init(store: ShareStore, statusItem: NSStatusItem, actions: PanelActions) {
        self.store = store
        self.statusItem = statusItem
        build(actions: actions)
    }

    private func build(actions: PanelActions) {
        hostingController = NSHostingController(rootView: PanelView(store: store, actions: actions))
        // Report the SwiftUI ideal size as preferredContentSize so the panel can
        // be sized to its content, and follow it when the content changes.
        hostingController.sizingOptions = [.preferredContentSize]

        // Rounded, vibrant background to replace the popover chrome lost by
        // going borderless. `.menu` is the most opaque public material, but the
        // system's own panels are more opaque still, so the blur is washed with
        // a semi-opaque adaptive tint below.
        let effect = NSVisualEffectView()
        effect.material = .menu
        effect.state = .active
        effect.blendingMode = .behindWindow
        // Round the blur with a resizable mask image, the documented way for
        // NSVisualEffectView. Setting layer.cornerRadius on it is unreliable:
        // square corners poke out during animation and resize.
        effect.maskImage = Self.roundedMaskImage(radius: cornerRadius)

        // In light mode a window-background fill over the blur lifts it toward
        // the system panels' solidity. In dark mode the blur is already dark
        // enough, so the tint is clear.
        let opacity = tintOpacity
        let tint = NSBox()
        tint.boxType = .custom
        tint.titlePosition = .noTitle
        tint.borderWidth = 0
        tint.cornerRadius = cornerRadius
        tint.fillColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? .clear
                : NSColor.windowBackgroundColor.withAlphaComponent(opacity)
        }
        tint.translatesAutoresizingMaskIntoConstraints = false

        let host = hostingController.view
        host.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(tint)
        effect.addSubview(host)
        NSLayoutConstraint.activate([
            tint.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            tint.topAnchor.constraint(equalTo: effect.topAnchor),
            tint.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            host.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            host.topAnchor.constraint(equalTo: effect.topAnchor),
            host.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])

        panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: 300),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = effect
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none           // animated manually below
        panel.isReleasedWhenClosed = false
        // .moveToActiveSpace, not .canJoinAllSpaces, so the panel follows the
        // user to whichever Space they are viewing.
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .stationary]
        // Escape peels back one layer per press: the highlight, then the panel.
        panel.onCancel = { [weak self] in
            guard let self else { return }
            switch self.store.escapeAction() {
            case .clearSelection: self.store.clearSelection()
            case .close: self.close()
            }
        }
        panel.onMove = { [weak self] direction in
            self?.store.moveSelection(direction)
        }
    }

    /// A resizable rounded-rect mask: the centre stretches and the corners stay
    /// fixed (cap insets), so one image rounds the effect view at any size.
    private static func roundedMaskImage(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    // MARK: Show and hide

    func toggle() {
        if isVisible { close() } else { open() }
    }

    func open() {
        store.refreshOnOpen()

        hostingController.view.layoutSubtreeIfNeeded()
        var size = hostingController.view.fittingSize
        if size.width < 1 || size.height < 1 { size = NSSize(width: panelWidth, height: 300) }
        // On the very first click after launch the hosting view can report a
        // degenerate fittingSize before SwiftUI's initial layout settles, and an
        // over-tall panel drives the origin math below the screen.
        if let visible = (statusItem.button?.window?.screen ?? NSScreen.main)?.visibleFrame,
           size.width > visible.width || size.height > visible.height {
            size.width = min(size.width, visible.width)
            size.height = min(size.height, visible.height)
        }
        panel.setContentSize(size)

        guard let finalOrigin = origin(for: panel.frame.size) else {
            // Status-item geometry unresolved, seen on the first click right
            // after launch. Never fall through to the panel's default frame:
            // its (0,0) origin puts it at the bottom-left corner.
            if let visible = NSScreen.main?.visibleFrame {
                panel.setFrameOrigin(NSPoint(x: visible.maxX - panel.frame.width - 8,
                                             y: visible.maxY - panel.frame.height))
            }
            panel.makeKeyAndOrderFront(nil)
            return
        }

        // Start tucked up under the menu bar and transparent, then slide down
        // and fade in. The fade masks the few points that overlap the bar.
        panel.setFrameOrigin(NSPoint(x: finalOrigin.x, y: finalOrigin.y + slideDistance))
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        statusItem.button?.highlight(true)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = openDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrameOrigin(finalOrigin)
            panel.animator().alphaValue = 1
        }

        // When a refresh adds or removes a row the content height changes; keep
        // the panel pinned just under the menu bar instead of drifting.
        sizeObservation = hostingController.observe(\.preferredContentSize, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.followContentSize() }
        }

        // Transient dismissal: a mouse-down anywhere outside this app closes the
        // panel. Clicks inside it and on our own status item are local events
        // and do not reach a global monitor, so they cannot double-toggle.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
    }

    private func followContentSize() {
        guard panel.isVisible else { return }
        let size = hostingController.preferredContentSize
        guard size.width > 0, size.height > 0 else { return }
        panel.setContentSize(size)
        if let point = origin(for: panel.frame.size) {
            panel.setFrameOrigin(point)
        }
    }

    func close() {
        guard panel.isVisible else { return }
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        sizeObservation?.invalidate(); sizeObservation = nil
        statusItem.button?.highlight(false)

        let up = NSPoint(x: panel.frame.origin.x, y: panel.frame.origin.y + slideDistance)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = closeDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrameOrigin(up)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1
            }
        })
    }

    /// Final origin: top edge just below the menu bar, centred under the status
    /// item, clamped on-screen.
    private func origin(for size: NSSize) -> NSPoint? {
        guard let button = statusItem.button,
              let buttonWindow = button.window,
              let screen = buttonWindow.screen
        else { return nil }

        let buttonInScreen = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let topEdge = screen.visibleFrame.maxY          // first point below the menu bar
        var point = NSPoint(x: buttonInScreen.midX - size.width / 2, y: topEdge - size.height)

        let minX = screen.visibleFrame.minX
        let maxX = screen.visibleFrame.maxX - size.width
        point.x = min(max(point.x, minX), maxX)
        return point
    }
}
