import Foundation

/// Persists user-configurable settings (microphone, recording shortcut) across launches.
enum AppSettingsStore {
    static var defaults = UserDefaults.standard
    private static let recordingShortcutKey = "recordingShortcut"
    private static let selectedMicrophoneUniqueIDKey = "selectedMicrophoneUniqueID"

    static var recordingShortcut: RecordingShortcut {
        get {
            guard let data = defaults.data(forKey: recordingShortcutKey),
                  let decoded = try? JSONDecoder().decode(RecordingShortcut.self, from: data) else {
                return .default
            }
            return decoded
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: recordingShortcutKey)
        }
    }

    /// `nil` means "use the system default input device".
    static var selectedMicrophoneUniqueID: String? {
        get { defaults.string(forKey: selectedMicrophoneUniqueIDKey) }
        set { defaults.set(newValue, forKey: selectedMicrophoneUniqueIDKey) }
    }
}
