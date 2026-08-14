import ApplicationServices
import AppKit

enum TextInserter {
    final class Target {
        fileprivate let element: AXUIElement

        fileprivate init(element: AXUIElement) {
            self.element = element
        }
    }

    enum LiveInsertionResult {
        case inserted
        case noEditableTarget
        case accessibilityDenied
    }

    static var isAccessibilityGranted: Bool { AXIsProcessTrusted() }

    static func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func captureTarget() -> Target? {
        guard AXIsProcessTrusted(), let focused = focusedElement(), isEditable(focused) else {
            return nil
        }
        return Target(element: focused)
    }

    static func insertLive(_ text: String, target: Target? = nil) -> LiveInsertionResult {
        guard AXIsProcessTrusted() else { return .accessibilityDenied }
        guard !text.isEmpty else { return .inserted }

        // Prefer replacing the focused element's current selection. This is
        // the most direct insertion path and keeps the caret in the target app.
        guard let focused = target?.element ?? focusedElement(), isEditable(focused) else {
            return .noEditableTarget
        }

        var selectedTextSettable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(
            focused,
            kAXSelectedTextAttribute as CFString,
            &selectedTextSettable
        ) == .success, selectedTextSettable.boolValue,
           AXUIElementSetAttributeValue(
                focused,
                kAXSelectedTextAttribute as CFString,
                text as CFTypeRef
           ) == .success {
            return .inserted
        }

        // Only validated text controls reach this fallback. Posting Unicode
        // events at an arbitrary focused button/window causes macOS's repeated
        // "dun" error sound and can trigger unrelated shortcuts.
        let characters = Array(text.utf16)
        guard !characters.isEmpty else { return .inserted }
        let source = CGEventSource(stateID: .combinedSessionState)
        for start in stride(from: 0, to: characters.count, by: 20) {
            let end = min(start + 20, characters.count)
            let chunk = Array(characters[start..<end])
            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                return .noEditableTarget
            }
            chunk.withUnsafeBufferPointer { buffer in
                guard let baseAddress = buffer.baseAddress else { return }
                keyDown.keyboardSetUnicodeString(
                    stringLength: buffer.count,
                    unicodeString: baseAddress
                )
                keyUp.keyboardSetUnicodeString(
                    stringLength: buffer.count,
                    unicodeString: baseAddress
                )
            }
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
        }
        return .inserted
    }

    static var hasEditableTarget: Bool {
        guard AXIsProcessTrusted(), let focused = focusedElement() else { return false }
        return isEditable(focused)
    }

    private static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success, let focusedValue else { return nil }
        let focused = unsafeBitCast(focusedValue, to: AXUIElement.self)
        var pid: pid_t = 0
        if AXUIElementGetPid(focused, &pid) == .success,
           pid == ProcessInfo.processInfo.processIdentifier {
            return nil
        }
        return focused
    }

    private static func isEditable(_ element: AXUIElement) -> Bool {
        var selectedTextSettable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(
            element,
            kAXSelectedTextAttribute as CFString,
            &selectedTextSettable
        ) == .success, selectedTextSettable.boolValue {
            return true
        }

        let role = stringAttribute(kAXRoleAttribute, from: element)
        let subrole = stringAttribute(kAXSubroleAttribute, from: element)
        let textRoles: Set<String> = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXComboBoxRole as String,
            "AXSearchField",
        ]
        return role.map(textRoles.contains) == true || subrole.map(textRoles.contains) == true
    }

    private static func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    static func insert(_ text: String) -> Bool {
        let system = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            system,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success, let focusedValue {
            let focused = unsafeBitCast(focusedValue, to: AXUIElement.self)
            var settable = DarwinBoolean(false)
            if AXUIElementIsAttributeSettable(
                focused,
                kAXSelectedTextAttribute as CFString,
                &settable
            ) == .success, settable.boolValue,
               AXUIElementSetAttributeValue(
                focused,
                kAXSelectedTextAttribute as CFString,
                text as CFTypeRef
               ) == .success {
                return true
            }
        }

        guard AXIsProcessTrusted() else { return false }
        paste(text)
        return true
    }

    private static func paste(_ text: String) {
        let board = NSPasteboard.general
        let snapshot = board.pasteboardItems?.map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        } ?? []

        board.clearContents()
        board.setString(text, forType: .string)

        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            board.clearContents()
            let restored = snapshot.map { values -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            }
            board.writeObjects(restored)
        }
    }
}
