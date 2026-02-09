import Foundation

struct WhisperModelOption: Identifiable, Hashable {
    let id: String
    let title: String
    let fileName: String
    let sizeLabel: String
    let sourceURL: URL

    var localURL: URL {
        WhisperModelCatalog.whisperModelsDirectory.appendingPathComponent(fileName)
    }
}

enum WhisperModelCatalog {
    static let selectedModelDefaultsKey = "selectedWhisperModelID"

    static let baseURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main")!

    static let models: [WhisperModelOption] = [
        WhisperModelOption(
            id: "large-v3-turbo",
            title: "Whisper large-v3-turbo (fp16)",
            fileName: "ggml-large-v3-turbo.bin",
            sizeLabel: "~1.5 GB",
            sourceURL: baseURL.appendingPathComponent("ggml-large-v3-turbo.bin")
        ),
        WhisperModelOption(
            id: "large-v3-turbo-q8_0",
            title: "Whisper large-v3-turbo (q8_0)",
            fileName: "ggml-large-v3-turbo-q8_0.bin",
            sizeLabel: "~0.9 GB",
            sourceURL: baseURL.appendingPathComponent("ggml-large-v3-turbo-q8_0.bin")
        ),
        WhisperModelOption(
            id: "large-v3-turbo-q5_0",
            title: "Whisper large-v3-turbo (q5_0)",
            fileName: "ggml-large-v3-turbo-q5_0.bin",
            sizeLabel: "~0.6 GB",
            sourceURL: baseURL.appendingPathComponent("ggml-large-v3-turbo-q5_0.bin")
        ),
        WhisperModelOption(
            id: "large-v3",
            title: "Whisper large-v3 (fp16)",
            fileName: "ggml-large-v3.bin",
            sizeLabel: "~3.1 GB",
            sourceURL: baseURL.appendingPathComponent("ggml-large-v3.bin")
        ),
        WhisperModelOption(
            id: "large-v3-q5_0",
            title: "Whisper large-v3 (q5_0)",
            fileName: "ggml-large-v3-q5_0.bin",
            sizeLabel: "~1.1 GB",
            sourceURL: baseURL.appendingPathComponent("ggml-large-v3-q5_0.bin")
        )
    ]

    static let defaultModelID = "large-v3-turbo"

    static let vadModelURL = baseURL.appendingPathComponent("ggml-silero-v5.1.2.bin")
    static let vadFileName = "ggml-silero-v5.1.2.bin"

    static var applicationSupportDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("LemonWhisper", isDirectory: true)
    }

    static var modelsRootDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("models", isDirectory: true)
    }

    static var whisperModelsDirectory: URL {
        modelsRootDirectory.appendingPathComponent("whisper", isDirectory: true)
    }

    static var sharedModelsDirectory: URL {
        modelsRootDirectory.appendingPathComponent("shared", isDirectory: true)
    }

    static var vadLocalURL: URL {
        sharedModelsDirectory.appendingPathComponent(vadFileName)
    }

    static func ensureDirectories() throws {
        try FileManager.default.createDirectory(at: whisperModelsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sharedModelsDirectory, withIntermediateDirectories: true)
    }

    static func option(for id: String) -> WhisperModelOption? {
        models.first(where: { $0.id == id })
    }

    static func selectedModelID() -> String {
        let stored = UserDefaults.standard.string(forKey: selectedModelDefaultsKey)
        if let stored, option(for: stored) != nil {
            return stored
        }
        return defaultModelID
    }

    static func setSelectedModelID(_ id: String) {
        UserDefaults.standard.set(id, forKey: selectedModelDefaultsKey)
    }

    static func isDownloaded(_ option: WhisperModelOption) -> Bool {
        FileManager.default.fileExists(atPath: option.localURL.path)
    }

    static func downloadedModels() -> [WhisperModelOption] {
        models.filter(isDownloaded)
    }

    static func selectedModelIfDownloaded() -> WhisperModelOption? {
        let selected = selectedModelID()
        guard let option = option(for: selected), isDownloaded(option) else {
            return downloadedModels().first
        }
        return option
    }

    static func ensureVADDownloadedIfNeeded() async throws {
        try ensureDirectories()
        guard !FileManager.default.fileExists(atPath: vadLocalURL.path) else {
            return
        }
        try await downloadFile(from: vadModelURL, to: vadLocalURL)
    }

    static func downloadModel(_ option: WhisperModelOption) async throws {
        try ensureDirectories()
        try await downloadFile(from: option.sourceURL, to: option.localURL)
    }

    static func removeModel(_ option: WhisperModelOption) throws {
        if FileManager.default.fileExists(atPath: option.localURL.path) {
            try FileManager.default.removeItem(at: option.localURL)
        }
    }

    private static func downloadFile(from sourceURL: URL, to destinationURL: URL) async throws {
        let tempURL = destinationURL.appendingPathExtension("downloading")
        try? FileManager.default.removeItem(at: tempURL)

        let (downloadedURL, response) = try await URLSession.shared.download(from: sourceURL)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw NSError(domain: "ModelDownload", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unexpected response while downloading \(sourceURL.lastPathComponent)"])
        }

        try? FileManager.default.removeItem(at: destinationURL)
        try FileManager.default.moveItem(at: downloadedURL, to: tempURL)
        try? FileManager.default.removeItem(at: destinationURL)
        try FileManager.default.moveItem(at: tempURL, to: destinationURL)
    }
}
