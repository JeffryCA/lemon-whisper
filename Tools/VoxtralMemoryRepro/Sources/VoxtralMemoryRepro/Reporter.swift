import Foundation

struct RunSummary: Codable, Sendable {
    let startedAt: String
    let finishedAt: String
    let requestedCycles: Int
    let completedCycles: Int
    let failedCycles: Int
    let initialFootprintBytes: UInt64?
    let finalFootprintBytes: UInt64?
    let footprintDeltaBytes: Int64?
    let postUnloadFootprintSlopeBytesPerCycle: Double?
    let initialHeapNodeCount: Int?
    let finalHeapNodeCount: Int?
    let heapNodeDelta: Int?
    let initialAGXFamilyBufferCount: Int?
    let finalAGXFamilyBufferCount: Int?
    let agxFamilyBufferDelta: Int?
}

final class Reporter {
    let outputDirectory: URL
    let startedAt: String

    private let csvHandle: FileHandle
    private let jsonlHandle: FileHandle
    private(set) var samples: [MetricSample] = []

    init(configuration: Configuration) throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        startedAt = formatter.string(from: Date())

        if let outputPath = configuration.outputPath {
            outputDirectory = URL(fileURLWithPath: outputPath, isDirectory: true)
        } else {
            let directoryName = startedAt
                .replacingOccurrences(of: ":", with: "-")
                .replacingOccurrences(of: ".", with: "-")
            outputDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("results", isDirectory: true)
                .appendingPathComponent(directoryName, isDirectory: true)
        }

        let heapDirectory = outputDirectory.appendingPathComponent("heap", isDirectory: true)
        try FileManager.default.createDirectory(at: heapDirectory, withIntermediateDirectories: true)

        let csvURL = outputDirectory.appendingPathComponent("metrics.csv")
        let jsonlURL = outputDirectory.appendingPathComponent("metrics.jsonl")
        FileManager.default.createFile(atPath: csvURL.path, contents: nil)
        FileManager.default.createFile(atPath: jsonlURL.path, contents: nil)
        csvHandle = try FileHandle(forWritingTo: csvURL)
        jsonlHandle = try FileHandle(forWritingTo: jsonlURL)

        let header = [
            "timestamp", "uptime_seconds", "cycle", "phase", "phase_elapsed_ms",
            "mlx_active_bytes", "mlx_cache_bytes", "physical_footprint_bytes",
            "malloc_blocks_in_use", "malloc_bytes_in_use", "heap_node_count",
            "agx_family_buffer_count", "deep_sample_status", "deep_sample_report",
            "transcription_characters", "error"
        ].joined(separator: ",") + "\n"
        try csvHandle.write(contentsOf: Data(header.utf8))

        let configurationData = try Self.encoder(pretty: true).encode(configuration)
        try configurationData.write(
            to: outputDirectory.appendingPathComponent("configuration.json"),
            options: .atomic
        )
    }

    deinit {
        try? csvHandle.close()
        try? jsonlHandle.close()
    }

    func heapReportURL(cycle: Int, phase: String) -> URL {
        let filename = String(format: "cycle-%03d-%@.txt", cycle, phase)
        return outputDirectory
            .appendingPathComponent("heap", isDirectory: true)
            .appendingPathComponent(filename)
    }

    func append(_ sample: MetricSample) throws {
        samples.append(sample)

        let json = try Self.encoder(pretty: false).encode(sample) + Data("\n".utf8)
        try jsonlHandle.write(contentsOf: json)
        try jsonlHandle.synchronize()

        let fields: [String] = [
            sample.timestamp,
            String(format: "%.3f", sample.uptimeSeconds),
            String(sample.cycle),
            sample.phase,
            String(sample.phaseElapsedMilliseconds),
            String(sample.mlxActiveBytes),
            String(sample.mlxCacheBytes),
            sample.physicalFootprintBytes.map(String.init) ?? "",
            sample.mallocBlocksInUse.map(String.init) ?? "",
            sample.mallocBytesInUse.map(String.init) ?? "",
            sample.heapNodeCount.map(String.init) ?? "",
            sample.agxFamilyBufferCount.map(String.init) ?? "",
            sample.deepSampleStatus,
            sample.deepSampleReport ?? "",
            sample.transcriptionCharacters.map(String.init) ?? "",
            sample.error ?? ""
        ]
        let row = fields.map(Self.csvEscape).joined(separator: ",") + "\n"
        try csvHandle.write(contentsOf: Data(row.utf8))
        try csvHandle.synchronize()
    }

    func finish(requestedCycles: Int, completedCycles: Int, failedCycles: Int) throws -> RunSummary {
        let initial = samples.first(where: { $0.phase == "initial" })
        let postUnload = samples.filter { $0.phase == "post-unload" }
        let final = postUnload.last

        let summary = RunSummary(
            startedAt: startedAt,
            finishedAt: Self.timestamp(),
            requestedCycles: requestedCycles,
            completedCycles: completedCycles,
            failedCycles: failedCycles,
            initialFootprintBytes: initial?.physicalFootprintBytes,
            finalFootprintBytes: final?.physicalFootprintBytes,
            footprintDeltaBytes: Self.delta(initial?.physicalFootprintBytes, final?.physicalFootprintBytes),
            postUnloadFootprintSlopeBytesPerCycle: Self.footprintSlope(postUnload),
            initialHeapNodeCount: initial?.heapNodeCount,
            finalHeapNodeCount: final?.heapNodeCount,
            heapNodeDelta: Self.delta(initial?.heapNodeCount, final?.heapNodeCount),
            initialAGXFamilyBufferCount: initial?.agxFamilyBufferCount,
            finalAGXFamilyBufferCount: final?.agxFamilyBufferCount,
            agxFamilyBufferDelta: Self.delta(
                initial?.agxFamilyBufferCount,
                final?.agxFamilyBufferCount
            )
        )
        try Self.encoder(pretty: true).encode(summary).write(
            to: outputDirectory.appendingPathComponent("summary.json"),
            options: .atomic
        )
        return summary
    }

    static func footprintSlope(_ samples: [MetricSample]) -> Double? {
        let points = samples.compactMap { sample -> (Double, Double)? in
            guard let footprint = sample.physicalFootprintBytes else { return nil }
            return (Double(sample.cycle), Double(footprint))
        }
        guard points.count >= 2 else { return nil }
        let xMean = points.map(\.0).reduce(0, +) / Double(points.count)
        let yMean = points.map(\.1).reduce(0, +) / Double(points.count)
        let numerator = points.reduce(0) { $0 + ($1.0 - xMean) * ($1.1 - yMean) }
        let denominator = points.reduce(0) { $0 + pow($1.0 - xMean, 2) }
        return denominator == 0 ? nil : numerator / denominator
    }

    static func csvEscape(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else {
            return value
        }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func delta(_ first: UInt64?, _ last: UInt64?) -> Int64? {
        guard let first, let last else { return nil }
        return Int64(last) - Int64(first)
    }

    private static func delta(_ first: Int?, _ last: Int?) -> Int? {
        guard let first, let last else { return nil }
        return last - first
    }

    private static func encoder(pretty: Bool) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return encoder
    }

    static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}
