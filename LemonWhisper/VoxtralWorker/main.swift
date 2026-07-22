import AVFoundation
import Darwin
import Foundation
import VoxtralCore

private final class ProtocolWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()

    init() throws {
        let protocolDescriptor = dup(STDOUT_FILENO)
        guard protocolDescriptor >= 0 else { throw POSIXError(.EBADF) }
        // Keep third-party diagnostics off the protocol stream.
        guard dup2(STDERR_FILENO, STDOUT_FILENO) >= 0 else { throw POSIXError(.EBADF) }
        handle = FileHandle(fileDescriptor: protocolDescriptor, closeOnDealloc: true)
    }

    func send(_ event: VoxtralWorkerEvent) {
        lock.lock()
        defer { lock.unlock() }
        do {
            try handle.write(contentsOf: VoxtralJSONLineEncoder<VoxtralWorkerEvent>().encode(event))
        } catch {
            fputs("VoxtralWorker protocol write failed: \(error)\n", stderr)
            Darwin.exit(74)
        }
    }
}

private actor VoxtralWorkerEngine {
    private let writer: ProtocolWriter
    private var pipeline: VoxtralPipeline?
    private var loadedModelID: String?
    private var operation: Task<Void, Never>?

    init(writer: ProtocolWriter) { self.writer = writer }

    func accept(_ command: VoxtralWorkerCommand) {
        switch command {
        case .prepare(let request):
            guard operation == nil else { return failBusy(request.id) }
            operation = Task { await prepare(request) }
        case .transcribe(let request):
            guard operation == nil else { return failBusy(request.id) }
            operation = Task { await transcribe(request) }
        case .cancel(let request):
            operation?.cancel()
            pipeline?.unload()
            writer.send(.cancelled(VoxtralWorkerCancelled(requestID: request.id)))
            Darwin.exit(0)
        case .shutdown:
            operation?.cancel()
            pipeline?.unload()
            Darwin.exit(0)
        }
    }

    private func prepare(_ request: VoxtralWorkerPrepareRequest) async {
        defer { operation = nil }
        do {
            let prepared = try await loadPipeline(modelID: request.modelID)
            try Task.checkCancellation()
            try await materializeWeights(prepared)
            try Task.checkCancellation()
            writer.send(.prepared(VoxtralWorkerPrepared(requestID: request.id, modelID: request.modelID)))
        } catch is CancellationError {
            writer.send(.cancelled(VoxtralWorkerCancelled(requestID: request.id)))
            Darwin.exit(0)
        } catch {
            fail(request.id, .modelLoadFailed, error.localizedDescription, true)
            Darwin.exit(1)
        }
    }

    private func transcribe(_ request: VoxtralWorkerTranscriptionRequest) async {
        defer { operation = nil }
        guard let pipeline, loadedModelID == request.modelID else {
            fail(request.id, .invalidRequest, "Requested model is not prepared.", true)
            Darwin.exit(1)
        }
        guard FileManager.default.isReadableFile(atPath: request.audioPath) else {
            fail(request.id, .invalidRequest, "Audio file is not readable.", false)
            Darwin.exit(1)
        }
        do {
            let text = try await pipeline.transcribe(
                audio: URL(fileURLWithPath: request.audioPath), language: request.language
            )
            try Task.checkCancellation()
            writer.send(.result(VoxtralWorkerResult(requestID: request.id, text: text)))
            pipeline.unload()
            Darwin.exit(0)
        } catch is CancellationError {
            writer.send(.cancelled(VoxtralWorkerCancelled(requestID: request.id)))
            pipeline.unload()
            Darwin.exit(0)
        } catch {
            fail(request.id, .transcriptionFailed, error.localizedDescription, true)
            pipeline.unload()
            Darwin.exit(1)
        }
    }

    private func loadPipeline(modelID: String) async throws -> VoxtralPipeline {
        if let pipeline, loadedModelID == modelID { return pipeline }
        guard let model = Self.pipelineModel(for: modelID) else {
            throw VoxtralWorkerError(
                code: .invalidRequest, message: "Unsupported Voxtral model: \(modelID)", isRetryable: false
            )
        }
        var configuration = VoxtralPipeline.Configuration.default
        configuration.temperature = 0
        configuration.maxTokens = 500
        let pipeline = VoxtralPipeline(model: model, backend: .mlx, configuration: configuration)
        try await pipeline.loadModel { progress, status in
            fputs("Voxtral load [\(Int(progress * 100))%] \(status)\n", stderr)
        }
        self.pipeline = pipeline
        loadedModelID = modelID
        return pipeline
    }

    private func materializeWeights(_ pipeline: VoxtralPipeline) async throws {
        let silenceURL = try Self.makeSilentClip()
        defer { try? FileManager.default.removeItem(at: silenceURL) }
        _ = try await pipeline.transcribe(audio: silenceURL, language: "en")
    }

    private func failBusy(_ requestID: UUID) {
        fail(requestID, .invalidCommand, "Worker is already busy.", true)
    }

    private func fail(_ requestID: UUID?, _ code: VoxtralWorkerError.Code, _ message: String, _ retryable: Bool) {
        writer.send(.failure(VoxtralWorkerFailure(
            requestID: requestID,
            error: VoxtralWorkerError(code: code, message: message, isRetryable: retryable)
        )))
    }

    private static func pipelineModel(for id: String) -> VoxtralPipeline.Model? {
        switch id {
        case "mini-3b": return .mini3b
        case "mini-3b-8bit": return .mini3b8bit
        case "mini-3b-4bit": return .mini3b4bit
        default: return nil
        }
    }

    private static func makeSilentClip() throws -> URL {
        let sampleRate = 16_000.0
        let frames = AVAudioFrameCount(sampleRate * 0.3)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
        ), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw VoxtralWorkerError(
                code: .internalError, message: "Could not allocate warmup audio.", isRetryable: true
            )
        }
        buffer.frameLength = frames
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxtral-worker-warmup-\(UUID().uuidString).wav")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }
}

@main
private struct VoxtralWorkerMain {
    static func main() async {
        do {
            let writer = try ProtocolWriter()
            writer.send(.hello(VoxtralWorkerHello(workerPID: getpid())))
            let engine = VoxtralWorkerEngine(writer: writer)
            var parser = VoxtralJSONLineParser<VoxtralWorkerCommand>()
            while true {
                let data = FileHandle.standardInput.availableData
                if data.isEmpty { try parser.finish(); break }
                for command in try parser.append(data) { await engine.accept(command) }
            }
        } catch {
            fputs("VoxtralWorker fatal error: \(error)\n", stderr)
            Darwin.exit(1)
        }
    }
}
