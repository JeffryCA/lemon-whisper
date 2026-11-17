import Foundation
import Testing
@testable import LemonWhisper

struct LiveDictationRangeTests {
    @Test func recognizesAComposerPlaceholderFollowedByAParagraphSeparator() throws {
        let hint = "Ask Open Research"
        let emptyCaret = NSRange(location: 0, length: 0)
        let value = TextInsertionService.editableValue(
            hint + "\n", placeholder: hint, selection: emptyCaret, bundleIdentifier: nil
        )
        var range = try #require(LiveDictationRange(value: value, selection: emptyCaret))
        let transcript = "A live transcript"
        range.apply(transcript, to: range.dictatedRange)
        #expect(range.matches(value: transcript, selection: NSRange(location: transcript.utf16.count, length: 0)))
        #expect(TextInsertionService.editableValue(
            hint + "\n", placeholder: hint, selection: NSRange(location: hint.utf16.count, length: 0),
            bundleIdentifier: nil
        ) == hint + "\n")
    }

    @Test func manualEditsRetainAllAudioUntilLiveDictationHasInsertedText() {
        let start = Date(timeIntervalSince1970: 1_000)
        let firstEdit = start.addingTimeInterval(5)
        let secondEdit = start.addingTimeInterval(10)
        let thirdEdit = start.addingTimeInterval(15)
        var progress = LiveDictationProgress()

        progress.fieldEdited(transcript: nil, at: 240_000, time: firstEdit, recordingStartedAt: start)
        #expect(progress.audioStartFrame == 0)
        #expect(progress.restartedAt == nil)
        #expect(progress.history.isEmpty)

        progress.fieldEdited(
            transcript: .init(original: "Full recording", corrected: "Full recording", path: .unicodeKeyboard),
            at: 480_000, time: secondEdit, recordingStartedAt: start
        )
        #expect(progress.audioStartFrame == 480_000)
        #expect(progress.restartedAt == secondEdit)
        #expect(progress.history.map(\.startedAt) == [start])

        progress.fieldEdited(transcript: nil, at: 720_000, time: thirdEdit, recordingStartedAt: start)
        #expect(progress.audioStartFrame == 480_000)
        #expect(progress.restartedAt == secondEdit)
        #expect(progress.history.count == 1)
    }

    @Test func appendsThenReplacesOnlyTheDictatedSpan() throws {
        let prefix = "Before 🎙️ "
        let suffix = " after"
        let selection = NSRange(location: prefix.utf16.count, length: "selected".utf16.count)
        var range = try #require(LiveDictationRange(value: prefix + "selected" + suffix, selection: selection))

        range.apply("hello", to: range.expectedSelection)
        range.apply(" there 🌍", to: range.expectedSelection)

        #expect(range.expectedValue == prefix + "hello there 🌍" + suffix)
        #expect(range.originalSelectionText == "selected")
        #expect(range.dictatedRange == NSRange(location: selection.location, length: "hello there 🌍".utf16.count))
        #expect(!range.matches(value: range.expectedValue, selection: NSRange(location: 0, length: 0)))
        #expect(!range.matches(value: "New text " + range.expectedValue, selection: range.expectedSelection))

        range.apply("Hello there.", to: range.dictatedRange)
        #expect(range.expectedValue == prefix + "Hello there." + suffix)
        #expect(range.expectedSelection == NSRange(location: prefix.utf16.count + "Hello there.".utf16.count, length: 0))
    }
    @Test func revisesAnInitiallyEmptyFieldAndAcceptsWebEditorSpaces() throws {
        var range = try #require(LiveDictationRange(value: "", selection: NSRange(location: 0, length: 0)))
        range.apply("One.", to: range.dictatedRange)
        range.apply("One two.", to: range.dictatedRange)

        #expect(range.expectedValue == "One two.")
        #expect(range.matches(value: "One\u{00A0}two.", selection: range.expectedSelection))
        #expect(!range.matches(value: "One two.", selection: NSRange(location: 0, length: 0)))
    }

    @Test func revisesDictationOnABlankObsidianLine() throws {
        var range = try #require(LiveDictationRange(
            value: "Before\nAfter\n", selection: NSRange(location: 6, length: 0)
        ))
        let first = "One 🌍."
        range.apply(first, to: range.dictatedRange)
        let value = "Before\n\(first)\nAfter\n"
        let selection = try #require(LiveDictationRange.alignSelection(
            value: value, prefix: "Before\(first)", selectedText: ""
        ))

        let acceptedEditedSuffix = range.reconcileObservedWrite(
            value: "Before\n\(first)\nEdited\n", selection: selection, insertedText: first
        )
        #expect(!acceptedEditedSuffix)
        let acceptedInsertion = range.reconcileObservedWrite(value: value, selection: selection, insertedText: first)
        #expect(acceptedInsertion)
        #expect(range.dictatedRange == NSRange(location: 7, length: first.utf16.count))
        #expect(LiveDictationRange.alignSelection(
            value: value, prefix: "Before\(first)", selectedText: first
        ) == range.dictatedRange)
        #expect(LiveDictationRange.alignSelection(
            value: value, prefix: "Before\(first)", selectedText: "Before"
        ) == nil)

        range.apply("One and two.", to: range.dictatedRange)
        #expect(range.expectedValue == "Before\nOne and two.\nAfter\n")
    }

    @Test func verifiesSmartQuotesWithinTheDictatedSpan() throws {
        let prefix = "Sam's note: "
        let suffix = " Next item"
        let first = "It's."
        let revised = "It's working."
        let selection = NSRange(location: prefix.utf16.count, length: 0)
        var range = try #require(LiveDictationRange(value: prefix + suffix, selection: selection))
        range.apply(first, to: selection)
        let caret = range.expectedSelection

        let editedPrefix = range.reconcileObservedWrite(
            value: "Sam’s note: It’s." + suffix, selection: caret, insertedText: first
        )
        #expect(!editedPrefix)
        let accepted = range.reconcileObservedWrite(
            value: prefix + "It’s." + suffix, selection: caret, insertedText: first
        )
        #expect(accepted)

        let revision = range.revision(from: first, to: revised)
        range.apply(revision.text, to: revision.range)
        #expect(range.matches(value: prefix + "It’s working." + suffix, selection: range.expectedSelection))
    }

    @Test func revisesOnlyTheChangedSuffixOfALongDictation() throws {
        let prefix = "Before\n"
        let suffix = "\nAfter"
        let shared = String(repeating: "A thought about work. ", count: 25) + "Then 🎙️"
        let previous = shared + " imagine"
        var span = try #require(LiveDictationRange(
            value: prefix + suffix, selection: NSRange(location: prefix.utf16.count, length: 0)
        ))
        span.apply(previous, to: span.dictatedRange)

        let appended = span.revision(from: previous, to: previous + " more")
        #expect(appended.range == span.expectedSelection)
        #expect(appended.backtrack == 0)
        #expect(appended.text == " more")

        let revision = span.revision(from: previous, to: shared + " create.")
        #expect(revision.range == NSRange(location: (prefix + shared + " ").utf16.count, length: 7))
        #expect(revision.backtrack == 7)
        #expect(revision.text == "create.")
        span.apply(revision.text, to: revision.range)
        #expect(span.expectedValue == prefix + shared + " create." + suffix)
    }
}
