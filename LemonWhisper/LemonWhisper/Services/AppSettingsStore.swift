import Foundation

/// Persists user-configurable settings (microphone, recording shortcut) across launches.
enum AppSettingsStore {
    static var defaults = UserDefaults.standard
    private static let recordingShortcutKey = "recordingShortcut"
    private static let selectedMicrophoneUniqueIDKey = "selectedMicrophoneUniqueID"
    private static let modelLoadingModeKey = "modelLoadingMode"
    private static let modelIdleTimeoutKey = "modelIdleTimeout"

    /// How the transcription model is kept in memory. Defaults to `.fast` to preserve prior behavior.
    static var modelLoadingMode: ModelLoadingMode {
        get {
            guard let raw = defaults.string(forKey: modelLoadingModeKey),
                  let mode = ModelLoadingMode(rawValue: raw) else {
                return .fast
            }
            return mode
        }
        set { defaults.set(newValue.rawValue, forKey: modelLoadingModeKey) }
    }

    /// Inactivity window before the model is unloaded in lazy mode. Defaults to 1 minute.
    static var modelIdleTimeout: ModelIdleTimeout {
        get {
            guard let raw = defaults.string(forKey: modelIdleTimeoutKey),
                  let value = ModelIdleTimeout(rawValue: raw) else {
                return .oneMinute
            }
            return value
        }
        set { defaults.set(newValue.rawValue, forKey: modelIdleTimeoutKey) }
    }

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
