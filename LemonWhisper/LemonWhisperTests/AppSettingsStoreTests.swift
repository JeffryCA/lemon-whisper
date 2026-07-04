import Foundation
import Testing
@testable import LemonWhisper

@Suite(.serialized)
struct AppSettingsStoreTests {

    @Test func defaultRecordingShortcutMatchesPreviousHardcodedShortcut() {
        UserDefaults.standard.removeObject(forKey: "recordingShortcut")

        let shortcut = AppSettingsStore.recordingShortcut

        #expect(shortcut.usesControl)
        #expect(!shortcut.usesCommand)
        #expect(!shortcut.usesShift)
        #expect(!shortcut.usesOption)
        #expect(shortcut.character == "y")
        #expect(shortcut.displayString == "⌃Y")
    }

    @Test func recordingShortcutRoundTripsThroughUserDefaults() {
        defer { UserDefaults.standard.removeObject(forKey: "recordingShortcut") }

        let custom = RecordingShortcut(
            keyCode: 15,
            character: "r",
            usesCommand: true,
            usesShift: true,
            usesOption: false,
            usesControl: false
        )

        AppSettingsStore.recordingShortcut = custom
        let loaded = AppSettingsStore.recordingShortcut

        #expect(loaded == custom)
        #expect(loaded.displayString == "⇧⌘R")
    }

    @Test func selectedMicrophoneUniqueIDRoundTripsThroughUserDefaults() {
        defer { UserDefaults.standard.removeObject(forKey: "selectedMicrophoneUniqueID") }

        #expect(AppSettingsStore.selectedMicrophoneUniqueID == nil)

        AppSettingsStore.selectedMicrophoneUniqueID = "com.example.mic"
        #expect(AppSettingsStore.selectedMicrophoneUniqueID == "com.example.mic")

        AppSettingsStore.selectedMicrophoneUniqueID = nil
        #expect(AppSettingsStore.selectedMicrophoneUniqueID == nil)
    }
}
