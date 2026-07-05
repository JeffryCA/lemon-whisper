import Foundation
import Testing
@testable import LemonWhisper

@Suite(.serialized)
struct AppSettingsStoreTests {

    @Test func defaultRecordingShortcutMatchesPreviousHardcodedShortcut() {
        withTemporaryDefaults {
            let shortcut = AppSettingsStore.recordingShortcut

            #expect(shortcut.usesControl)
            #expect(!shortcut.usesCommand)
            #expect(!shortcut.usesShift)
            #expect(!shortcut.usesOption)
            #expect(shortcut.character == "y")
            #expect(shortcut.displayString == "⌃Y")
        }
    }

    @Test func recordingShortcutRoundTripsThroughUserDefaults() {
        withTemporaryDefaults {
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
    }

    @Test func selectedMicrophoneUniqueIDRoundTripsThroughUserDefaults() {
        withTemporaryDefaults {
            #expect(AppSettingsStore.selectedMicrophoneUniqueID == nil)

            AppSettingsStore.selectedMicrophoneUniqueID = "com.example.mic"
            #expect(AppSettingsStore.selectedMicrophoneUniqueID == "com.example.mic")

            AppSettingsStore.selectedMicrophoneUniqueID = nil
            #expect(AppSettingsStore.selectedMicrophoneUniqueID == nil)
        }
    }

    private func withTemporaryDefaults(_ body: () -> Void) {
        let suiteName = "LemonWhisperTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let previousDefaults = AppSettingsStore.defaults
        AppSettingsStore.defaults = defaults
        defer {
            AppSettingsStore.defaults = previousDefaults
            defaults.removePersistentDomain(forName: suiteName)
        }
        body()
    }
}
