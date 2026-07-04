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

    func updateRecordingShortcut(_ shortcut: RecordingShortcut) {
        recordingShortcut = shortcut
        AppSettingsStore.recordingShortcut = shortcut
        HotKeyManager.updateToggleRecordingHotKey(
            into: &toggleHotKeyRef,
            keyCode: shortcut.keyCode,
            modifiers: shortcut.carbonModifiers
        )
    }
}
