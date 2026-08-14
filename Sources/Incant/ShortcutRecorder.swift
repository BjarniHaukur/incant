import AppKit
import Carbon.HIToolbox
import SwiftUI

struct ShortcutRecorder: View {
    let shortcut: GlobalHotKey.Shortcut
    let onChange: (GlobalHotKey.Shortcut) -> Void
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button(isRecording ? "Press shortcut…" : shortcut.displayName) {
            isRecording.toggle()
            updateMonitor()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(isRecording ? .cyan : .white.opacity(0.35))
        .onDisappear { removeMonitor() }
    }

    private func updateMonitor() {
        removeMonitor()
        guard isRecording else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                isRecording = false
                removeMonitor()
                return nil
            }

            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
            guard !flags.isEmpty else { return nil }
            var carbonModifiers: UInt32 = 0
            if flags.contains(.command) { carbonModifiers |= UInt32(cmdKey) }
            if flags.contains(.shift) { carbonModifiers |= UInt32(shiftKey) }
            if flags.contains(.option) { carbonModifiers |= UInt32(optionKey) }
            if flags.contains(.control) { carbonModifiers |= UInt32(controlKey) }

            let next = GlobalHotKey.Shortcut(
                keyCode: UInt32(event.keyCode),
                modifiers: carbonModifiers,
                key: Self.keyName(for: event)
            )
            isRecording = false
            removeMonitor()
            onChange(next)
            return nil
        }
    }

    private func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private static func keyName(for event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "Return"
        case kVK_Tab: return "Tab"
        case kVK_Delete: return "Delete"
        case kVK_ForwardDelete: return "⌦"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        default:
            let value = event.charactersIgnoringModifiers?.uppercased() ?? "Key"
            return value.isEmpty ? "Key" : value
        }
    }
}
