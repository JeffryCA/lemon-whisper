import ApplicationServices
import Foundation

/// Tracks only the span inserted by this recording. AX ranges count UTF-16 code units.
struct LiveDictationRange {
    private(set) var expectedValue: String
    private(set) var dictatedRange: NSRange
    private(set) var expectedSelection: NSRange
    let originalSelectionText: String
    private(set) var hasWritten = false

    init?(value: String, selection: NSRange) {
        guard Range(selection, in: value) != nil else { return nil }
        expectedValue = value
        dictatedRange = selection
        expectedSelection = selection
        originalSelectionText = (value as NSString).substring(with: selection)
    }

    func matches(value: String, selection: NSRange) -> Bool {
        matchesText(value) && selection == expectedSelection
    }

    func matchesText(_ value: String) -> Bool {
        // Web editors represent some ordinary spaces as nonbreaking spaces in AXValue.
        value.replacingOccurrences(of: "\u{00A0}", with: " ").utf16.elementsEqual(
            expectedValue.replacingOccurrences(of: "\u{00A0}", with: " ").utf16
        )
    }

    mutating func apply(_ text: String, to range: NSRange) {
        expectedValue = (expectedValue as NSString).replacingCharacters(in: range, with: text)
        dictatedRange.length = range.location - dictatedRange.location + text.utf16.count
        expectedSelection = NSRange(location: NSMaxRange(dictatedRange), length: 0)
        hasWritten = true
    }
}

/// Writes only to the verified dictated span in the original focused field.
@MainActor
final class LiveDictationInsertion {
    private let service: TextInsertionService
    private let element: AXUIElement
    private let processID: pid_t
    private var span: LiveDictationRange
    private var fieldChanged = false
    private var writeWasUnverified = false
    private var usesKeyboard = false
    private var insertedText = ""

    init(service: TextInsertionService, element: AXUIElement, processID: pid_t, span: LiveDictationRange) {
        self.service = service
        self.element = element
        self.processID = processID
        self.span = span
    }

    enum FieldChange { case unchanged, caretMoved, edited, unavailable }

    var fieldChange: FieldChange {
        guard let state = service.liveFieldState(for: element, processID: processID) else { return .unavailable }
        if !span.matchesText(state.value) { return writeWasUnverified ? .unavailable : .edited }
        return state.selection == span.expectedSelection ? .unchanged : .caretMoved
    }

    func nextSegment() -> LiveDictationInsertion? {
        guard let state = service.liveFieldState(for: element, processID: processID),
              let newSpan = LiveDictationRange(value: state.value, selection: state.selection) else { return nil }
        return LiveDictationInsertion(service: service, element: element, processID: processID, span: newSpan)
    }

    func update(_ text: String) async -> Bool {
        guard validate() else { return false }
        if text.utf16.elementsEqual(insertedText.utf16) { return true }
        guard await writeLive(text, in: span.dictatedRange) != nil else { return false }
        insertedText = text
        return true
    }

    func finishLive(_ text: String) async -> TextInsertionResult? {
        guard validate() else { return canUseStandardPaste ? nil : interrupted }
        if span.hasWritten, text.utf16.elementsEqual(insertedText.utf16) {
            return .init(path: usesKeyboard ? .unicodeKeyboard : .accessibility, errorMessage: nil)
        }
        if let path = await writeLive(text, in: span.dictatedRange) {
            return .init(path: path, errorMessage: nil)
        }
        return canUseStandardPaste ? nil : interrupted
    }

    func discardLive() async {
        guard span.hasWritten, validate() else { return }
        let original = span.originalSelectionText
        let restore = NSRange(location: span.dictatedRange.location, length: original.utf16.count)
        if await writeLive(original, in: span.dictatedRange) != nil, restore.length > 0 {
            _ = service.setLiveSelection(restore, in: element)
        }
    }

    func finish(_ text: String) -> TextInsertionResult? {
        guard validate() else {
            // A session that never changed the document can use ordinary paste.
            return canUseStandardPaste ? nil : interrupted
        }
        if span.hasWritten, text.utf16.elementsEqual(insertedText.utf16) {
            return .init(path: .accessibility, errorMessage: nil)
        }

        let range = span.dictatedRange
        if write(text, in: range) {
            return .init(path: .accessibility, errorMessage: nil)
        }
        return canUseStandardPaste ? nil : interrupted
    }

    private var canUseStandardPaste: Bool {
        !span.hasWritten && !writeWasUnverified
    }

    private var interrupted: TextInsertionResult {
        .init(path: nil, errorMessage: "The focused field changed or could not apply the final edit. The transcript is in History.")
    }

    private func validate() -> Bool {
        guard !fieldChanged, !writeWasUnverified,
              let state = service.liveFieldState(for: element, processID: processID),
              span.matches(value: state.value, selection: state.selection) else {
            fieldChanged = true
            return false
        }
        return true
    }

    private func writeLive(_ text: String, in range: NSRange) async -> TextInsertionPath? {
        if !usesKeyboard, !span.expectedValue.isEmpty {
            if write(text, in: range) { return .accessibility }
            guard validate() else { return nil }
        }

        let startingSelection = span.expectedSelection
        if range != startingSelection {
            // Web editors may acknowledge AX selection changes without moving
            // the caret. Select backwards only from the verified end of our span.
            guard startingSelection.length == 0, startingSelection.location == NSMaxRange(range),
                  service.selectLiveTextBackward(insertedText.count, processID: processID) else {
                return nil
            }
            for _ in 0..<10 {
                try? await Task.sleep(for: .milliseconds(15))
                guard let current = service.liveFieldState(for: element, processID: processID),
                      span.matchesText(current.value) else { break }
                if current.selection == range { break }
            }
        }
        guard let state = service.liveFieldState(for: element, processID: processID),
              span.matchesText(state.value),
              state.selection == range else {
            fieldChanged = true
            return nil
        }
        guard service.typeLiveText(text, processID: processID) else {
            if range != startingSelection { _ = service.setLiveSelection(startingSelection, in: element) }
            return nil
        }

        // Keyboard input is asynchronous in web editors. Check the actual text
        // and caret before allowing another batch or replacing this span.
        var updated = span
        updated.apply(text, to: range)
        for _ in 0..<15 {
            try? await Task.sleep(for: .milliseconds(20))
            guard let current = service.liveFieldState(for: element, processID: processID) else { break }
            if updated.matches(value: current.value, selection: current.selection) {
                usesKeyboard = true
                span = updated
                return .unicodeKeyboard
            }
        }
        // The events may still have reached the editor. Avoid a second insertion.
        writeWasUnverified = true
        return nil
    }

    private func write(_ text: String, in range: NSRange) -> Bool {
        let changedSelection = range != span.expectedSelection
        if changedSelection {
            guard service.setLiveSelection(range, in: element),
                  let state = service.liveFieldState(for: element, processID: processID),
                  state.selection == range,
                  span.matchesText(state.value) else {
                return false
            }
        }
        guard service.setLiveSelectedText(text, in: element) else {
            if changedSelection { _ = service.setLiveSelection(span.expectedSelection, in: element) }
            return false
        }
        var updated = span
        updated.apply(text, to: range)
        guard let state = service.liveFieldState(for: element, processID: processID) else {
            writeWasUnverified = true
            return false
        }
        guard updated.matchesText(state.value) else {
            // Some editors acknowledge AXSelectedText without applying the edit.
            // Permit regular paste only if a fresh read confirms nothing changed.
            writeWasUnverified = !span.matchesText(state.value)
            if changedSelection && !writeWasUnverified && state.selection == range {
                _ = service.setLiveSelection(span.expectedSelection, in: element)
            }
            return false
        }
        span = updated
        if state.selection != updated.expectedSelection,
           state.selection == NSRange(location: NSMaxRange(range), length: 0) || state.selection == range {
            _ = service.setLiveSelection(updated.expectedSelection, in: element)
        }
        return true
    }
}
