import Carbon.HIToolbox
import Foundation

final class GlobalHotKey {
    struct Shortcut: Codable, Equatable {
        var keyCode: UInt32
        var modifiers: UInt32
        var key: String

        static let standard = Shortcut(
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(cmdKey | shiftKey),
            key: "Space"
        )

        var displayName: String {
            var symbols = ""
            if modifiers & UInt32(controlKey) != 0 { symbols += "⌃" }
            if modifiers & UInt32(optionKey) != 0 { symbols += "⌥" }
            if modifiers & UInt32(shiftKey) != 0 { symbols += "⇧" }
            if modifiers & UInt32(cmdKey) != 0 { symbols += "⌘" }
            return symbols + key
        }

        static func load() -> Shortcut {
            guard let data = UserDefaults.standard.data(forKey: "dictationShortcut"),
                  let shortcut = try? JSONDecoder().decode(Shortcut.self, from: data) else {
                return .standard
            }
            return shortcut
        }

        func save() {
            guard let data = try? JSONEncoder().encode(self) else { return }
            UserDefaults.standard.set(data, forKey: "dictationShortcut")
        }
    }

    struct RegistrationError: LocalizedError {
        let status: OSStatus

        var errorDescription: String? {
            if status == OSStatus(eventHotKeyExistsErr) {
                return "That shortcut is already used by another app."
            }
            return "Could not register the shortcut (\(status))."
        }
    }

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    init(shortcut: Shortcut = .load(), action: @escaping () -> Void) throws {
        self.action = action

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let owner = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { owner.action() }
                return noErr
            },
            1,
            &eventType,
            pointer,
            &handlerRef
        )

        let identifier = EventHotKeyID(signature: 0x50545950, id: 1) // PTYP
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard status == noErr else {
            if let handlerRef { RemoveEventHandler(handlerRef) }
            self.handlerRef = nil
            throw RegistrationError(status: status)
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
