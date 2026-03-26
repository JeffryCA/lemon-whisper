enum SetupState: Equatable {
    case ready
    case firstRunDownloadingDefaultModel
    case preparingSelectedModel
    case blocked(message: String)

    var isBlocking: Bool {
        if case .ready = self {
            return false
        }
        return true
    }

    var cardTitle: String? {
        switch self {
        case .ready:
            return nil
        case .firstRunDownloadingDefaultModel:
            return "Setting up Lemon Whisper"
        case .preparingSelectedModel:
            return "Preparing your model"
        case .blocked:
            return "Model not ready"
        }
    }

    var cardMessage: String? {
        switch self {
        case .ready:
            return nil
        case .firstRunDownloadingDefaultModel:
            return "Lemon Whisper is downloading Voxtral Mini 3B 4-bit for first use. Recording stays disabled until the model is ready."
        case .preparingSelectedModel:
            return "Your selected model is being prepared. Recording stays disabled until setup finishes."
        case .blocked(let message):
            return message
        }
    }

    var idleButtonTitle: String {
        switch self {
        case .ready:
            return "Start Recording (Ctrl+Y)"
        case .firstRunDownloadingDefaultModel:
            return "Downloading First Model…"
        case .preparingSelectedModel:
            return "Preparing Model…"
        case .blocked:
            return "Model Not Ready Yet"
        }
    }
}
