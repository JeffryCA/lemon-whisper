import Foundation

#if canImport(VoxtralCore)
import VoxtralCore
#endif

enum VoxtralServiceError: LocalizedError {
    case unavailable
    case loadFailed(String)
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Voxtral support is unavailable in this build."
        case .loadFailed(let message):
            return "Failed to load Voxtral model: \(message)"
        case .transcriptionFailed(let message):
            return "Voxtral transcription failed: \(message)"
        }
    }
}

actor VoxtralService {
    static let shared = VoxtralService()

#if canImport(VoxtralCore)
    private var pipeline: VoxtralPipeline?
    private var isLoadingModel = false
    private var lastErrorMessage: String?
#endif

    var isReady: Bool {
#if canImport(VoxtralCore)
        pipeline != nil
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
        lastErrorMessage = nil
#endif
    }

#if canImport(VoxtralCore)
    private func loadPipelineIfNeeded() async throws -> VoxtralPipeline {
        if let pipeline {
            return pipeline
        }

        while isLoadingModel {
            try await Task.sleep(nanoseconds: 100_000_000)
            if let pipeline {
                return pipeline
            }
        }

        isLoadingModel = true
        defer { isLoadingModel = false }

        var config = VoxtralPipeline.Configuration.default
        config.temperature = 0
        config.maxTokens = 500

        let newPipeline = VoxtralPipeline(
            model: .mini3b8bit,
            backend: .mlx,
            configuration: config
        )

        do {
            try await loadModelWithSingleRetry(newPipeline)
            pipeline = newPipeline
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
