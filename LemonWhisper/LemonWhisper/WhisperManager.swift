
import Foundation
import AVFoundation
import SwiftUI

@MainActor
class WhisperManager: ObservableObject {
    @Published var isRecording = false
    @Published var transcription = ""
    @Published var showAlert = false
    @Published var alertMessage = ""

    private var whisperContext: WhisperContext?
    private var audioRecorder: AVAudioRecorder?
    private var audioEngine: AVAudioEngine?
    private var audioPlayer: AVAudioPlayer?
    private var recordingURL: URL?

    init() {
        // Initialize Whisper
        Task {
            await initializeWhisper()
        }
    }

    private func initializeWhisper() async {
        guard let modelURL = Bundle.main.url(forResource: "ggml-large-v3-turbo", withExtension: "bin"),
              let vadURL = Bundle.main.url(forResource: "ggml-silero-v5.1.2", withExtension: "bin")
        else {
            self.alertMessage = "Model files not found in the application bundle."
            self.showAlert = true
            return
        }

        let modelPath = modelURL.path
        let vadModelPath = vadURL.path

        do {
            self.whisperContext = try await WhisperContext.createContext(path: modelPath)
            await self.whisperContext?.setVADModelPath(vadModelPath)
        } catch {
            self.alertMessage = "Error initializing Whisper: \(error)"
            self.showAlert = true
        }
    }

    func startRecording() {
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "recording.wav"
        recordingURL = tempDir.appendingPathComponent(fileName)

        let settings = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        do {
            audioRecorder = try AVAudioRecorder(url: recordingURL!, settings: settings)
            audioRecorder?.record()
            isRecording = true
        } catch {
            print("Could not start recording: \(error)")
        }
    }

    func stopRecording() {
        audioRecorder?.stop()
        isRecording = false
        transcribe()
    }

    func startLiveRecording() {
        audioEngine = AVAudioEngine()
        let inputNode = audioEngine!.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { (buffer, when) in
            let floatArray = buffer.floatChannelData![0]
            let frameLength = buffer.frameLength
            let samples = Array(UnsafeBufferPointer(start: floatArray, count: Int(frameLength)))
            
            Task {
                if await self.whisperContext?.fullTranscribe(samples: samples) == true {
                    if let newTranscription = await self.whisperContext?.getTranscription() {
                        DispatchQueue.main.async {
                            self.transcription = newTranscription
                            self.paste()
                        }
                    }
                }
            }
        }

        do {
            try audioEngine?.start()
            isRecording = true
        } catch {
            print("Could not start audio engine: \(error)")
        }
    }

    func stopLiveRecording() {
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        isRecording = false
    }

    private func transcribe() {
        guard let recordingURL = recordingURL else { return }

        Task {
            do {
                let audioData = try Data(contentsOf: recordingURL)
                let samples = audioData.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> [Float] in
                    let int16Pointer = bytes.baseAddress!.assumingMemoryBound(to: Int16.self)
                    let sampleCount = bytes.count / MemoryLayout<Int16>.size
                    var floatSamples = [Float](repeating: 0.0, count: sampleCount)
                    for i in 0..<sampleCount {
                        floatSamples[i] = Float(int16Pointer[i]) / 32768.0
                    }
                    return floatSamples
                }

                if await whisperContext?.fullTranscribe(samples: samples) == true {
                    if let newTranscription = await whisperContext?.getTranscription() {
                        DispatchQueue.main.async {
                            self.transcription = newTranscription
                            self.paste()
                        }
                    }
                }
            } catch {
                self.alertMessage = "Error transcribing audio: \(error)"
                self.showAlert = true
            }
        }
    }

    private func paste() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(transcription, forType: .string)

        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
