import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let dot = NSView()
    private let store = Store()
    private let notifier = Notifier()
    /// Used instead of the popover when the menu bar icon is hidden (notch overflow, Hidden Bar, …).
    private var panel: FloatingPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }
        let image = NSImage(systemSymbolName: "arrow.triangle.pull", accessibilityDescription: "GitHub Monitor")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        image?.isTemplate = true
        button.image = image
        button.target = self
        button.action = #selector(toggle)

        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 3.5
        dot.isHidden = true
        dot.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(dot)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
            dot.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -1),
            dot.topAnchor.constraint(equalTo: button.topAnchor, constant: 3),
        ])

        let host = NSHostingController(rootView: ContentView().environment(store))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        store.onBadgeChange = { [weak self] unseen in self?.dot.isHidden = !unseen }
        store.dismiss = { [weak self] in self?.closeAll() }
        notifier.setup()
        notifier.onOpenSummary = { [weak self] in self?.showPopover() }
        store.onNotify = { [weak self] items in self?.notifier.post(items) }
        store.requestNotificationPermission = { [weak self] done in self?.notifier.requestAuthorization(done) }
        store.start()

        // First launch: show the window so it's obvious the app is running.
        if !UserDefaults.standard.bool(forKey: "launchedBefore") {
            UserDefaults.standard.set(true, forKey: "launchedBefore")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.showPopover() }
        }
    }

    /// Launching the app again (Finder, Spotlight, `open`) shows the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPopover()
        return false
    }

    @objc private func toggle() {
        popover.isShown ? popover.performClose(nil) : showPopover()
    }

    private func showPopover() {
        guard let button = statusItem.button, !popover.isShown, panel?.isVisible != true else { return }
        NSApp.activate(ignoringOtherApps: true)
        let iconVisible = button.window.map { w in NSScreen.screens.contains { $0.frame.intersects(w.frame) } } ?? false
        if iconVisible {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        } else {
            showPanel()
        }
        store.popoverOpened()
    }

    private func showPanel() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let area = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: area.maxX - panel.frame.width - 10, y: area.maxY - panel.frame.height - 6))
        }
        panel.makeKeyAndOrderFront(nil)
    }

    private func makePanel() -> FloatingPanel {
        let size = NSSize(width: 380, height: 520)
        let panel = FloatingPanel(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.delegate = self

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .popover
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        let host = NSHostingView(rootView: ContentView().environment(store))
        host.frame = effect.bounds
        host.autoresizingMask = [.width, .height]
        effect.addSubview(host)
        panel.contentView = effect
        return panel
    }

    private func closeAll() {
        popover.performClose(nil)
        if panel?.isVisible == true { panel?.orderOut(nil); store.popoverClosed() }
    }

    func popoverDidClose(_ notification: Notification) {
        store.popoverClosed()
    }

    func windowDidResignKey(_ notification: Notification) {
        guard panel?.isVisible == true else { return }
        panel?.orderOut(nil)
        store.popoverClosed()
    }
}

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { resignKey(); orderOut(nil) }
}
