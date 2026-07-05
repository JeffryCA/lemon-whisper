import Foundation

/// Controls how aggressively the selected transcription model is kept in memory.
enum ModelLoadingMode: String, CaseIterable, Identifiable {
    /// Load the model at startup and keep it resident. Fastest transcriptions, highest memory use.
    case fast
    /// Skip startup loading and free the model after a period of inactivity. Lower memory, slower first transcription.
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
        case .fast:
            return "Fast"
        case .lazy:
            return "Lazy"
        }
    }
}
