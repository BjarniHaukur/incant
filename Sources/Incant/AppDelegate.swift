import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model = AppModel()
    private var hotKey: GlobalHotKey?
    private var recorderPanel: NSPanel?
    private var settingsWindow: NSWindow?
    private var motionSamples: [ObjectIdentifier: (origin: NSPoint, time: TimeInterval)] = [:]
    /// The corner the panel was last put at by code. A move that reports exactly
    /// this corner is our own placement rather than the user dragging the stone,
    /// whether the notification arrives inside `setFrameOrigin` or a turn of the
    /// run loop later.
    private var placedRecorderCorner: NSPoint?
    /// Bumped by every show and hide. The fade-out's completion handler carries
    /// the token it was scheduled with, so a session that starts while the
    /// previous one is still fading cannot be ordered out by that stale handler.
    private var recorderVisibility = 0
    private static let recorderCornerKey = "recorderOrbCorner"

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "png"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = icon
        }
        buildMenu()
        buildRecorderPanel()
        buildSettingsWindow()

        do {
            hotKey = try makeHotKey(for: model.shortcut)
        } catch {
            showShortcutError(error.localizedDescription)
        }
        model.showRecorder = { [weak self] in self?.showRecorder() }
        model.hideRecorder = { [weak self] in self?.hideRecorder() }
        model.showSettings = { [weak self] in self?.showSettings() }
        model.applyShortcut = { [weak self] shortcut in
            self?.replaceHotKey(with: shortcut)
        }

        if CommandLine.arguments.contains("--preview-orb") {
            settingsWindow?.orderOut(nil)
            model.startVisualPreview()
        } else {
            if CommandLine.arguments.contains("--preview-home") {
                model.startVisualPreview(showPanel: false)
            }
            // Incant is a Dock app: launching it or clicking its Dock icon
            // should always have a visible home rather than an invisible
            // menu-bar-style process.
            showSettings()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Incant Settings...", action: #selector(openSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Incant", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        NSApplication.shared.mainMenu = main
    }

    private func buildRecorderPanel() {
        let panel = InteractiveRecorderPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 350),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: RecorderOrbView(model: model))
        recorderPanel = panel
        rememberMotionSample(for: panel)
    }

    private func buildSettingsWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 770),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Incant"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(red: 0.005, green: 0.008, blue: 0.02, alpha: 1)
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.contentView = NSHostingView(rootView: SettingsView(model: model))
        window.center()
        window.delegate = self
        settingsWindow = window
        rememberMotionSample(for: window)
    }

    private func showRecorder() {
        guard let panel = recorderPanel else { return }
        recorderVisibility += 1
        placeRecorder(panel)
        rememberMotionSample(for: panel)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            panel.animator().alphaValue = 1
        }
    }

    /// Puts the stone back where the user dragged it. Without a remembered
    /// corner — or with one that no longer lands on a screen, as after a display
    /// is unplugged — it opens above the bottom of the active screen.
    private func placeRecorder(_ panel: NSPanel) {
        var origin: NSPoint
        if let corner = storedRecorderCorner, isOnAScreen(corner, of: panel) {
            origin = NSPoint(x: corner.x, y: corner.y - panel.frame.height)
        } else {
            let screen = NSScreen.main?.visibleFrame ?? NSScreen.screens[0].visibleFrame
            origin = NSPoint(x: screen.midX - panel.frame.width / 2, y: screen.minY + 86)
        }
        // Recorded before the move, because the notification it provokes can
        // arrive before `setFrameOrigin` returns.
        placedRecorderCorner = NSPoint(x: origin.x, y: origin.y + panel.frame.height)
        panel.setFrameOrigin(origin)
    }

    /// True when the middle of the panel — where the stone sits, and where the
    /// pointer has to be to drag it — still falls on a screen the user has. The
    /// panel's transparent edges may hang off, so a stone parked at the edge of a
    /// screen comes back parked at the edge.
    private func isOnAScreen(_ corner: NSPoint, of panel: NSPanel) -> Bool {
        let middle = NSPoint(
            x: corner.x + panel.frame.width / 2,
            y: corner.y - panel.frame.height / 2
        )
        return NSScreen.screens.contains { $0.frame.contains(middle) }
    }

    /// The panel's top-left corner, which is the part of it that holds still: the
    /// orb view sizes the window to its content, and a window grows and shrinks
    /// away from that corner, so it is the only anchor that survives the
    /// composer appearing or the transcript arriving.
    private func corner(of window: NSWindow) -> NSPoint {
        NSPoint(x: window.frame.minX, y: window.frame.maxY)
    }

    /// Kept in defaults rather than in memory, so the place the user chose
    /// survives a relaunch as well as a toggle.
    private var storedRecorderCorner: NSPoint? {
        guard let stored = UserDefaults.standard.array(forKey: Self.recorderCornerKey) as? [Double],
              stored.count == 2 else { return nil }
        return NSPoint(x: stored[0], y: stored[1])
    }

    private func rememberRecorderCorner(_ corner: NSPoint) {
        UserDefaults.standard.set([corner.x, corner.y], forKey: Self.recorderCornerKey)
    }

    private func hideRecorder() {
        guard let panel = recorderPanel else { return }
        recorderVisibility += 1
        let token = recorderVisibility
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.075
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // Animation completions land on the main thread, where the token
            // this handler has to check lives.
            MainActor.assumeIsolated {
                guard let self, self.recorderVisibility == token else { return }
                panel.orderOut(nil)
            }
        })
    }

    private func showSettings() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        recorderPanel?.orderOut(nil)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === settingsWindow || window === recorderPanel else { return }
        let now = Date.timeIntervalSinceReferenceDate
        let origin = window.frame.origin
        if window === recorderPanel, corner(of: window) != placedRecorderCorner {
            rememberRecorderCorner(corner(of: window))
        }
        let id = ObjectIdentifier(window)
        guard let sample = motionSamples[id] else {
            rememberMotionSample(for: window)
            return
        }
        let delta = CGSize(
            width: origin.x - sample.origin.x,
            height: -(origin.y - sample.origin.y)
        )
        let elapsed = max(now - sample.time, 1.0 / 240.0)
        motionSamples[id] = (origin, now)
        model.injectWindowMotion(delta: delta, elapsed: elapsed)
    }

    private func rememberMotionSample(for window: NSWindow) {
        motionSamples[ObjectIdentifier(window)] = (
            window.frame.origin,
            Date.timeIntervalSinceReferenceDate
        )
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === settingsWindow else { return }
        if model.phase == .connecting || model.phase == .listening {
            showRecorder()
        }
    }

    private func makeHotKey(for shortcut: GlobalHotKey.Shortcut) throws -> GlobalHotKey {
        try GlobalHotKey(shortcut: shortcut) { [weak self] in
            Task { @MainActor in self?.model.toggleRecording() }
        }
    }

    private func replaceHotKey(with shortcut: GlobalHotKey.Shortcut) -> String? {
        let previous = model.shortcut
        hotKey = nil
        do {
            hotKey = try makeHotKey(for: shortcut)
            return nil
        } catch {
            hotKey = try? makeHotKey(for: previous)
            return error.localizedDescription
        }
    }

    private func showShortcutError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Incant shortcut unavailable"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func openSettings() {
        showSettings()
    }
}

private final class InteractiveRecorderPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
