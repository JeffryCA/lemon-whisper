import Foundation

/// Backend-agnostic control over whether a transcription model is resident in memory.
///
/// Both transcription backends already load lazily at transcription time; this protocol lets the
/// app proactively warm up (fast mode / parallel-with-recording) or free memory after the selected
/// lazy idle timeout without the caller needing to know which backend is active.
protocol ModelMemoryController: Sendable {
    func isLoaded() async -> Bool
    /// Load the model. If `weightMaterializationBudget` is non-nil, also make weights fully
    /// resident now — but only if the backend expects that to complete within the budget (e.g.
    /// shorter than a typical recording). Pass `.infinity` to always do it (fast mode), or nil to
    /// skip it. Backends that allocate weights eagerly on load ignore the budget.
    func warmUp(weightMaterializationBudget: TimeInterval?) async throws
    func unload() async
}

/// whisper.cpp adapter. The C context is allocated eagerly by `whisper_init_*`, so warming up
/// materializes memory immediately (no separate evaluation step needed).
struct WhisperMemoryController: ModelMemoryController {
    func isLoaded() async -> Bool {
        WhisperContext.getShared() != nil
    }

    func warmUp(weightMaterializationBudget: TimeInterval?) async throws {
        // whisper.cpp allocates the model on init, so weights are always resident after load;
        // the budget is a no-op here.
        guard WhisperContext.getShared() == nil else { return }
        guard let selected = WhisperModelCatalog.selectedModelIfDownloaded() else {
            throw WhisperStateError.modelLoadFailed
        }
        _ = try await WhisperContext.createContext(path: selected.localURL.path)
        try await WhisperModelCatalog.ensureVADDownloadedIfNeeded()
        if let context = WhisperContext.getShared() {
            await context.setVADModelPath(WhisperModelCatalog.vadLocalURL.path)
        }
    }

    func unload() async {
        await WhisperContext.getShared()?.releaseResources()
        WhisperContext.clearShared()
    }
}

/// Voxtral/MLX adapter. The service prepares an idle-scoped helper rather than loading MLX in-app.
struct VoxtralMemoryController: ModelMemoryController {
    func isLoaded() async -> Bool {
        await VoxtralService.shared.isReady
    }

    func warmUp(weightMaterializationBudget: TimeInterval?) async throws {
        try await VoxtralService.shared.warmupModel(weightMaterializationBudget: weightMaterializationBudget)
    }

    func unload() async {
        await VoxtralService.shared.unload()
    }
}
