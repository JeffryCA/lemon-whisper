import Foundation
import VoxtralCore

enum ReproError: LocalizedError {
    case invalidArguments(String)
    case modelNotDownloaded(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let message):
            return message
        case .modelNotDownloaded(let message):
            return message
        }
    }
}

struct Configuration: Codable, Sendable {
    var audioPath: String
    var cycles: Int = 100
    var modelID: String = "mini-3b-4bit"
    var language: String = "auto"
    var outputPath: String?
    var settleMilliseconds: Int = 1_000
    var deepSampleEvery: Int = 1
    var clearMLXCache = true
    var stopOnError = false

    static let usage = """
    Usage:
      swift run -c release voxtral-memory-repro --audio /absolute/path/sample.wav [options]

    Options:
      --cycles N                 Load/transcribe/unload cycles (default: 100)
      --model ID                 mini-3b, mini-3b-8bit, or mini-3b-4bit
                                 (default: mini-3b-4bit)
      --language CODE            Language code, or auto (default: auto)
      --output DIRECTORY         Result directory (default: results/<timestamp>)
      --settle-ms N              Delay before each post-unload sample (default: 1000)
      --deep-sample-every N      Run /usr/bin/heap every N post-unload cycles;
                                 0 disables it (default: 1)
      --no-clear-cache           Do not call MLX Memory.clearCache() after unload
      --stop-on-error            Stop after the first failed cycle
      --help                     Show this help

    The selected model must already be fully downloaded. This tool never owns downloads,
    preventing it from racing LemonWhisper over the shared model cache.
    """

    static func parse(_ arguments: [String]) throws -> Configuration {
        if arguments.contains("--help") || arguments.contains("-h") {
            throw ReproError.invalidArguments(usage)
        }

        var values = arguments
        var result = Configuration(audioPath: "")

        func takeValue(for option: String) throws -> String {
            guard !values.isEmpty else {
                throw ReproError.invalidArguments("Missing value for \(option).\n\n\(usage)")
            }
            return values.removeFirst()
        }

        while !values.isEmpty {
            let option = values.removeFirst()
            switch option {
            case "--audio":
                result.audioPath = try takeValue(for: option)
            case "--cycles":
                let raw = try takeValue(for: option)
                guard let value = Int(raw), value > 0 else {
                    throw ReproError.invalidArguments("--cycles must be a positive integer")
                }
                result.cycles = value
            case "--model":
                result.modelID = try takeValue(for: option)
            case "--language":
                result.language = try takeValue(for: option)
            case "--output":
                result.outputPath = try takeValue(for: option)
            case "--settle-ms":
                let raw = try takeValue(for: option)
                guard let value = Int(raw), value >= 0 else {
                    throw ReproError.invalidArguments("--settle-ms must be zero or greater")
                }
                result.settleMilliseconds = value
            case "--deep-sample-every":
                let raw = try takeValue(for: option)
                guard let value = Int(raw), value >= 0 else {
                    throw ReproError.invalidArguments("--deep-sample-every must be zero or greater")
                }
                result.deepSampleEvery = value
            case "--no-clear-cache":
                result.clearMLXCache = false
            case "--stop-on-error":
                result.stopOnError = true
            default:
                throw ReproError.invalidArguments("Unknown argument: \(option)\n\n\(usage)")
            }
        }

        guard !result.audioPath.isEmpty else {
            throw ReproError.invalidArguments("--audio is required.\n\n\(usage)")
        }
        guard ["mini-3b", "mini-3b-8bit", "mini-3b-4bit"].contains(result.modelID) else {
            throw ReproError.invalidArguments("Unsupported model ID: \(result.modelID)")
        }
        guard FileManager.default.fileExists(atPath: result.audioPath) else {
            throw ReproError.invalidArguments("Audio file does not exist: \(result.audioPath)")
        }

        result.audioPath = URL(fileURLWithPath: result.audioPath).standardizedFileURL.path
        if let outputPath = result.outputPath {
            result.outputPath = URL(fileURLWithPath: outputPath).standardizedFileURL.path
        }
        return result
    }

    var pipelineModel: VoxtralPipeline.Model {
        switch modelID {
        case "mini-3b": .mini3b
        case "mini-3b-8bit": .mini3b8bit
        default: .mini3b4bit
        }
    }

    var normalizedLanguage: String? {
        language == "auto" ? nil : language
    }

    func requireDownloadedModel() throws -> URL {
        guard
            let info = ModelRegistry.model(withId: modelID),
            let path = ModelDownloader.findModelPath(for: info)
        else {
            throw ReproError.modelNotDownloaded(
                "Model \(modelID) is not fully downloaded. Download it in LemonWhisper, quit "
                    + "LemonWhisper, and rerun this tool."
            )
        }
        return path
    }
}
