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
        Self.sameText(value, expectedValue)
    }

    private static func sameText(_ lhs: String, _ rhs: String) -> Bool {
        lhs.replacingOccurrences(of: "\u{00A0}", with: " ").utf16.elementsEqual(
            rhs.replacingOccurrences(of: "\u{00A0}", with: " ").utf16
        )
    }

    /// Some editors count line separators differently in AXValue and AX ranges.
    /// Align AXStringForRange's text up to the caret to AXValue.
    static func alignSelection(value: String, prefix: String, selectedText: String) -> NSRange? {
        var valueUnits = value.utf16.makeIterator()
        var end = 0
        for unit in prefix.utf16 {
            var observed = valueUnits.next()
            end += 1
            while observed == 0x0A, observed != unit {
                observed = valueUnits.next()
                end += 1
            }
            guard observed == unit else { return nil }
        }
        let length = selectedText.utf16.count
        guard end >= length else { return nil }
        let range = NSRange(location: end - length, length: length)
        guard let indices = Range(range, in: value),
              sameText(String(value[indices]), selectedText) else { return nil }
        return range
    }

    /// Verify editor formatting of the inserted text and adjacent line boundaries.
    mutating func reconcileObservedWrite(
        value: String, selection: NSRange, insertedText: String
    ) -> Bool {
        let length = insertedText.utf16.count
        let observed = value as NSString
        guard selection.length == 0, selection.location >= length, selection.location <= observed.length else {
            return false
        }
        let range = NSRange(location: selection.location - length, length: length)
        guard observed.substring(with: range).utf16.elementsEqual(insertedText.utf16, by: { lhs, rhs in
            Self.insertionCodeUnit(lhs) == Self.insertionCodeUnit(rhs)
        }) else { return false }

        let expected = expectedValue as NSString
        let expectedPrefix = expected.substring(to: dictatedRange.location)
        let observedPrefix = observed.substring(to: range.location)
        let expectedSuffix = expected.substring(from: NSMaxRange(dictatedRange))
        let observedSuffix = observed.substring(from: NSMaxRange(range))
        let stripTrailingNewlines = #"\n+\z"#
        let stripLeadingNewlines = #"\A\n+"#
        guard Self.sameText(
            expectedPrefix.replacingOccurrences(of: stripTrailingNewlines, with: "", options: .regularExpression),
            observedPrefix.replacingOccurrences(of: stripTrailingNewlines, with: "", options: .regularExpression)
        ), Self.sameText(
            expectedSuffix.replacingOccurrences(of: stripLeadingNewlines, with: "", options: .regularExpression),
            observedSuffix.replacingOccurrences(of: stripLeadingNewlines, with: "", options: .regularExpression)
        ) else { return false }

        expectedValue = value
        dictatedRange = range
        expectedSelection = selection
        return true
    }

    private static func insertionCodeUnit(_ unit: UInt16) -> UInt16 {
        switch unit {
        case 0x00A0: return 0x20 // Nonbreaking space
        case 0x2018, 0x2019: return 0x27 // Smart single quotes and apostrophes
        case 0x201C, 0x201D: return 0x22 // Smart double quotes
        default: return unit
        }
    }

    mutating func apply(_ text: String, to range: NSRange) {
        expectedValue = (expectedValue as NSString).replacingCharacters(in: range, with: text)
        dictatedRange.length = range.location - dictatedRange.location + text.utf16.count
        expectedSelection = NSRange(location: NSMaxRange(dictatedRange), length: 0)
        hasWritten = true
    }

    /// Keep the confirmed prefix in place and replace only the part that changed.
    func revision(from previous: String, to text: String) -> (range: NSRange, text: String, backtrack: Int) {
        var prefixUnits = 0
        var prefixCharacters = 0
        for (old, new) in zip(previous, text) {
            guard String(old).utf16.elementsEqual(String(new).utf16) else { break }
            prefixUnits += String(old).utf16.count
            prefixCharacters += 1
        }
        return (
            NSRange(location: dictatedRange.location + prefixUnits, length: dictatedRange.length - prefixUnits),
            String(text.dropFirst(prefixCharacters)),
            previous.dropFirst(prefixCharacters).count
        )
    }
}

/// Writes only to the verified dictated span in the original focused field.
@MainActor
final class LiveDictationInsertion {
    struct Transcript {
        let original: String
        let corrected: String
        let path: TextInsertionPath
    }

    private let service: TextInsertionService
    private let element: AXUIElement
    private let processID: pid_t
    private var span: LiveDictationRange
    private var fieldChanged = false
    private var writeWasUnverified = false
    private var usesKeyboard = false
    private var insertedText = ""
    private(set) var transcript: Transcript?

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

    func update(_ text: String, original: String? = nil) async -> Bool {
        guard validate() else { return false }
        if !text.utf16.elementsEqual(insertedText.utf16) {
            guard await writeLive(text, in: span.dictatedRange) != nil else { return false }
            insertedText = text
        }
        if let original, span.hasWritten {
            transcript = Transcript(original: original, corrected: text, path: usesKeyboard ? .unicodeKeyboard : .accessibility)
        }
        return true
    }

    func finishLive(_ text: String) async -> TextInsertionResult? {
        if !span.hasWritten {
            if !writeWasUnverified { return nil }
            // A live update may have posted events that the editor ignored.
            // After the final decode, retry through normal paste if the field
            // and caret still match the original state.
            if let state = service.liveFieldState(for: element, processID: processID),
               span.matches(value: state.value, selection: state.selection) { return nil }
        }
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
        guard let state = validatedState(), !state.prefersKeyboard else {
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

    private func validate() -> Bool { validatedState() != nil }

    private func validatedState() -> (value: String, selection: NSRange, prefersKeyboard: Bool)? {
        guard !fieldChanged, !writeWasUnverified,
              let state = service.liveFieldState(for: element, processID: processID),
              span.matches(value: state.value, selection: state.selection) else {
            fieldChanged = true
            return nil
        }
        return state
    }

    private func writeLive(_ text: String, in fullRange: NSRange) async -> TextInsertionPath? {
        guard let originalState = validatedState() else { return nil }
        if span.hasWritten, text.utf16.elementsEqual(insertedText.utf16) {
            return usesKeyboard ? .unicodeKeyboard : .accessibility
        }
        if !usesKeyboard, !originalState.prefersKeyboard, !span.expectedValue.isEmpty {
            if write(text, in: fullRange) { return .accessibility }
            guard validate() else { return nil }
        }

        let revision = span.hasWritten ? span.revision(from: insertedText, to: text) : (fullRange, text, 0)
        let (range, replacement, backtrack) = revision
        guard await selectForLiveWrite(range, backtrack: backtrack) else { return nil }
        guard let state = service.liveFieldState(for: element, processID: processID),
              span.matchesText(state.value),
              state.selection == range else {
            fieldChanged = true
            return nil
        }
        guard service.typeLiveText(replacement, processID: processID) else {
            if range != span.expectedSelection, !originalState.prefersKeyboard {
                _ = service.setLiveSelection(originalState.selection, in: element)
            }
            return nil
        }

        // Keyboard input is asynchronous in web editors. Check the actual text
        // and caret before allowing another batch or replacing this span.
        var updated = span
        updated.apply(replacement, to: range)
        let clock = ContinuousClock()
        let timeout = clock.now + .seconds(2)
        repeat {
            try? await Task.sleep(for: .milliseconds(20))
            guard let current = service.liveFieldState(for: element, processID: processID) else { break }
            if updated.matches(value: current.value, selection: current.selection)
                || updated.reconcileObservedWrite(
                    value: current.value, selection: current.selection, insertedText: text
                ) {
                usesKeyboard = true
                span = updated
                return .unicodeKeyboard
            }
        } while clock.now < timeout
        // The events may still have reached the editor. Avoid a second insertion.
        writeWasUnverified = true
        return nil
    }

    private func selectForLiveWrite(_ range: NSRange, backtrack: Int) async -> Bool {
        guard let state = validatedState() else { return false }
        if state.selection == range { return true }
        // Select from the real caret. An AX selection can silently include a
        // paragraph separator omitted from the editor's selected text.
        guard state.selection.length == 0, state.selection.location == NSMaxRange(range),
              service.selectLiveTextBackward(backtrack, processID: processID) else {
            return false
        }
        let clock = ContinuousClock()
        let timeout = clock.now + .seconds(2)
        repeat {
            try? await Task.sleep(for: .milliseconds(20))
            guard let current = service.liveFieldState(for: element, processID: processID),
                  span.matchesText(current.value) else { return false }
            if current.selection == range { return true }
        } while clock.now < timeout
        return false
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
        guard updated.matchesText(state.value)
                || updated.reconcileObservedWrite(
                    value: state.value, selection: state.selection, insertedText: text
                ) else {
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
