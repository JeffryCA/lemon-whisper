import Foundation
import Testing
@testable import LemonWhisper

@Suite(.serialized)
struct AppSettingsStoreTests {

    @Test func defaultRecordingShortcutMatchesPreviousHardcodedShortcut() {
        withTemporaryDefaults { _ in
            let shortcut = AppSettingsStore.recordingShortcuts.first

            #expect(shortcut?.usesControl == true)
            #expect(shortcut?.usesCommand == false)
            #expect(shortcut?.usesShift == false)
            #expect(shortcut?.usesOption == false)
            #expect(shortcut?.character == "y")
            #expect(shortcut?.displayString == "⌃Y")
        }
    }

    @Test func recordingShortcutsRoundTripThroughUserDefaults() {
        withTemporaryDefaults { _ in
            let custom = RecordingShortcut(
                keyCode: 15,
                character: "r",
                usesCommand: true,
                usesShift: true,
                usesOption: false,
                usesControl: false
            )

            AppSettingsStore.recordingShortcuts = [.default, custom]
            let loaded = AppSettingsStore.recordingShortcuts

            #expect(loaded == [.default, custom])
            #expect(loaded.last?.displayString == "⇧⌘R")
        }
    }

    @Test func legacySingleRecordingShortcutMigrates() {
        withTemporaryDefaults { defaults in
            let legacy = RecordingShortcut(
                keyCode: 15,
                character: "r",
                usesCommand: true,
                usesShift: false,
                usesOption: false,
                usesControl: false
            )
            defaults.set(try? JSONEncoder().encode(legacy), forKey: "recordingShortcut")

            #expect(AppSettingsStore.recordingShortcuts == [legacy])
        }
    }

    @Test func selectedMicrophoneUniqueIDRoundTripsThroughUserDefaults() {
        withTemporaryDefaults { _ in
            #expect(AppSettingsStore.selectedMicrophoneUniqueID == nil)

            AppSettingsStore.selectedMicrophoneUniqueID = "com.example.mic"
            #expect(AppSettingsStore.selectedMicrophoneUniqueID == "com.example.mic")

            AppSettingsStore.selectedMicrophoneUniqueID = nil
            #expect(AppSettingsStore.selectedMicrophoneUniqueID == nil)
        }
    }

    @Test func recordingIndicatorDefaultsOffAndRoundTrips() {
        withTemporaryDefaults { _ in
            #expect(!AppSettingsStore.recordingIndicatorEnabled)
            AppSettingsStore.recordingIndicatorEnabled = true
            #expect(AppSettingsStore.recordingIndicatorEnabled)
        }
    }

    @Test func modelLoadingModeDefaultsToFastAndRoundTrips() {
        withTemporaryDefaults { _ in
            #expect(AppSettingsStore.modelLoadingMode == .fast)

            AppSettingsStore.modelLoadingMode = .lazy
            #expect(AppSettingsStore.modelLoadingMode == .lazy)
        }
    }

    @Test func modelIdleTimeoutDefaultsToOneMinuteAndRoundTrips() {
        withTemporaryDefaults { _ in
            #expect(AppSettingsStore.modelIdleTimeout == .oneMinute)
            #expect(AppSettingsStore.modelIdleTimeout.seconds == 60)

            AppSettingsStore.modelIdleTimeout = .thirtySeconds
            #expect(AppSettingsStore.modelIdleTimeout == .thirtySeconds)
            #expect(AppSettingsStore.modelIdleTimeout.seconds == 30)
        }
    }

    private func withTemporaryDefaults(_ body: (UserDefaults) -> Void) {
        let suiteName = "LemonWhisperTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let previousDefaults = AppSettingsStore.defaults
        AppSettingsStore.defaults = defaults
        defer {
            AppSettingsStore.defaults = previousDefaults
            defaults.removePersistentDomain(forName: suiteName)
        }
        body(defaults)
    }
}
