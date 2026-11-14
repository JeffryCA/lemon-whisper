import Foundation

/// Reuses the disposable MLX helper transport, with a separate worker session from Voxtral.
/// The app owns downloads; the helper loads only from the verified local directory.
actor QwenService {
    static let shared = QwenService()
    private let worker = VoxtralWorkerCoordinator()

    var isReady: Bool { get async { await worker.isPrepared } }

    func warmupModel() async throws {
        guard QwenModelCatalog.isDownloaded else { throw QwenServiceError.modelMissing }
        try await worker.prepare(modelID: QwenModelCatalog.modelID)
    }

    func transcribe(audioURL: URL, language: String) async throws -> String {
        guard QwenModelCatalog.isDownloaded else { throw QwenServiceError.modelMissing }
        return try await worker.transcribe(
            audioURL: audioURL, modelID: QwenModelCatalog.modelID,
            language: QwenModelCatalog.transcriptionLanguage(for: language)
        )
    }

    func unload() async { await worker.cancel() }
    func cancel() async { await worker.cancel() }

    func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        if QwenModelCatalog.isDownloaded { progress(1); return }
        struct Entry: Decodable { let type: String; let path: String; let size: Int? }
        let repo = QwenModelCatalog.repositoryID
        let url = URL(string: "https://huggingface.co/api/models/\(repo)/tree/main?recursive=true")!
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw QwenServiceError.downloadFailed }
        let entries = try JSONDecoder().decode([Entry].self, from: data).filter {
            $0.type == "file" && ["json", "safetensors", "txt"].contains(URL(fileURLWithPath: $0.path).pathExtension)
        }
        guard entries.contains(where: { $0.path == "config.json" }),
              entries.contains(where: { $0.path.hasSuffix(".safetensors") }),
              entries.allSatisfy({ $0.size != nil && !$0.path.contains("..") && !$0.path.hasPrefix("/") }) else {
            throw QwenServiceError.downloadFailed
        }
        let directory = QwenModelCatalog.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let total = entries.reduce(0) { $0 + ($1.size ?? 0) }
        var completed = 0
        var manifest: [String: Int] = [:]
        for entry in entries {
            try Task.checkCancellation()
            let destination = directory.appendingPathComponent(entry.path)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let values = try? destination.resourceValues(forKeys: [.fileSizeKey])
            if values?.fileSize != entry.size {
                let fileURL = URL(string: "https://huggingface.co/\(repo)/resolve/main/\(entry.path)")!
                let (temporary, response) = try await URLSession.shared.download(from: fileURL)
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      (try temporary.resourceValues(forKeys: [.fileSizeKey])).fileSize == entry.size else {
                    try? FileManager.default.removeItem(at: temporary)
                    throw QwenServiceError.downloadFailed
                }
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
            manifest[entry.path] = entry.size
            completed += entry.size ?? 0
            progress(total > 0 ? Double(completed) / Double(total) : 0)
        }
        try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("download-manifest.json"), options: .atomic)
        guard QwenModelCatalog.isDownloaded else { throw QwenServiceError.downloadFailed }
        progress(1)
    }

    func removeModel() async throws {
        await worker.cancel()
        if FileManager.default.fileExists(atPath: QwenModelCatalog.directory.path) {
            try FileManager.default.removeItem(at: QwenModelCatalog.directory)
        }
    }
}

enum QwenServiceError: LocalizedError {
    case modelMissing, downloadFailed
    var errorDescription: String? {
        switch self {
        case .modelMissing: return "Download the Qwen3-ASR model first."
        case .downloadFailed: return "Qwen3-ASR download failed or was incomplete. Try again to resume."
        }
    }
}
