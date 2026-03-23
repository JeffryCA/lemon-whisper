import Foundation
import AVFoundation
import Carbon
import AppKit
import ApplicationServices

enum TranscriptionBackend: String, CaseIterable, Identifiable {
    case whisper
    case voxtral

    var id: String { rawValue }

    var title: String {
        switch self {
        case .whisper:
            return "Whisper"
        case .voxtral:
            return "Voxtral"
        }
    }
}

class TranscriptionManager {
    static let shared = TranscriptionManager()
    private let textInsertionService = TextInsertionService()

    func transcribe(
        buffer: AVAudioPCMBuffer,
        language: String = "en",
        prompt: String? = nil,
        isLiveMode: Bool = false,
        backend: TranscriptionBackend = .whisper,
        completion: @escaping (String) -> Void
    ) {
        Task {
            do {
                let tempURL = try FileManager.default.writeBufferToWav(buffer)
                let file = try AVAudioFile(forReading: tempURL)
                let totalFrames = Int(file.length)
                guard
                    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                  frameCapacity: AVAudioFrameCount(totalFrames))
                else { throw NSError(domain: "BufferFail", code: -1) }
                try file.read(into: buffer)

                guard let floatData = buffer.floatChannelData else { throw NSError(domain: "NoData", code: -2) }
                let channelPtr = floatData[0]
                let sampleCount = Int(buffer.frameLength)
                let samples = Array(UnsafeBufferPointer(start: channelPtr, count: sampleCount))

                switch backend {
                case .whisper:
                    let ctx = try await ensureWhisperContextLoaded()

                    let ok = await ctx.fullTranscribe(
                        samples: samples,
                        language: language,
                        prompt: prompt,
                        isLiveMode: isLiveMode
                    )
                    let result = ok ? await ctx.getTranscription().trimmingCharacters(in: .whitespacesAndNewlines) : "Transcription failed."
                    completion(result)
                case .voxtral:
                    let text = try await VoxtralService.shared.transcribe(audioURL: tempURL, language: language)
                    completion(text.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            } catch {
                print("❌ Error during transcription: \(error)")
                completion("Transcription failed.")
            }
        }
    }

    func transcribe(
        from url: URL,
        language: String = "en",
        backend: TranscriptionBackend,
        targetBundleIdentifier: String?,
        targetProcessID: pid_t?,
        onActivityChanged: ((Bool) -> Void)? = nil
    ) {
        Task {
            await MainActor.run {
                onActivityChanged?(true)
            }
            defer {
                Task { @MainActor in
                    onActivityChanged?(false)
                }
            }
            do {
                let result: String
                switch backend {
                case .whisper:
                    let file = try AVAudioFile(forReading: url)
                    let totalFrames = Int(file.length)
                    guard
                        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                      frameCapacity: AVAudioFrameCount(totalFrames))
                    else { throw NSError(domain: "BufferFail", code: -1) }
                    try file.read(into: buffer)

                    guard let floatData = buffer.floatChannelData else { throw NSError(domain: "NoData", code: -2) }
                    let channelPtr = floatData[0]
                    let sampleCount = Int(buffer.frameLength)
                    let samples = Array(UnsafeBufferPointer(start: channelPtr, count: sampleCount))

                    let ctx = try await ensureWhisperContextLoaded()

                    let ok = await ctx.fullTranscribe(
                        samples: samples,
                        language: language,
                        prompt: nil,
                        isLiveMode: false
                    )
                    result = ok ? await ctx.getTranscription().trimmingCharacters(in: .whitespacesAndNewlines) : "Transcription failed."
                case .voxtral:
                    result = try await VoxtralService.shared.transcribe(audioURL: url, language: language)
                }

                let sanitized = result.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !sanitized.isEmpty else { return }

                let savedRecord: TranscriptionRecord?
                if sanitized != "Transcription failed." {
                    savedRecord = await TranscriptionHistoryStore.shared.record(
                        rawText: sanitized,
                        language: language,
                        backend: backend,
                        targetBundleIdentifier: targetBundleIdentifier
                    )
                } else {
                    savedRecord = nil
                }

                let insertionResult = await copyAndPaste(
                    sanitized,
                    targetBundleIdentifier: targetBundleIdentifier,
                    targetProcessID: targetProcessID
                )

                if let savedRecord {
                    await TranscriptionHistoryStore.shared.updatePasteMetadata(
                        id: savedRecord.id,
                        pasteStatus: insertionResult.succeeded ? "succeeded" : "failed",
                        pastePath: insertionResult.path?.rawValue,
                        pasteError: insertionResult.errorMessage
                    )
                }

            } catch {
                print("❌ Error during transcription: \(error)")
            }
        }
    }

    func copyAndPaste(
        _ text: String,
        targetBundleIdentifier: String?,
        targetProcessID: pid_t?
    ) async -> TextInsertionResult {
        let sanitized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty else {
            return TextInsertionResult(path: nil, errorMessage: "Cannot paste empty text.")
        }

        let insertionResult = await MainActor.run {
            textInsertionService.insertText(
                sanitized,
                targetBundleIdentifier: targetBundleIdentifier,
                targetProcessID: targetProcessID
            )
        }

        if !insertionResult.succeeded {
            print("❌ \(insertionResult.errorMessage ?? "All paste paths failed")")
            return insertionResult
        }

        if let path = insertionResult.path {
            print("✅ Paste path: \(path.logLabel)")
        }
        return insertionResult
    }

    private func ensureWhisperContextLoaded() async throws -> WhisperContext {
        if let existing = WhisperContext.getShared() {
            return existing
        }

        guard let model = WhisperModelCatalog.selectedModelIfDownloaded() else {
            throw NSError(domain: "WhisperModelMissing", code: -1001)
        }

        let context = try await WhisperContext.createContext(path: model.localURL.path)
        try await WhisperModelCatalog.ensureVADDownloadedIfNeeded()
        await context.setVADModelPath(WhisperModelCatalog.vadLocalURL.path)
        return context
    }
}
