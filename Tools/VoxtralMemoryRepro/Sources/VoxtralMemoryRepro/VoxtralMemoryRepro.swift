import Darwin
import Foundation
import MLX
import VoxtralCore

@main
struct VoxtralMemoryRepro {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.contains("--help") || arguments.contains("-h") {
            print(Configuration.usage)
            return
        }

        do {
            let configuration = try Configuration.parse(arguments)
            try await run(configuration)
        } catch {
            writeDiagnostic("error: \(error.localizedDescription)")
            exit(error is ReproError ? 2 : 1)
        }
    }

    private static func run(_ configuration: Configuration) async throws {
        let modelPath = try configuration.requireDownloadedModel()
        let reporter = try Reporter(configuration: configuration)
        writeDiagnostic("Pinned MLX 0.31.6 / mlx-voxtral-swift 2.2.0")
        writeDiagnostic("Model: \(configuration.modelID) at \(modelPath.path)")
        writeDiagnostic("Results: \(reporter.outputDirectory.path)")
        writeDiagnostic("Do not run LemonWhisper concurrently with this reproduction.")

        try reporter.append(sample(
            reporter: reporter,
            cycle: 0,
            phase: "initial",
            phaseStartedAt: ProcessInfo.processInfo.systemUptime,
            deep: true,
            transcriptionCharacters: nil,
            error: nil
        ))

        var completedCycles = 0
        var failedCycles = 0

        for cycle in 1...configuration.cycles {
            writeDiagnostic("Cycle \(cycle)/\(configuration.cycles): load")
            var pipeline: VoxtralPipeline? = VoxtralPipeline(
                model: configuration.pipelineModel,
                backend: .mlx,
                configuration: pipelineConfiguration()
            )
            var cycleError: Error?
            var transcriptionCharacters: Int?

            let loadStartedAt = ProcessInfo.processInfo.systemUptime
            do {
                try await pipeline?.loadModel { progress, status in
                    let percent = Int(progress * 100)
                    writeDiagnostic("Cycle \(cycle) load [\(percent)%] \(status)")
                }
                try reporter.append(sample(
                    reporter: reporter,
                    cycle: cycle,
                    phase: "post-load",
                    phaseStartedAt: loadStartedAt,
                    deep: false,
                    transcriptionCharacters: nil,
                    error: nil
                ))

                writeDiagnostic("Cycle \(cycle)/\(configuration.cycles): transcribe")
                let transcriptionStartedAt = ProcessInfo.processInfo.systemUptime
                let text = try await pipeline?.transcribe(
                    audio: URL(fileURLWithPath: configuration.audioPath),
                    language: configuration.normalizedLanguage
                ) ?? ""
                transcriptionCharacters = text.count
                try reporter.append(sample(
                    reporter: reporter,
                    cycle: cycle,
                    phase: "post-transcribe",
                    phaseStartedAt: transcriptionStartedAt,
                    deep: false,
                    transcriptionCharacters: text.count,
                    error: nil
                ))
                completedCycles += 1
            } catch {
                cycleError = error
                failedCycles += 1
                writeDiagnostic("Cycle \(cycle) failed: \(error.localizedDescription)")
            }

            let unloadStartedAt = ProcessInfo.processInfo.systemUptime
            pipeline?.unload()
            pipeline = nil
            if configuration.clearMLXCache {
                Memory.clearCache()
            }
            if configuration.settleMilliseconds > 0 {
                try await Task.sleep(
                    for: .milliseconds(configuration.settleMilliseconds)
                )
            }

            let shouldDeepSample = configuration.deepSampleEvery > 0
                && cycle.isMultiple(of: configuration.deepSampleEvery)
            try reporter.append(sample(
                reporter: reporter,
                cycle: cycle,
                phase: "post-unload",
                phaseStartedAt: unloadStartedAt,
                deep: shouldDeepSample,
                transcriptionCharacters: transcriptionCharacters,
                error: cycleError?.localizedDescription
            ))

            if cycleError != nil && configuration.stopOnError {
                break
            }
        }

        let summary = try reporter.finish(
            requestedCycles: configuration.cycles,
            completedCycles: completedCycles,
            failedCycles: failedCycles
        )
        let slopeMB = summary.postUnloadFootprintSlopeBytesPerCycle.map {
            String(format: "%.3f", $0 / 1_048_576)
        } ?? "unavailable"
        writeDiagnostic("Finished: \(completedCycles) succeeded, \(failedCycles) failed")
        writeDiagnostic("Post-unload footprint slope: \(slopeMB) MiB/cycle")
        writeDiagnostic("Summary: \(reporter.outputDirectory.appendingPathComponent("summary.json").path)")
    }

    private static func pipelineConfiguration() -> VoxtralPipeline.Configuration {
        var configuration = VoxtralPipeline.Configuration.default
        configuration.temperature = 0
        configuration.maxTokens = 500
        return configuration
    }

    private static func sample(
        reporter: Reporter,
        cycle: Int,
        phase: String,
        phaseStartedAt: TimeInterval,
        deep: Bool,
        transcriptionCharacters: Int?,
        error: String?
    ) -> MetricSample {
        let malloc = ProcessMetrics.mallocStatistics()
        let heap: HeapMetrics
        if deep {
            heap = ProcessMetrics.deepHeapSample(
                processID: getpid(),
                reportURL: reporter.heapReportURL(cycle: cycle, phase: phase)
            )
        } else {
            heap = HeapMetrics(
                nodeCount: nil,
                agxFamilyBufferCount: nil,
                status: "not-requested",
                rawReportPath: nil
            )
        }

        return MetricSample(
            timestamp: Reporter.timestamp(),
            uptimeSeconds: ProcessInfo.processInfo.systemUptime,
            cycle: cycle,
            phase: phase,
            phaseElapsedMilliseconds: Int(
                (ProcessInfo.processInfo.systemUptime - phaseStartedAt) * 1_000
            ),
            mlxActiveBytes: Memory.activeMemory,
            mlxCacheBytes: Memory.cacheMemory,
            physicalFootprintBytes: ProcessMetrics.physicalFootprintBytes(),
            mallocBlocksInUse: malloc?.blocks,
            mallocBytesInUse: malloc?.bytes,
            heapNodeCount: heap.nodeCount,
            agxFamilyBufferCount: heap.agxFamilyBufferCount,
            deepSampleStatus: heap.status,
            deepSampleReport: heap.rawReportPath,
            transcriptionCharacters: transcriptionCharacters,
            error: error
        )
    }
}

func writeDiagnostic(_ message: String) {
    let line = Data(("[voxtral-memory-repro] " + message + "\n").utf8)
    try? FileHandle.standardError.write(contentsOf: line)
}
