import Foundation

#if canImport(VoxtralCore)
import VoxtralCore
#endif

struct VoxtralModelOption: Identifiable, Hashable {
    let id: String
    let title: String
    let family: String
    let downloadSizeLabel: String
    let expectedPeakMemoryLabel: String
    let description: String
}

enum VoxtralServiceError: LocalizedError {
    case unavailable
    case modelNotConfigured
    case loadFailed(String)
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Voxtral support is unavailable in this build."
        case .modelNotConfigured:
            return "No Voxtral model is configured."
        case .loadFailed(let message):
            return "Failed to load Voxtral model: \(message)"
        case .transcriptionFailed(let message):
            return "Voxtral transcription failed: \(message)"
        }
    }
}

actor VoxtralService {
    static let shared = VoxtralService()

    private let selectedModelDefaultsKey = "selectedVoxtralModelID"

#if canImport(VoxtralCore)
    private var pipeline: VoxtralPipeline?
    private var loadedModelID: String?
    private var isLoadingModel = false
    private var lastErrorMessage: String?

    private var selectedModelID: String

    init() {
        let stored = UserDefaults.standard.string(forKey: selectedModelDefaultsKey)
        if let stored, Self.modelInfo(for: stored) != nil {
            self.selectedModelID = stored
        } else {
            self.selectedModelID = "mini-3b-8bit"
        }
    }
#else
    init() {}
#endif

    var isReady: Bool {
#if canImport(VoxtralCore)
        pipeline != nil && loadedModelID == selectedModelID
#else
        false
#endif
    }

    var latestError: String? {
#if canImport(VoxtralCore)
        lastErrorMessage
#else
        VoxtralServiceError.unavailable.localizedDescription
#endif
    }

    func currentSelectedModelID() -> String {
#if canImport(VoxtralCore)
        selectedModelID
#else
        ""
#endif
    }

    func availableModels() -> [VoxtralModelOption] {
#if canImport(VoxtralCore)
        return Self.availableModelInfos().map { info in
            VoxtralModelOption(
                id: info.id,
                title: info.name,
                family: Self.familyLabel(for: info.id),
                downloadSizeLabel: info.size,
                expectedPeakMemoryLabel: Self.peakMemoryLabel(for: info.id),
                description: info.description
            )
        }
#else
        return []
#endif
    }

    func downloadedModels() -> [VoxtralModelOption] {
#if canImport(VoxtralCore)
        return Self.availableModelInfos().filter { info in
            ModelDownloader.findModelPath(for: info) != nil
        }.map { info in
            VoxtralModelOption(
                id: info.id,
                title: info.name,
                family: Self.familyLabel(for: info.id),
                downloadSizeLabel: info.size,
                expectedPeakMemoryLabel: Self.peakMemoryLabel(for: info.id),
                description: info.description
            )
        }
#else
        return []
#endif
    }

    func isModelDownloaded(_ id: String) -> Bool {
#if canImport(VoxtralCore)
        guard let info = Self.modelInfo(for: id) else { return false }
        return ModelDownloader.findModelPath(for: info) != nil
#else
        false
#endif
    }

    func setSelectedModel(_ id: String) {
#if canImport(VoxtralCore)
        guard Self.modelInfo(for: id) != nil else { return }
        if selectedModelID == id { return }
        selectedModelID = id
        UserDefaults.standard.set(id, forKey: selectedModelDefaultsKey)
        unload()
#endif
    }

    func downloadModel(
        _ id: String,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws {
#if canImport(VoxtralCore)
        guard let info = Self.modelInfo(for: id) else {
            throw VoxtralServiceError.modelNotConfigured
        }
        removeIncompleteModelIfPresent(info)
        _ = try await ModelDownloader.download(info, progress: progress)
#else
        throw VoxtralServiceError.unavailable
#endif
    }

    func cleanupInterruptedDownloads() {
#if canImport(VoxtralCore)
        for info in Self.availableModelInfos() {
            removeIncompleteModelIfPresent(info)
        }
#endif
    }

    func removeModel(_ id: String) throws {
#if canImport(VoxtralCore)
        guard let info = Self.modelInfo(for: id) else {
            throw VoxtralServiceError.modelNotConfigured
        }

        if id == selectedModelID {
            unload()
        }
        try ModelDownloader.deleteModel(info)
#else
        throw VoxtralServiceError.unavailable
#endif
    }

    func transcribe(audioURL: URL, language: String) async throws -> String {
#if canImport(VoxtralCore)
        let pipeline = try await loadPipelineIfNeeded()
        let normalizedLanguage = language == "auto" ? "en" : language
        let text = try await pipeline.transcribe(audio: audioURL, language: normalizedLanguage)
        return text
#else
        throw VoxtralServiceError.unavailable
#endif
    }

    func warmupModel() async throws {
#if canImport(VoxtralCore)
        _ = try await loadPipelineIfNeeded()
#else
        throw VoxtralServiceError.unavailable
#endif
    }

    func unload() {
#if canImport(VoxtralCore)
        pipeline?.unload()
        pipeline = nil
        loadedModelID = nil
        lastErrorMessage = nil
#endif
    }

#if canImport(VoxtralCore)
    private static func availableModelInfos() -> [VoxtralModelInfo] {
        // Keep scope practical for local usage: Mini family only (full + quantized).
        ModelRegistry.models.filter { $0.parameters == "3B" }
    }

    private static func modelInfo(for id: String) -> VoxtralModelInfo? {
        availableModelInfos().first(where: { $0.id == id })
    }

    private static func familyLabel(for id: String) -> String {
        switch id {
        case "mini-3b", "mini-3b-8bit", "mini-3b-4bit":
            return "Mini 3B"
        default:
            return "Other"
        }
    }

    private static func peakMemoryLabel(for id: String) -> String {
        switch id {
        case "mini-3b":
            return "~15 GB"
        case "mini-3b-8bit":
            return "~10 GB"
        case "mini-3b-4bit":
            return "~8 GB"
        default:
            return "Unknown"
        }
    }

    private static func pipelineModel(for id: String) -> VoxtralPipeline.Model? {
        switch id {
        case "mini-3b":
            return .mini3b
        case "mini-3b-8bit":
            return .mini3b8bit
        case "mini-3b-4bit":
            return .mini3b4bit
        default:
            return nil
        }
    }

    private func removeIncompleteModelIfPresent(_ info: VoxtralModelInfo) {
        guard let path = ModelDownloader.findModelPath(for: info) else { return }
        let verification = ModelDownloader.verifyShardedModel(at: path)
        guard !verification.complete else { return }
        try? ModelDownloader.deleteModel(info)
    }

    private func loadPipelineIfNeeded() async throws -> VoxtralPipeline {
        if let pipeline, loadedModelID == selectedModelID {
            return pipeline
        }

        while isLoadingModel {
            try await Task.sleep(nanoseconds: 100_000_000)
            if let pipeline, loadedModelID == selectedModelID {
                return pipeline
            }
        }

        isLoadingModel = true
        defer { isLoadingModel = false }

        guard let pipelineModel = Self.pipelineModel(for: selectedModelID) else {
            throw VoxtralServiceError.modelNotConfigured
        }

        var config = VoxtralPipeline.Configuration.default
        config.temperature = 0
        config.maxTokens = 500

        let newPipeline = VoxtralPipeline(
            model: pipelineModel,
            backend: .mlx,
            configuration: config
        )

        do {
            try await loadModelWithSingleRetry(newPipeline)
            pipeline = newPipeline
            loadedModelID = selectedModelID
            lastErrorMessage = nil
            return newPipeline
        } catch {
            lastErrorMessage = error.localizedDescription
            throw VoxtralServiceError.loadFailed(error.localizedDescription)
        }
    }

    private func loadModelWithSingleRetry(_ pipeline: VoxtralPipeline) async throws {
        do {
            try await pipeline.loadModel { progress, status in
                let percent = Int(progress * 100)
                print("🧠 Voxtral load [\(percent)%] \(status)")
            }
        } catch {
            let message = error.localizedDescription
            guard let badPath = extractMissingWeightsPath(from: message) else {
                throw error
            }

            print("⚠️ Voxtral cache seems incomplete. Removing \(badPath) and retrying once.")
            try? FileManager.default.removeItem(atPath: badPath)

            try await pipeline.loadModel { progress, status in
                let percent = Int(progress * 100)
                print("🧠 Voxtral retry [\(percent)%] \(status)")
            }
        }
    }

    private func extractMissingWeightsPath(from message: String) -> String? {
        let marker = "No weight files found in "
        guard let range = message.range(of: marker) else { return nil }
        let path = String(message[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }
#endif
}
