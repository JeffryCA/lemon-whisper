import Carbon
import SwiftUI
import Testing
@testable import LemonWhisper

struct RecordingShortcutTests {

    @Test func carbonModifiersCombineFlags() {
        let shortcut = RecordingShortcut(
            keyCode: 0,
            character: "a",
            usesCommand: true,
            usesShift: false,
            usesOption: true,
            usesControl: false
        )

        #expect(shortcut.carbonModifiers == UInt32(cmdKey) | UInt32(optionKey))
    }

    @Test func swiftUIModifiersCombineFlags() {
        let shortcut = RecordingShortcut(
            keyCode: 0,
            character: "a",
            usesCommand: false,
            usesShift: true,
            usesOption: false,
            usesControl: true
        )

        #expect(shortcut.swiftUIModifiers == [.shift, .control])
    }

    @Test func displayStringOrdersModifiersConsistently() {
        let shortcut = RecordingShortcut(
            keyCode: 0,
            character: "y",
            usesCommand: true,
            usesShift: true,
            usesOption: true,
            usesControl: true
        )

        #expect(shortcut.displayString == "⌃⌥⇧⌘Y")
    }

    @Test func conflictUsesRegisteredKeyAndModifiers() {
        let first = RecordingShortcut(
            keyCode: 6,
            character: "z",
            usesCommand: false,
            usesShift: false,
            usesOption: false,
            usesControl: true
        )
        let samePhysicalShortcutOnAnotherLayout = RecordingShortcut(
            keyCode: 6,
            character: "y",
            usesCommand: false,
            usesShift: false,
            usesOption: false,
            usesControl: true
        )

        #expect(first.conflicts(with: samePhysicalShortcutOnAnotherLayout))
    }
}
