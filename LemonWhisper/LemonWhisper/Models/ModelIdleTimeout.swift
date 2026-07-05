import Foundation

/// How long the model stays resident with no activity before lazy mode unloads it.
enum ModelIdleTimeout: String, CaseIterable, Identifiable {
    case thirtySeconds
    case oneMinute
    case twoMinutes
    case fiveMinutes

    var id: String { rawValue }

    /// Seconds of inactivity before the model is unloaded.
    var seconds: TimeInterval {
        switch self {
        case .thirtySeconds: return 30
        case .oneMinute: return 60
        case .twoMinutes: return 120
        case .fiveMinutes: return 300
        }
    }

    var title: String {
        switch self {
        case .thirtySeconds: return "30 seconds"
        case .oneMinute: return "1 minute"
        case .twoMinutes: return "2 minutes"
        case .fiveMinutes: return "5 minutes"
        }
    }
}
