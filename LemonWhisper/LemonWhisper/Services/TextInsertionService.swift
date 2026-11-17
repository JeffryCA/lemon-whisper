import AppKit
import ApplicationServices
import Foundation

enum TextInsertionPath: String {
    case accessibility
    case unicodeKeyboard
    case commandV
    case appleScript
    
    var logLabel: String {
        switch self {
        case .accessibility:
            return "Accessibility text insertion"
        case .unicodeKeyboard:
            return "Unicode keyboard events"
        case .commandV:
            return "Command-V"
        case .appleScript:
            return "AppleScript System Events"
        }
    }
}

struct TextInsertionResult {
    let path: TextInsertionPath?
    let errorMessage: String?

    var succeeded: Bool {
        path != nil
    }
}

final class TextInsertionService {
    private struct InsertionTarget {
        let bundleIdentifier: String?
        let processID: pid_t?
    }

    private struct AccessibilityTextContext {
        let currentValue: String?
        let placeholderValue: String?
        let selectedRange: CFRange?

        var exposesPlaceholderAsValue: Bool {
            guard let currentValue else { return false }
            return TextInsertionService.isPlaceholderValue(currentValue, placeholder: placeholderValue)
        }

        var hasSelection: Bool {
            guard let selectedRange else {
                return false
            }
            return selectedRange.length > 0
        }

        var isEmptyField: Bool {
            guard let currentValue else {
                return false
            }
            return currentValue.isEmpty
        }
    }

    @MainActor
    func beginLiveDictation(processID: pid_t?) -> LiveDictationInsertion? {
        guard AXIsProcessTrusted(), let processID, processID != getpid(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == processID,
              let element = focusedElement(inApplicationPID: processID),
              isEditableTextRole(element),
              isAttributeSettable(kAXSelectedTextRangeAttribute as CFString, in: element),
              let state = liveFieldState(for: element, processID: processID),
              let span = LiveDictationRange(value: state.value, selection: state.selection) else { return nil }
        return LiveDictationInsertion(service: self, element: element, processID: processID, span: span)
    }

    @MainActor
    func liveFieldState(
        for element: AXUIElement, processID: pid_t
    ) -> (value: String, selection: NSRange, prefersKeyboard: Bool)? {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == processID,
              let focused = focusedElement(inApplicationPID: processID), CFEqual(element, focused),
              let value = stringValue(for: element),
              let range = selectedTextRange(for: element),
              range.location >= 0, range.length >= 0 else { return nil }
        let rawSelection = NSRange(location: range.location, length: range.length)
        let bundleIdentifier = NSRunningApplication(processIdentifier: processID)?.bundleIdentifier
        let selection = alignedLiveSelection(rawSelection, value: value, in: element) ?? rawSelection
        var placeholder = stringAttributeValue(kAXPlaceholderValueAttribute as CFString, for: element)
        // Codex can expose an empty composer hint as its accessibility name.
        if placeholder?.isEmpty != false, bundleIdentifier == "com.openai.codex",
           selection == NSRange(location: 0, length: 0), value.hasSuffix("\n"),
           let title = stringAttributeValue(kAXTitleAttribute as CFString, for: element),
           value == title + "\n",
           title == stringAttributeValue(kAXDescriptionAttribute as CFString, for: element) {
            placeholder = title
        }
        // A caret at a line boundary can share an AX offset with another line.
        // Keyboard events act on the actual caret even where AX offsets are ambiguous.
        let text = value as NSString
        let touchesLineBreak = selection.location < text.length && text.character(at: selection.location) == 0x0A
        return (
            Self.editableValue(value, placeholder: placeholder, selection: selection, bundleIdentifier: bundleIdentifier),
            selection,
            selection != rawSelection || touchesLineBreak
        )
    }

    static func editableValue(
        _ value: String, placeholder: String?, selection: NSRange, bundleIdentifier: String?
    ) -> String {
        guard selection == NSRange(location: 0, length: 0) else { return value }
        // The Codex composer can expose its empty hint with no AXPlaceholderValue.
        let isCodexEmptyHint = bundleIdentifier == "com.openai.codex" && value == "Work with Codex\n"
        if isCodexEmptyHint || value == "\n" || isPlaceholderValue(value, placeholder: placeholder) {
            return ""
        }
        return value
    }

    private static func isPlaceholderValue(_ value: String, placeholder: String?) -> Bool {
        guard let placeholder else { return false }
        // Some rich-text editors add a paragraph separator only to AXValue.
        return value == placeholder || (!placeholder.isEmpty && value == placeholder + "\n")
    }

    private func alignedLiveSelection(_ selection: NSRange, value: String, in element: AXUIElement) -> NSRange? {
        let (end, overflow) = selection.location.addingReportingOverflow(selection.length)
        guard !overflow, end > 0, end <= value.utf16.count, value.utf16.contains(0x0A) else { return nil }
        var prefixRange = CFRange(location: 0, length: end)
        guard let argument = AXValueCreate(.cfRange, &prefixRange) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, argument, &result
        ) == .success, let prefix = result as? String, prefix.utf16.count == end else { return nil }
        let selectedText = selection.length > 0
            ? stringAttributeValue(kAXSelectedTextAttribute as CFString, for: element)
            : ""
        guard let selectedText else { return nil }
        return LiveDictationRange.alignSelection(value: value, prefix: prefix, selectedText: selectedText)
    }

    func setLiveSelection(_ range: NSRange, in element: AXUIElement) -> Bool {
        var selection = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &selection) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }

    func setLiveSelectedText(_ text: String, in element: AXUIElement) -> Bool {
        replaceSelectedTextAttribute(in: element, with: text)
    }

    @MainActor
    func insertText(
        _ text: String,
        targetBundleIdentifier: String?,
        targetProcessID: pid_t?
    ) -> TextInsertionResult {
        let sanitized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty else {
            return TextInsertionResult(path: nil, errorMessage: "Cannot insert empty text.")
        }

        let copied = Self.copyTextToPasteboard(sanitized)
        let target = InsertionTarget(
            bundleIdentifier: targetBundleIdentifier,
            processID: targetProcessID
        )

        let focused = ensureTargetIsActive(target)
        print("🎯 Focus target result: \(focused)")

        if focused,
           let field = beginLiveDictation(processID: NSWorkspace.shared.frontmostApplication?.processIdentifier),
           let result = field.finish(sanitized) {
            // A verified write succeeds here. If the editor may already have
            // mutated text, a second insertion could duplicate the transcript.
            return result
        }

        // Paste the whole transcript in one operation. Editors can apply a
        // burst of synthetic Unicode events out of order.
        let strategies: [(path: TextInsertionPath, attempt: () -> Bool)] = [
            (.commandV, { copied && self.pasteUsingCommandV(target: target) }),
            (.unicodeKeyboard, { self.typeUsingUnicodeEvents(sanitized, target: target) }),
            (.accessibility, { self.insertTextViaAccessibility(sanitized, target: target) }),
            (.appleScript, { copied && self.pasteWithAppleScript(target: target) })
        ]

        for strategy in strategies where strategy.attempt() {
            return TextInsertionResult(path: strategy.path, errorMessage: nil)
        }

        return TextInsertionResult(
            path: nil,
            errorMessage: "All insertion paths failed for target bundle \(targetBundleIdentifier ?? "unknown")."
        )
    }

    private func isEditableTextRole(_ element: AXUIElement) -> Bool {
        guard let role = stringAttributeValue(kAXRoleAttribute as CFString, for: element) else { return false }
        return [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role)
            && stringAttributeValue(kAXSubroleAttribute as CFString, for: element) != kAXSecureTextFieldSubrole
    }

    private func insertTextViaAccessibility(_ text: String, target: InsertionTarget) -> Bool {
        guard AXIsProcessTrusted() else {
            print("⚠️ Accessibility not trusted for AX text insertion")
            return false
        }

        guard let focusedElement = resolvedFocusedElement(preferredAppPID: target.processID) else {
            print("⚠️ Could not resolve focused AX element")
            return false
        }

        let context = accessibilityTextContext(for: focusedElement)
        if context.exposesPlaceholderAsValue {
            print("⚠️ AX field is exposing placeholder as value; falling back to keyboard insertion")
            return false
        }

        if context.hasSelection {
            if replaceSelectedTextAttribute(in: focusedElement, with: text) {
                return true
            }

            if replaceSelectedTextRange(in: focusedElement, with: text) {
                return true
            }
        }

        if context.isEmptyField {
            if replaceSelectedTextAttribute(in: focusedElement, with: text) {
                return true
            }

            if replaceEmptyValue(in: focusedElement, with: text) {
                return true
            }
        }

        return false
    }

    private func resolvedFocusedElement(preferredAppPID: pid_t?) -> AXUIElement? {
        if let preferredAppPID,
           preferredAppPID != 0,
           preferredAppPID != getpid(),
           let focusedElement = focusedElement(inApplicationPID: preferredAppPID) {
            return focusedElement
        }

        if let systemFocused = focusedElementFromSystemWide(),
           systemFocused.pid != getpid() {
            return systemFocused.element
        }

        return nil
    }

    private func accessibilityTextContext(for element: AXUIElement) -> AccessibilityTextContext {
        AccessibilityTextContext(
            currentValue: stringAttributeValue(kAXValueAttribute as CFString, for: element),
            placeholderValue: stringAttributeValue(
                NSAccessibility.Attribute.placeholderValue.rawValue as CFString,
                for: element
            ),
            selectedRange: selectedTextRange(for: element)
        )
    }

    private func focusedElementFromSystemWide() -> (element: AXUIElement, pid: pid_t)? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedObject: CFTypeRef?
        let focusedResult = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedObject
        )

        guard focusedResult == .success, let focusedObject else {
            return nil
        }

        let element = unsafeDowncast(focusedObject, to: AXUIElement.self)
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else {
            return nil
        }
        return (element, pid)
    }

    private func focusedElement(inApplicationPID pid: pid_t) -> AXUIElement? {
        let application = AXUIElementCreateApplication(pid)
        var focusedObject: CFTypeRef?
        let focusedResult = AXUIElementCopyAttributeValue(
            application,
            kAXFocusedUIElementAttribute as CFString,
            &focusedObject
        )
        guard focusedResult == .success, let focusedObject else {
            return nil
        }
        return unsafeDowncast(focusedObject, to: AXUIElement.self)
    }

    private func ensureTargetIsActive(
        _ target: InsertionTarget
    ) -> Bool {
        guard let targetApp = preferredTargetApplication(for: target) else {
            guard let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
                return false
            }
            return frontmostPID != getpid()
        }

        let targetPID = targetApp.processIdentifier
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID {
            return true
        }

        targetApp.activate(options: [])
        let deadline = Date().addingTimeInterval(0.12)
        while Date() < deadline {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID {
                return true
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }

        return NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID
    }

    private func preferredTargetApplication(for target: InsertionTarget) -> NSRunningApplication? {
        if let processID = target.processID,
           processID != 0,
           processID != getpid(),
           let application = NSRunningApplication(processIdentifier: processID) {
            return application
        }

        if let bundleIdentifier = target.bundleIdentifier {
            return NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleIdentifier
            ).first(where: { $0.processIdentifier != getpid() })
        }

        return nil
    }

    private func replaceSelectedTextRange(in element: AXUIElement, with text: String) -> Bool {
        guard let currentValue = stringValue(for: element),
              let selectedRange = selectedTextRange(for: element) else {
            return false
        }

        let currentValueNSString = currentValue as NSString
        let safeLocation = min(max(0, selectedRange.location), currentValueNSString.length)
        let safeLength = min(max(0, selectedRange.length), currentValueNSString.length - safeLocation)
        let replaced = currentValueNSString.replacingCharacters(
            in: NSRange(location: safeLocation, length: safeLength),
            with: text
        )

        guard AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            replaced as CFTypeRef
        ) == .success else {
            return false
        }

        var cursorRange = CFRange(location: safeLocation + (text as NSString).length, length: 0)
        if let newSelection = AXValueCreate(.cfRange, &cursorRange) {
            _ = AXUIElementSetAttributeValue(
                element,
                kAXSelectedTextRangeAttribute as CFString,
                newSelection
            )
        }

        return true
    }

    private func replaceSelectedTextAttribute(in element: AXUIElement, with text: String) -> Bool {
        setStringAttribute(
            kAXSelectedTextAttribute as CFString,
            to: text,
            in: element,
            failureLabel: "AX selected text set failed"
        )
    }

    private func replaceEmptyValue(in element: AXUIElement, with text: String) -> Bool {
        guard let currentValue = stringValue(for: element), currentValue.isEmpty else {
            return false
        }
        return setStringAttribute(
            kAXValueAttribute as CFString,
            to: text,
            in: element,
            failureLabel: "AX value set failed"
        )
    }

    private func stringValue(for element: AXUIElement) -> String? {
        stringAttributeValue(kAXValueAttribute as CFString, for: element)
    }

    private func selectedTextRange(for element: AXUIElement) -> CFRange? {
        var selectedRangeObject: CFTypeRef?
        let selectedRangeStatus = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &selectedRangeObject
        )

        guard selectedRangeStatus == .success,
              let selectedRangeObject,
              CFGetTypeID(selectedRangeObject) == AXValueGetTypeID()
        else {
            return nil
        }

        let selectedRangeValue = unsafeDowncast(selectedRangeObject, to: AXValue.self)
        guard AXValueGetType(selectedRangeValue) == .cfRange else {
            return nil
        }

        var selectedRange = CFRange()
        guard AXValueGetValue(selectedRangeValue, .cfRange, &selectedRange) else {
            return nil
        }

        return selectedRange
    }

    private func stringAttributeValue(_ attribute: CFString, for element: AXUIElement) -> String? {
        var valueObject: CFTypeRef?
        let valueStatus = AXUIElementCopyAttributeValue(
            element,
            attribute,
            &valueObject
        )

        guard valueStatus == .success, let valueObject else {
            return nil
        }

        return valueObject as? String
    }

    private func isAttributeSettable(_ attribute: CFString, in element: AXUIElement) -> Bool {
        var isSettable = DarwinBoolean(false)
        let result = AXUIElementIsAttributeSettable(element, attribute, &isSettable)
        return result == .success && isSettable.boolValue
    }

    private func setStringAttribute(
        _ attribute: CFString,
        to value: String,
        in element: AXUIElement,
        failureLabel: String
    ) -> Bool {
        guard isAttributeSettable(attribute, in: element) else {
            return false
        }

        let result = AXUIElementSetAttributeValue(
            element,
            attribute,
            value as CFTypeRef
        )
        if result != .success {
            print("⚠️ \(failureLabel) (\(result.rawValue))")
        }
        return result == .success
    }

    private func typeUsingUnicodeEvents(
        _ text: String,
        target: InsertionTarget
    ) -> Bool {
        guard ensureTargetIsActive(target) else { return false }

        return postUnicodeText(text)
    }

    @MainActor
    func selectLiveTextBackward(_ characterCount: Int, processID: pid_t) -> Bool {
        guard characterCount > 0,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == processID,
              let down = CGEvent(keyboardEventSource: nil, virtualKey: 123, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 123, keyDown: false) else { return false }
        down.flags = .maskShift
        up.flags = .maskShift
        for _ in 0..<characterCount {
            down.post(tap: .cgAnnotatedSessionEventTap)
            up.post(tap: .cgAnnotatedSessionEventTap)
        }
        return true
    }

    @MainActor
    func typeLiveText(_ text: String, processID: pid_t) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == processID else { return false }
        if text.isEmpty {
            guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 51, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 51, keyDown: false) else { return false }
            keyDown.flags = []
            keyUp.flags = []
            keyDown.post(tap: .cgAnnotatedSessionEventTap)
            keyUp.post(tap: .cgAnnotatedSessionEventTap)
            return true
        }
        return postUnicodeText(text)
    }

    private func postUnicodeText(_ text: String) -> Bool {
        guard !text.isEmpty,
              let source = CGEventSource(stateID: .combinedSessionState) else {
            return false
        }

        var didPostAnyEvent = false
        let utf16 = Array(text.utf16)
        let chunkSize = 20

        for start in stride(from: 0, to: utf16.count, by: chunkSize) {
            let end = min(start + chunkSize, utf16.count)
            var chunk = Array(utf16[start ..< end])

            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                continue
            }

            keyDown.flags = []
            keyUp.flags = []
            keyDown.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            keyUp.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            keyDown.post(tap: .cgAnnotatedSessionEventTap)
            keyUp.post(tap: .cgAnnotatedSessionEventTap)
            didPostAnyEvent = true
        }

        return didPostAnyEvent
    }

    private func pasteUsingCommandV(target: InsertionTarget) -> Bool {
        guard ensureTargetIsActive(target) else {
            return false
        }

        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            print("⚠️ Failed to create Command-V CGEvents")
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        keyUp.post(tap: .cgAnnotatedSessionEventTap)

        return true
    }

    private func pasteWithAppleScript(target: InsertionTarget) -> Bool {
        guard ensureTargetIsActive(target) else {
            return false
        }

        let scriptSource = """
        tell application "System Events"
            keystroke "v" using {command down}
        end tell
        """

        guard let script = NSAppleScript(source: scriptSource) else {
            return false
        }

        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            print("⚠️ AppleScript paste failed: \(errorInfo)")
            return false
        }
        return true
    }

    @MainActor
    @discardableResult
    static func copyTextToPasteboard(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        let item = NSPasteboardItem()
        guard item.setString(text, forType: .string) else { return false }
        pasteboard.clearContents()
        let copied = pasteboard.writeObjects([item])
        if !copied {
            print("⚠️ Failed to copy transcript to pasteboard")
        }
        return copied
    }
}
