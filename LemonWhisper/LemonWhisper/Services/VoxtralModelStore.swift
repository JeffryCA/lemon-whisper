import Foundation

struct VoxtralModelInfo: Identifiable, Sendable {
    let id: String
    let repoID: String
    let name: String
    let description: String
    let size: String
}

enum VoxtralModelStoreError: LocalizedError {
    case modelNotFound
    case repositoryListingFailed(Int)
    case noFiles(String)
    case downloadFailed(String, Int)
    case incompleteDownload([String])

    var errorDescription: String? {
        switch self {
        case .modelNotFound: return "Voxtral model was not found."
        case .repositoryListingFailed(let status): return "Could not list model files (HTTP \(status))."
        case .noFiles(let repo): return "No model files were found for \(repo)."
        case .downloadFailed(let file, let status): return "Download failed for \(file) (HTTP \(status))."
        case .incompleteDownload(let files): return "Model download is incomplete: \(files.joined(separator: ", "))."
        }
    }
}

/// Lightweight cache owner used by the main app. It deliberately has no MLX/VoxtralCore import,
/// ensuring model execution code and Metal state can exist only in the disposable helper.
enum VoxtralModelStore {
    static let models: [VoxtralModelInfo] = [
        VoxtralModelInfo(
            id: "mini-3b", repoID: "mistralai/Voxtral-Mini-3B-2507",
            name: "Voxtral Mini 3B (Official)",
            description: "Official Mistral model - full precision", size: "~6 GB"
        ),
        VoxtralModelInfo(
            id: "mini-3b-8bit", repoID: "mzbac/voxtral-mini-3b-8bit",
            name: "Voxtral Mini 3B (8-bit)",
            description: "Best quality/size balance for the mini model", size: "~3.5 GB"
        ),
        VoxtralModelInfo(
            id: "mini-3b-4bit", repoID: "mzbac/voxtral-mini-3b-4bit-mixed",
            name: "Voxtral Mini 3B (4-bit mixed)",
            description: "Smaller footprint, slightly lower quality", size: "~2 GB"
        ),
    ]

    private struct TreeEntry: Decodable {
        let type: String
        let path: String
        let size: Int?
    }

    static func model(id: String) -> VoxtralModelInfo? {
        models.first { $0.id == id }
    }

    static func findModelPath(for model: VoxtralModelInfo) -> URL? {
        for candidate in candidatePaths(for: model) where hasConfig(candidate) {
            if verifyShardedModel(at: candidate).complete { return candidate }
        }
        return nil
    }

    static func removeIncompleteModelIfPresent(_ model: VoxtralModelInfo) {
        for candidate in candidatePaths(for: model) where hasConfig(candidate) {
            guard !verifyShardedModel(at: candidate).complete else { continue }
            try? FileManager.default.removeItem(at: deletionRoot(for: candidate))
        }
    }

    static func download(
        _ model: VoxtralModelInfo,
        progress: (@Sendable (Double, String) -> Void)?
    ) async throws -> URL {
        if let existing = findModelPath(for: model) {
            progress?(1, "Model already downloaded")
            return existing
        }

        let revision = "main"
        let treeURL = URL(
            string: "https://huggingface.co/api/models/\(model.repoID)/tree/\(revision)?recursive=true"
        )!
        var treeRequest = URLRequest(url: treeURL)
        addAuthorization(to: &treeRequest)
        progress?(0, "Starting download of \(model.name)...")
        let (treeData, treeResponse) = try await URLSession.shared.data(for: treeRequest)
        let treeStatus = (treeResponse as? HTTPURLResponse)?.statusCode ?? -1
        guard treeStatus == 200 else { throw VoxtralModelStoreError.repositoryListingFailed(treeStatus) }

        let files = try JSONDecoder().decode([TreeEntry].self, from: treeData).filter {
            $0.type == "file" && ($0.path.hasSuffix(".json") || $0.path.hasSuffix(".safetensors"))
        }
        guard !files.isEmpty else { throw VoxtralModelStoreError.noFiles(model.repoID) }

        let destination = modelsDirectory.appendingPathComponent(model.repoID)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let totalBytes = files.reduce(0) { $0 + ($1.size ?? 0) }
        var completedBytes = 0

        for file in files {
            try Task.checkCancellation()
            let output = destination.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(
                at: output.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            if let expected = file.size,
               let values = try? output.resourceValues(forKeys: [.fileSizeKey]),
               values.fileSize == expected {
                completedBytes += expected
                progress?(fraction(completedBytes, totalBytes), "Skipped \(file.path)")
                continue
            }

            progress?(fraction(completedBytes, totalBytes), "Downloading \(file.path)...")
            let remote = URL(
                string: "https://huggingface.co/\(model.repoID)/resolve/\(revision)/\(file.path)"
            )!
            var request = URLRequest(url: remote)
            addAuthorization(to: &request)
            try await downloadWithRetry(request, to: output, filename: file.path, progress: progress)
            completedBytes += file.size ?? 0
        }

        let verification = verifyShardedModel(at: destination)
        guard verification.complete else {
            throw VoxtralModelStoreError.incompleteDownload(verification.missing)
        }
        progress?(1, "Download complete")
        return destination
    }

    static func delete(_ model: VoxtralModelInfo) throws {
        guard let path = findModelPath(for: model) else { throw VoxtralModelStoreError.modelNotFound }
        try FileManager.default.removeItem(at: deletionRoot(for: path))
    }

    static func verifyShardedModel(at path: URL) -> (complete: Bool, missing: [String]) {
        let index = path.appendingPathComponent("model.safetensors.index.json")
        guard let data = try? Data(contentsOf: index),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let weights = json["weight_map"] as? [String: String] else {
            return (true, [])
        }
        let missing = Set(weights.values).filter {
            !FileManager.default.fileExists(atPath: path.appendingPathComponent($0).path)
        }.sorted()
        return (missing.isEmpty, missing)
    }

    private static var modelsDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("models")
    }

    private static func candidatePaths(for model: VoxtralModelInfo) -> [URL] {
        var paths = [modelsDirectory.appendingPathComponent(model.repoID)]
        let legacyBase = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub")
            .appendingPathComponent("models--\(model.repoID.replacingOccurrences(of: "/", with: "--"))")
        let snapshots = legacyBase.appendingPathComponent("snapshots")
        if let entries = try? FileManager.default.contentsOfDirectory(at: snapshots, includingPropertiesForKeys: nil) {
            paths.append(contentsOf: entries.sorted { $0.lastPathComponent > $1.lastPathComponent })
        }
        return paths
    }

    private static func hasConfig(_ path: URL) -> Bool {
        FileManager.default.fileExists(atPath: path.appendingPathComponent("config.json").path)
    }

    private static func deletionRoot(for path: URL) -> URL {
        guard path.path.contains("/.cache/huggingface/hub/"),
              path.deletingLastPathComponent().lastPathComponent == "snapshots" else { return path }
        return path.deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func fraction(_ completed: Int, _ total: Int) -> Double {
        total > 0 ? min(1, Double(completed) / Double(total)) : 0
    }

    private static func addAuthorization(to request: inout URLRequest) {
        if let token = ProcessInfo.processInfo.environment["HF_TOKEN"], !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    private static func downloadWithRetry(
        _ request: URLRequest,
        to output: URL,
        filename: String,
        progress: (@Sendable (Double, String) -> Void)?
    ) async throws {
        for attempt in 1...5 {
            do {
                let (temporary, response) = try await URLSession.shared.download(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                guard status == 200 else { throw VoxtralModelStoreError.downloadFailed(filename, status) }
                if FileManager.default.fileExists(atPath: output.path) {
                    try FileManager.default.removeItem(at: output)
                }
                try FileManager.default.moveItem(at: temporary, to: output)
                return
            } catch let error as URLError where isTransient(error) && attempt < 5 {
                let delay = UInt64(pow(2, Double(attempt)))
                progress?(0, "Network interrupted on \(filename); retrying in \(delay)s...")
                try await Task.sleep(nanoseconds: delay * 1_000_000_000)
            }
        }
        throw URLError(.unknown)
    }

    private static func isTransient(_ error: URLError) -> Bool {
        switch error.code {
        case .networkConnectionLost, .notConnectedToInternet, .timedOut,
             .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
             .resourceUnavailable, .dataNotAllowed:
            return true
        default:
            return false
        }
    }
}
