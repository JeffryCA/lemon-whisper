import Foundation

extension LemonWhisperController {
    func refreshAvailableMicrophones() {
        availableMicrophones = MicrophoneManager.availableDevices()
    }

    /// Pass `nil` to use the system default input device.
    func selectMicrophone(_ uniqueID: String?) {
        selectedMicrophoneID = uniqueID
        AppSettingsStore.selectedMicrophoneUniqueID = uniqueID
    }

    func updateRecordingShortcuts(_ shortcuts: [RecordingShortcut]) {
        let uniqueShortcuts = shortcuts.reduce(into: [RecordingShortcut]()) { result, shortcut in
            if !result.contains(where: { $0.conflicts(with: shortcut) }) {
                result.append(shortcut)
            }
        }
        guard !uniqueShortcuts.isEmpty else { return }

        recordingShortcuts = uniqueShortcuts
        AppSettingsStore.recordingShortcuts = uniqueShortcuts
        HotKeyManager.updateToggleRecordingHotKeys(
            into: &toggleHotKeyRefs,
            shortcuts: uniqueShortcuts
        )
    }

    func setRecordingIndicatorEnabled(_ enabled: Bool) {
        recordingIndicatorEnabled = enabled
        AppSettingsStore.recordingIndicatorEnabled = enabled

        guard isRecording else { return }
        RecordingPulseHUD.shared.showPulse(
            isRecording: enabled,
            persistUntilRecordingStops: enabled
        )
    }
}
