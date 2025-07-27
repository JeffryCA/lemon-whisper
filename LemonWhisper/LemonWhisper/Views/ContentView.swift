import SwiftUI
import AVFoundation

struct ContentView: View {
    @State private var isRecording = false
    @StateObject private var recorder = AudioRecorder()
    @State private var isTranscribing = false
    @State private var transcription = ""
    
    private var canTranscribe: Bool {
        !isRecording && recorder.latestWavURL != nil && !isTranscribing
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("Simple Recorder")
                .font(.largeTitle)

            // Record / Stop button
            Button(action: { toggleRecording() }) {
                Text(isRecording ? "Stop Recording" : "Start Recording")
                    .padding()
                    .background(isRecording ? Color.red : Color.green)
                    .foregroundColor(.white)
                    .cornerRadius(10)
            }

            // Transcribe button
            Button(action: { transcribe() }) {
                Text(isTranscribing ? "Transcribing…" : "Transcribe")
                    .padding()
                    .background(canTranscribe ? Color.blue : Color.gray)
                    .foregroundColor(.white)
                    .cornerRadius(10)
            }
            .disabled(!canTranscribe)

            Text("Transcription")
                .font(.headline)
                .padding(.top)

            // Text box for result
            TextEditor(text: $transcription)
                .frame(minHeight: 150)
                .border(Color.secondary)
        }
        .padding()
        .onAppear(perform: requestMicrophonePermission)
    }

    func toggleRecording() {
        if isRecording {
            recorder.stopRecording()
        } else {
            recorder.startRecording()
        }
        isRecording.toggle()
    }
    
    func transcribe() {
        guard let wavURL = recorder.latestWavURL else { return }
        isTranscribing = true
        transcription = ""   // clear previous
        
        Task.detached {
            do {
                // 1. Load WAV samples as Float32
                let file = try AVAudioFile(forReading: wavURL)
                let totalFrames = Int(file.length)
                guard
                    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                  frameCapacity: AVAudioFrameCount(totalFrames))
                else { throw NSError(domain: "BufferFail", code: -1) }
                try file.read(into: buffer)
                
                // Down‑mix to mono if needed
                guard let floatData = buffer.floatChannelData else { throw NSError(domain: "NoData", code: -2) }
                let channelPtr = floatData[0]   // assuming mono
                let sampleCount = Int(buffer.frameLength)
                let samples = Array(UnsafeBufferPointer(start: channelPtr, count: sampleCount))
                
                // 2. Lazy‑init Whisper context (singleton)
                let modelURL = Bundle.main.url(forResource: "ggml-large-v3-turbo", withExtension: "bin")!
                let whisperCtx = try await WhisperContext.createContext(path: modelURL.path)
                
                // 3. Run transcription
                let ok = await whisperCtx.fullTranscribe(samples: samples)
                let result = ok ? await whisperCtx.getTranscription() : "Transcription failed."
                
                // 4. Update UI on main thread
                await MainActor.run {
                    transcription = result
                    isTranscribing = false
                }
            } catch {
                await MainActor.run {
                    transcription = "Error: \(error.localizedDescription)"
                    isTranscribing = false
                }
            }
        }
    }
    
    func requestMicrophonePermission() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            if granted {
                print("✅ Microphone permission granted")
            } else {
                print("❌ Microphone permission denied")
            }
        }
    }

}


struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
