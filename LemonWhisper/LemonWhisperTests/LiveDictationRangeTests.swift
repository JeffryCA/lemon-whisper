import Foundation
import Testing
@testable import LemonWhisper

struct LiveDictationRangeTests {
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
}
