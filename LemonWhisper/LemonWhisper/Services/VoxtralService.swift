import Foundation

struct VoxtralModelOption: Identifiable, Hashable {
    let id: String
    let title: String
    let family: String
    let downloadSizeLabel: String
    let expectedPeakMemoryLabel: String
    let description: String
}

enum VoxtralServiceError: LocalizedError {
    case modelNotConfigured
    case loadFailed(String)
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotConfigured: return "No Voxtral model is configured."
        case .loadFailed(let message): return "Failed to load Voxtral model: \(message)"
        case .transcriptionFailed(let message): return "Voxtral transcription failed: \(message)"
        }
    }
}

actor VoxtralService {
    static let shared = VoxtralService()
    static let defaultModelID = "mini-3b-4bit"

    private let selectedModelDefaultsKey = "selectedVoxtralModelID"
    private let worker = VoxtralWorkerCoordinator()
    private var lastErrorMessage: String?
    private var workerIsPrepared = false
    private var selectedModelID: String

    init() {
        let stored = UserDefaults.standard.string(forKey: selectedModelDefaultsKey)
        selectedModelID = stored.flatMap(VoxtralModelStore.model(id:))?.id ?? Self.defaultModelID
    }

    var isReady: Bool { workerIsPrepared }
    var latestError: String? { lastErrorMessage }

    func currentSelectedModelID() -> String { selectedModelID }

    func availableModels() -> [VoxtralModelOption] {
        VoxtralModelStore.models.map(Self.option(for:))
    }

    func downloadedModels() -> [VoxtralModelOption] {
        VoxtralModelStore.models.filter { VoxtralModelStore.findModelPath(for: $0) != nil }
            .map(Self.option(for:))
    }

    func isModelDownloaded(_ id: String) -> Bool {
        guard let info = VoxtralModelStore.model(id: id) else { return false }
        return VoxtralModelStore.findModelPath(for: info) != nil
    }

    func setSelectedModel(_ id: String) async {
        guard VoxtralModelStore.model(id: id) != nil, selectedModelID != id else { return }
        await worker.shutdown()
        workerIsPrepared = false
        selectedModelID = id
        UserDefaults.standard.set(id, forKey: selectedModelDefaultsKey)
    }

    func downloadModel(
        _ id: String,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws {
        guard let info = VoxtralModelStore.model(id: id) else {
            throw VoxtralServiceError.modelNotConfigured
        }
        // The main app is the sole cache owner; workers never download or delete model files.
        await worker.shutdown()
        workerIsPrepared = false
        VoxtralModelStore.removeIncompleteModelIfPresent(info)
        _ = try await VoxtralModelStore.download(info, progress: progress)
    }

    func cleanupInterruptedDownloads() {
        for info in VoxtralModelStore.models {
            VoxtralModelStore.removeIncompleteModelIfPresent(info)
        }
    }

    func removeModel(_ id: String) async throws {
        guard let info = VoxtralModelStore.model(id: id) else {
            throw VoxtralServiceError.modelNotConfigured
        }
        await worker.shutdown()
        workerIsPrepared = false
        try VoxtralModelStore.delete(info)
    }

    func transcribe(audioURL: URL, language: String) async throws -> String {
        let normalizedLanguage: String? = language == "auto" ? nil : language
        workerIsPrepared = false
        do {
            let text = try await worker.transcribe(
                audioURL: audioURL,
                modelID: selectedModelID,
                language: normalizedLanguage
            )
            lastErrorMessage = nil
            if AppSettingsStore.modelLoadingMode == .fast {
                let modelID = selectedModelID
                Task { await self.prepareFastWorker(modelID: modelID) }
            }
            return text
        } catch {
            lastErrorMessage = error.localizedDescription
            throw VoxtralServiceError.transcriptionFailed(error.localizedDescription)
        }
    }

    /// Starts a disposable process and fully prepares its model. Model loading and materialization
    /// happen entirely in the helper and overlap the active recording.
    func warmupModel(weightMaterializationBudget: TimeInterval? = nil) async throws {
        do {
            try await worker.prepare(modelID: selectedModelID)
            workerIsPrepared = true
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
            throw VoxtralServiceError.loadFailed(error.localizedDescription)
        }
    }

    func unload() async {
        await worker.shutdown()
        workerIsPrepared = false
        lastErrorMessage = nil
    }

    func cancelCurrentWorker() async {
        await worker.cancel()
        workerIsPrepared = false
    }

    private func prepareFastWorker(modelID: String) async {
        guard selectedModelID == modelID, AppSettingsStore.modelLoadingMode == .fast else { return }
        do {
            try await worker.prepare(modelID: modelID)
            guard selectedModelID == modelID else { return }
            workerIsPrepared = true
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    private static func option(for info: VoxtralModelInfo) -> VoxtralModelOption {
        VoxtralModelOption(
            id: info.id,
            title: info.name,
            family: "Mini 3B",
            downloadSizeLabel: info.size,
            expectedPeakMemoryLabel: peakMemoryLabel(for: info.id),
            description: info.description
        )
    }

    private static func peakMemoryLabel(for id: String) -> String {
        switch id {
        case "mini-3b": return "~15 GB"
        case "mini-3b-8bit": return "~10 GB"
        case "mini-3b-4bit": return "~8 GB"
        default: return "Unknown"
        }
    }
}
