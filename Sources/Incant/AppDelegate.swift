import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model = AppModel()
    private var hotKey: GlobalHotKey?
    private var recorderPanel: NSPanel?
    private var settingsWindow: NSWindow?
    private var motionSamples: [ObjectIdentifier: (origin: NSPoint, time: TimeInterval)] = [:]

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
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 700),
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
        let frame = NSScreen.main?.visibleFrame ?? NSScreen.screens[0].visibleFrame
        let origin = NSPoint(
            x: frame.midX - panel.frame.width / 2,
            y: frame.minY + 86
        )
        panel.setFrameOrigin(origin)
        rememberMotionSample(for: panel)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            panel.animator().alphaValue = 1
        }
    }

    private func hideRecorder() {
        guard let panel = recorderPanel else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.075
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
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
