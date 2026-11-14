import Foundation

enum QwenModelCatalog {
    static let modelID = "qwen3-asr-1.7b-4bit"
    static let repositoryID = "mlx-community/Qwen3-ASR-1.7B-4bit"
    static let title = "Qwen3-ASR 1.7B (4-bit, experimental)"
    /// Qwen expects language names; its upstream alias table omits some ISO codes (e.g. nl).
    static func transcriptionLanguage(for code: String) -> String? {
        ["en": "English", "es": "Spanish", "de": "German", "fr": "French",
         "it": "Italian", "pt": "Portuguese", "nl": "Dutch", "ru": "Russian",
         "ja": "Japanese", "ko": "Korean", "zh": "Chinese"][code]
    }

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LemonWhisper/models/qwen3-asr-1.7b-4bit", isDirectory: true)
    }
    static var isDownloaded: Bool { isComplete(at: directory) }

    static func isComplete(at directory: URL) -> Bool {
        let marker = directory.appendingPathComponent("download-manifest.json")
        guard let data = try? Data(contentsOf: marker),
              let files = try? JSONDecoder().decode([String: Int].self, from: data),
              files["config.json"] != nil,
              files.keys.contains(where: { $0.hasSuffix(".safetensors") }) else { return false }
        return files.allSatisfy { name, size in
            let values = try? directory.appendingPathComponent(name).resourceValues(forKeys: [.fileSizeKey])
            return values?.fileSize == size
        }
    }
}
