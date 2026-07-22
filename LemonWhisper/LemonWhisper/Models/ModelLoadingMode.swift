import Foundation

/// Controls how aggressively the selected transcription model is kept in memory.
enum ModelLoadingMode: String, CaseIterable, Identifiable {
    case fast
    case lazy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fast:
            return "Fast (keep model in memory)"
        case .lazy:
            return "Lazy (free memory when idle)"
        }
    }

    var menuTitle: String {
        switch self {
        case .fast: return "Fast"
        case .lazy: return "Lazy"
        }
    }
}
