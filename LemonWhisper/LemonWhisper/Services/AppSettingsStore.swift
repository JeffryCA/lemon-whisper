import Foundation

/// Persists user-configurable settings across launches.
enum AppSettingsStore {
    static var defaults = UserDefaults.standard
    private static let recordingShortcutKey = "recordingShortcut"
    private static let recordingShortcutsKey = "recordingShortcuts"
    private static let selectedMicrophoneUniqueIDKey = "selectedMicrophoneUniqueID"
    private static let recordingIndicatorEnabledKey = "recordingIndicatorEnabled"
    private static let modelLoadingModeKey = "modelLoadingMode"
    private static let modelIdleTimeoutKey = "modelIdleTimeout"

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

    static var modelIdleTimeout: ModelIdleTimeout {
        get {
            guard let raw = defaults.string(forKey: modelIdleTimeoutKey),
                  let timeout = ModelIdleTimeout(rawValue: raw) else {
                return .oneMinute
            }
            return timeout
        }
        set { defaults.set(newValue.rawValue, forKey: modelIdleTimeoutKey) }
    }

    static var recordingShortcuts: [RecordingShortcut] {
        get {
            if let data = defaults.data(forKey: recordingShortcutsKey),
               let decoded = try? JSONDecoder().decode([RecordingShortcut].self, from: data),
               !decoded.isEmpty {
                return decoded
            }

            // Migrate the single-shortcut preference used by earlier releases.
            if let data = defaults.data(forKey: recordingShortcutKey),
               let decoded = try? JSONDecoder().decode(RecordingShortcut.self, from: data) {
                return [decoded]
            }

            return [.default]
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: recordingShortcutsKey)
        }
    }

    static var recordingIndicatorEnabled: Bool {
        get { defaults.bool(forKey: recordingIndicatorEnabledKey) }
        set { defaults.set(newValue, forKey: recordingIndicatorEnabledKey) }
    }

    /// `nil` means "use the system default input device".
    static var selectedMicrophoneUniqueID: String? {
        get { defaults.string(forKey: selectedMicrophoneUniqueIDKey) }
        set { defaults.set(newValue, forKey: selectedMicrophoneUniqueIDKey) }
    }
}
