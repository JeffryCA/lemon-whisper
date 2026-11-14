import AVFoundation
import Darwin
import Foundation
import VoxtralCore
import MLXAudioCore
import MLXAudioSTT

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
    private var qwenModel: Qwen3ASRModel?
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
            if request.modelID == QwenModelCatalog.modelID {
                guard QwenModelCatalog.isDownloaded else { throw QwenServiceWorkerError.modelMissing }
                if qwenModel == nil {
                    pipeline?.unload()
                    pipeline = nil
                    qwenModel = try await Qwen3ASRModel.fromModelDirectory(QwenModelCatalog.directory)
                    loadedModelID = request.modelID
                }
            } else {
                let prepared = try await loadPipeline(modelID: request.modelID)
                try Task.checkCancellation()
                try await materializeWeights(prepared)
            }
            try Task.checkCancellation()
            // Publishing completion means the worker is ready for the next command. Clear the
            // operation first so an immediate transcription cannot observe a stale busy state.
            operation = nil
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
        guard (pipeline != nil || qwenModel != nil), loadedModelID == request.modelID else {
            fail(request.id, .invalidRequest, "Requested model is not prepared.", true)
            Darwin.exit(1)
        }
        guard FileManager.default.isReadableFile(atPath: request.audioPath) else {
            fail(request.id, .invalidRequest, "Audio file is not readable.", false)
            Darwin.exit(1)
        }
        do {
            let text = try await transcribeFile(
                URL(fileURLWithPath: request.audioPath), request: request
            )
            try Task.checkCancellation()
            operation = nil
            writer.send(.result(VoxtralWorkerResult(requestID: request.id, text: text)))
        } catch is CancellationError {
            writer.send(.cancelled(VoxtralWorkerCancelled(requestID: request.id)))
            pipeline?.unload()
            Darwin.exit(0)
        } catch {
            fail(request.id, .transcriptionFailed, error.localizedDescription, true)
            pipeline?.unload()
            Darwin.exit(1)
        }
    }

    private func transcribeFile(_ url: URL, request: VoxtralWorkerTranscriptionRequest) async throws -> String {
        let file = try AVAudioFile(forReading: url)
        let maxFrames = AVAudioFrameCount(file.processingFormat.sampleRate * TranscriptionAudioPolicy.maximumChunkSeconds)
        guard file.length > AVAudioFramePosition(maxFrames) else {
            return try await transcribeChunk(url, request: request)
        }
        var texts: [String] = []
        while file.framePosition < file.length {
            try Task.checkCancellation()
            let start = file.framePosition
            let capacity = AVAudioFrameCount(min(AVAudioFramePosition(maxFrames), file.length - start))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity) else {
                throw QwenServiceWorkerError.audioAllocationFailed
            }
            try file.read(into: buffer)
            guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else {
                throw QwenServiceWorkerError.audioAllocationFailed
            }
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            let count = TranscriptionAudioPolicy.chunkFrameCount(
                samples: samples, sampleRate: file.processingFormat.sampleRate,
                hasMoreAudio: file.framePosition < file.length
            )
            buffer.frameLength = AVAudioFrameCount(count)
            file.framePosition = start + AVAudioFramePosition(count)
            let chunkURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("lemon-asr-chunk-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: chunkURL) }
            do {
                let output = try AVAudioFile(forWriting: chunkURL, settings: buffer.format.settings)
                try output.write(from: buffer)
            }
            texts.append(try await transcribeChunk(chunkURL, request: request))
        }
        return texts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func transcribeChunk(_ url: URL, request: VoxtralWorkerTranscriptionRequest) async throws -> String {
        if let qwenModel {
            let (_, audio) = try loadAudioArray(from: url, sampleRate: 16_000)
            if request.preview == true {
                var partial = ""
                let clock = ContinuousClock()
                var nextUpdate = clock.now
                for try await event in qwenModel.generateStream(
                    audio: audio, maxTokens: 192, temperature: 0, context: request.context ?? "",
                    language: request.language, chunkDuration: 60
                ) {
                    try Task.checkCancellation()
                    switch event {
                    case .token(let token):
                        partial += token
                        if clock.now >= nextUpdate {
                            writer.send(.partial(VoxtralWorkerPartial(requestID: request.id, text: partial)))
                            nextUpdate = clock.now + .milliseconds(90)
                        }
                    case .result(let output):
                        return output.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    default:
                        break
                    }
                }
                try Task.checkCancellation()
                throw QwenServiceWorkerError.missingPreviewResult
            }

            let output = qwenModel.generate(
                audio: audio, maxTokens: TranscriptionAudioPolicy.maximumOutputTokens,
                temperature: 0, context: request.context ?? "", language: request.language, chunkDuration: 60
            )
            // Our external chunks never exceed 60 seconds, so this is a per-request check.
            guard output.generationTokens < TranscriptionAudioPolicy.maximumOutputTokens else {
                throw QwenServiceWorkerError.outputLimitReached
            }
            return output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let pipeline else { throw QwenServiceWorkerError.modelMissing }
        return try await pipeline.transcribe(audio: url, language: request.language)
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
        configuration.maxTokens = TranscriptionAudioPolicy.maximumOutputTokens
        qwenModel = nil
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

private enum QwenServiceWorkerError: LocalizedError {
    case modelMissing, audioAllocationFailed, outputLimitReached, missingPreviewResult
    var errorDescription: String? {
        switch self {
        case .missingPreviewResult: return "Qwen3-ASR did not return a live preview."
        case .modelMissing: return "The requested local model is not downloaded."
        case .audioAllocationFailed: return "Could not read the audio chunk."
        case .outputLimitReached: return "The transcription reached its output limit. Try a shorter recording."
        }
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
