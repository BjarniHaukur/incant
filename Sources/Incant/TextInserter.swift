import ApplicationServices
import AppKit
import OSLog

enum TextInserter {
    private static let logger = Logger(subsystem: "com.bjarni.Incant", category: "Insertion")
    /// Apps already asked for their web accessibility tree, and the last target
    /// refused, so the log gets one line per app rather than one per delta.
    /// Every caller runs on the main actor.
    nonisolated(unsafe) private static var webAccessibilityRequested: Set<pid_t> = []
    nonisolated(unsafe) private static var lastRefusal = ""

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
        guard AXIsProcessTrusted(), let focused = focusedElement(),
              isEditable(focused) || isWebContext(focused) else {
            return nil
        }
        return Target(element: focused)
    }

    static func insertLive(_ text: String, target: Target? = nil) -> LiveInsertionResult {
        guard AXIsProcessTrusted() else { return .accessibilityDenied }
        guard !text.isEmpty else { return .inserted }

        // Prefer replacing the focused element's current selection. This is
        // the most direct insertion path and keeps the caret in the target app.
        let focusedTarget = target?.element ?? focusedElement()
        guard let focused = focusedTarget else {
            logRefusal(nil)
            return .noEditableTarget
        }
        if isEditable(focused), replaceSelection(with: text, in: focused) { return .inserted }

        // Keystrokes land wherever the keyboard is pointed, and in a browser that
        // is not where the accessibility tree says focus is: Chrome reports the
        // focused element as a button while the characters arrive in the search
        // field. So anything that came out of a web page is worth typing into and
        // the page decides where it goes, exactly as the user's own typing would.
        // Elsewhere this stays narrow, because Unicode events aimed at an
        // arbitrary button trigger shortcuts and macOS's repeated error sound.
        guard isEditable(focused) || isWebContext(focused) else {
            logRefusal(focused)
            return .noEditableTarget
        }

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

    /// Chromium ships its web-content accessibility tree switched off and builds
    /// it only once a client asks for it. Until then a focused text box on a web
    /// page is invisible to the accessibility API, so every Chromium browser and
    /// every Electron app — Slack, VS Code, Discord — reports no editable target
    /// and dictation into a web page goes nowhere. Screen readers get the tree
    /// by setting exactly this attribute. Apps that do not know it return
    /// unsupported, which is harmless.
    private static func requestWebAccessibility() {
        guard let application = NSWorkspace.shared.frontmostApplication,
              !webAccessibilityRequested.contains(application.processIdentifier) else { return }
        webAccessibilityRequested.insert(application.processIdentifier)
        let element = AXUIElementCreateApplication(application.processIdentifier)
        let result = AXUIElementSetAttributeValue(
            element,
            "AXManualAccessibility" as CFString,
            kCFBooleanTrue
        )
        logger.info(
            """
            Requested web accessibility from \(application.localizedName ?? "?", privacy: .public): \
            \(result == .success ? "granted" : "AXError \(result.rawValue)", privacy: .public)
            """
        )
    }

    /// Records which app and which element turned an insertion down, so a report
    /// of "it does not type into <app>" can be traced without a debugger.
    private static func logRefusal(_ element: AXUIElement?) {
        let name = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        let role = element.flatMap { stringAttribute(kAXRoleAttribute, from: $0) } ?? "<no focus>"
        let subrole = element.flatMap { stringAttribute(kAXSubroleAttribute, from: $0) } ?? "—"
        let refusal = "\(name)/\(role)/\(subrole)"
        guard refusal != lastRefusal else { return }
        lastRefusal = refusal
        logger.error("No editable target in \(refusal, privacy: .public)")
    }

    private static func focusedElement() -> AXUIElement? {
        requestWebAccessibility()
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

    /// Writes over the current selection and confirms the write actually took.
    ///
    /// Slack reports `AXSelectedText` as settable, accepts the write, returns
    /// success and inserts nothing at all. Believing it cost the whole
    /// transcript: the caller treated the delta as delivered and cleared the
    /// buffer behind it, so the words were gone with nothing on screen to
    /// recover them from. Length and caret position are both checked because
    /// replacing a selection of the same length leaves the count unchanged.
    private static func replaceSelection(with text: String, in element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
            element, kAXSelectedTextAttribute as CFString, &settable
        ) == .success, settable.boolValue else { return false }

        let countBefore = characterCount(of: element)
        let caretBefore = caretLocation(of: element)
        guard AXUIElementSetAttributeValue(
            element, kAXSelectedTextAttribute as CFString, text as CFTypeRef
        ) == .success else { return false }

        let countAfter = characterCount(of: element)
        let caretAfter = caretLocation(of: element)
        if let countBefore, let countAfter, countAfter != countBefore { return true }
        if let caretBefore, let caretAfter, caretAfter != caretBefore { return true }
        // Nothing legible to compare against. Trusting the write is what this
        // method exists to avoid, but typing again would duplicate every delta
        // in the many apps that simply do not publish their contents, so the
        // benefit of the doubt goes to the app that claimed success.
        if countBefore == nil, caretBefore == nil { return true }
        logger.error("Insertion reported success but changed nothing in \(frontmostName(), privacy: .public)")
        return false
    }

    private static func characterCount(of element: AXUIElement) -> Int? {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element, kAXNumberOfCharactersAttribute as CFString, &value
        ) == .success, let number = value as? Int {
            return number
        }
        return stringAttribute(kAXValueAttribute, from: element)?.count
    }

    private static func caretLocation(of element: AXUIElement) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &value
        ) == .success, let value else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range.location
    }

    /// Did this element come out of a web page? Both Chromium and WebKit hang DOM
    /// attributes off their nodes, which is a far steadier signal than any role:
    /// the role a browser reports for the focused element varies by browser, by
    /// page, and by whether the field is a real input or a contenteditable.
    private static func isWebContext(_ element: AXUIElement) -> Bool {
        var current = element
        for _ in 0..<6 {
            if stringAttribute(kAXRoleAttribute, from: current) == "AXWebArea" { return true }
            var names: CFArray?
            if AXUIElementCopyAttributeNames(current, &names) == .success,
               let names = names as? [String],
               names.contains(where: { $0.hasPrefix("AXDOM") }) {
                return true
            }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                current, kAXParentAttribute as CFString, &parent
            ) == .success, let parent else { return false }
            current = unsafeBitCast(parent, to: AXUIElement.self)
        }
        return false
    }

    private static func frontmostName() -> String {
        NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
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
