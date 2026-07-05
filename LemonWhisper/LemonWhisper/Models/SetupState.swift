enum SetupState: Equatable {
    case bootstrapping
    case ready
    case awaitingModelSelection(supportsVoxtral: Bool)
    case preparingSelectedModel
    case blocked(message: String)

    var isBlocking: Bool {
        switch self {
        case .bootstrapping, .ready:
            return false
        default:
            return true
        }
    }

    /// Recording is refused only when no usable model exists on disk. If a model is
    /// available we start optimistically, even while it is still loading into memory.
    var blocksRecording: Bool {
        switch self {
        case .awaitingModelSelection, .blocked:
            return true
        case .bootstrapping, .ready, .preparingSelectedModel:
            return false
        }
    }

    var cardTitle: String? {
        switch self {
        case .bootstrapping, .ready:
            return nil
        case .awaitingModelSelection:
            return "Choose a model to get started"
        case .preparingSelectedModel:
            return "Preparing your model"
        case .blocked:
            return "Model not ready"
        }
    }

    var cardMessage: String? {
        switch self {
        case .bootstrapping, .ready:
            return nil
        case .awaitingModelSelection(let supportsVoxtral):
            if supportsVoxtral {
                return "Choose a local model before recording. Lemon Whisper will not download anything until you confirm."
            }
            return "Voxtral is unavailable on this Mac. Choose a Whisper model before recording. Lemon Whisper will not download anything until you confirm."
        case .preparingSelectedModel:
            return "Your selected model is being prepared. Recording stays disabled until setup finishes."
        case .blocked(let message):
            return message
        }
    }

    var idleButtonTitle: String {
        switch self {
        case .bootstrapping:
            return "Loading…"
        case .ready:
            return "Start Recording"
        case .awaitingModelSelection:
            return "Choose Model to Start"
        case .preparingSelectedModel:
            return "Preparing Model…"
        case .blocked:
            return "Model Not Ready Yet"
        }
    }
}
