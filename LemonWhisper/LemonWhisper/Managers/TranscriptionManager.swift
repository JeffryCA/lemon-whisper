import Foundation
import AVFoundation
import Carbon
import AppKit
import ApplicationServices

enum TranscriptionBackend: String, CaseIterable, Identifiable, Hashable {
    case whisper
    case voxtral
    case qwen

    static var defaultForCurrentMac: Self {
        PlatformCapabilities.isAppleSilicon ? .qwen : .whisper
    }

    var id: String { rawValue }

    var supportsVocabularyHints: Bool { self == .whisper || self == .qwen }
    var supportsLivePreview: Bool { self == .qwen }

    var title: String {
        switch self {
        case .whisper:
            return "Whisper"
        case .voxtral:
            return "Voxtral"
        case .qwen:
            return "Qwen3-ASR"
        }
    }
}

class TranscriptionManager {
    static let shared = TranscriptionManager()
    private let textInsertionService = TextInsertionService()

    @MainActor
    func beginLiveDictation(processID: pid_t?) -> LiveDictationInsertion? {
        textInsertionService.beginLiveDictation(processID: processID)
    }

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
                defer { try? FileManager.default.removeItem(at: tempURL) }
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
                case .qwen:
                    let text = try await QwenService.shared.transcribe(audioURL: tempURL, language: language, context: prompt)
                    completion(text.trimmingCharacters(in: .whitespacesAndNewlines))
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
        recordingStartedAt: Date? = nil,
        recordingStoppedAt: Date? = nil,
        dictionary: TranscriptionDictionary = .init(),
        context: String? = nil,
        liveInsertion: LiveDictationInsertion? = nil,
        audioStartFrame: Int = 0,
        liveHistorySegments: [LiveDictationHistorySegment] = [],
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
            if !liveHistorySegments.isEmpty {
                await TranscriptionHistoryStore.shared.recordLiveSegments(
                    liveHistorySegments, language: language, backend: backend, targetBundleIdentifier: targetBundleIdentifier
                )
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
                    let duration = Double(sampleCount) / file.processingFormat.sampleRate

                    let ctx = try await ensureWhisperContextLoaded()

                    result = await ctx.transcribeRecording(
                        samples: samples,
                        language: language,
                        prompt: context,
                        // The VAD requires 250 ms of detected speech. For sub-second clips,
                        // bypass it so a quick word is not discarded before transcription.
                        useVAD: duration >= 1
                    )
                case .qwen:
                    if audioStartFrame > 0 {
                        guard let tail = try FileManager.default.copyWavTail(url, from: audioStartFrame) else {
                            debugLog("No audio was recorded after the last manual edit.")
                            return
                        }
                        defer { try? FileManager.default.removeItem(at: tail) }
                        result = try await QwenService.shared.transcribe(audioURL: tail, language: language, context: context)
                    } else {
                        result = try await QwenService.shared.transcribe(audioURL: url, language: language, context: context)
                    }
                case .voxtral:
                    result = try await VoxtralService.shared.transcribe(audioURL: url, language: language)
                }

                let sanitized = result.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !sanitized.isEmpty else {
                    await liveInsertion?.discardLive()
                    debugLog("⚠️ Transcription produced no text (backend: \(backend.rawValue), file: \(url.lastPathComponent))")
                    return
                }

                let savedRecord: TranscriptionRecord?
                let pasteText: String
                if sanitized != "Transcription failed." {
                    pasteText = dictionary.applyingCorrections(to: sanitized)
                    savedRecord = await TranscriptionHistoryStore.shared.record(
                        rawText: sanitized,
                        correctedText: pasteText == sanitized ? nil : pasteText,
                        language: language,
                        backend: backend,
                        targetBundleIdentifier: targetBundleIdentifier,
                        recordingStartedAt: recordingStartedAt,
                        recordingStoppedAt: recordingStoppedAt
                    )
                } else {
                    await liveInsertion?.discardLive()
                    if liveInsertion != nil { return }
                    savedRecord = nil
                    pasteText = sanitized
                }

                let expandedText = PrivateDictationSnippets.expanding(in: pasteText)
                let insertionResult = await copyAndPaste(
                    expandedText,
                    targetBundleIdentifier: targetBundleIdentifier,
                    targetProcessID: targetProcessID,
                    liveInsertion: liveInsertion
                )

                if sanitized != "Transcription failed." {
                    logTranscriptionProcessing(
                        id: savedRecord?.id,
                        backend: backend.rawValue,
                        original: result,
                        dictionaryCorrected: pasteText,
                        processed: expandedText.trimmingCharacters(in: .whitespacesAndNewlines),
                        pasteSucceeded: insertionResult.succeeded
                    )
                }

                if let savedRecord {
                    await TranscriptionHistoryStore.shared.updatePasteMetadata(
                        id: savedRecord.id,
                        pasteStatus: insertionResult.succeeded ? "succeeded" : "failed",
                        pastePath: insertionResult.path?.rawValue,
                        pasteError: insertionResult.errorMessage
                    )
                }

            } catch {
                await liveInsertion?.discardLive()
                debugLog("❌ Error during transcription (backend: \(backend.rawValue), file: \(url.lastPathComponent)): \(error)")
            }
        }
    }

    @MainActor
    func copyAndPaste(
        _ text: String,
        targetBundleIdentifier: String?,
        targetProcessID: pid_t?,
        liveInsertion: LiveDictationInsertion? = nil
    ) async -> TextInsertionResult {
        let sanitized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty else {
            return TextInsertionResult(path: nil, errorMessage: "Cannot paste empty text.")
        }

        let insertionResult: TextInsertionResult
        if let result = await liveInsertion?.finishLive(sanitized) {
            TextInsertionService.copyTextToPasteboard(sanitized)
            insertionResult = result
        } else {
            insertionResult = textInsertionService.insertText(
                sanitized,
                targetBundleIdentifier: targetBundleIdentifier,
                targetProcessID: targetProcessID
            )
        }

        if !insertionResult.succeeded {
            debugLog("❌ \(insertionResult.errorMessage ?? "All paste paths failed")")
            return insertionResult
        }

        if let path = insertionResult.path {
            debugLog("✅ Paste path: \(path.logLabel)")
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
