import SwiftUI
import AVFoundation
import ApplicationServices
import Carbon

extension Notification.Name {
    static let toggleRecordingHotKey = Notification.Name("toggleRecordingHotKey")
}

private func hotKeyHandler(
    nextHandler: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    DispatchQueue.main.async {
        NotificationCenter.default.post(name: .toggleRecordingHotKey, object: nil)
    }
    return noErr
}

struct ContentView: View {
    @State private var isRecording = false
    @StateObject private var recorder = AudioRecorder()
    @State private var isTranscribing = false
    @State private var transcription = ""
    @State private var whisperCtx: WhisperContext?
    @State private var previouslyActiveApp: NSRunningApplication?
    
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
        }
        .padding()
        .onAppear {
            requestMicrophonePermission()
            requestAccessibilityPermission()
            setupWhisperContext()
            setupHotKey()
        }
    }

    func toggleRecording() {
        if isRecording {
            recorder.stopRecording()
            Task {
                await transcribe()
            }
        } else {
            previouslyActiveApp = NSWorkspace.shared.frontmostApplication
            recorder.startRecording()
        }
        isRecording.toggle()
    }
    
    func transcribe() async {
        guard let wavURL = recorder.latestWavURL else { return }
        isTranscribing = true
        transcription = ""   // clear previous
        
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

            // 2. Use previously loaded Whisper context
            guard let ctx = whisperCtx else {
                throw NSError(domain: "ModelNotReady", code: -1)
            }

            // 3. Run transcription
            let ok = await ctx.fullTranscribe(samples: samples)
            let result = ok ? await ctx.getTranscription().trimmingCharacters(in: .whitespacesAndNewlines) : "Transcription failed."

            // 4. Update UI on main thread
            await MainActor.run {
                transcription = result
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result, forType: .string)
                // Explicitly resign first responder before pasting
                NSApp.keyWindow?.makeFirstResponder(nil)

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    let src = CGEventSource(stateID: .hidSystemState)
                    let vDown = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true) // V key
                    let vUp = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false)
                    vDown?.flags = .maskCommand
                    vDown?.post(tap: .cgAnnotatedSessionEventTap)
                    vUp?.post(tap: .cgAnnotatedSessionEventTap)
                    isTranscribing = false
                }
            }
        } catch {
            await MainActor.run {
                transcription = "Error: \(error.localizedDescription)"
                isTranscribing = false
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

    func requestAccessibilityPermission() {
        if !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
    }

    func setupWhisperContext() {
        Task {
            let modelURL = Bundle.main.url(forResource: "ggml-large-v3-turbo", withExtension: "bin")!
            whisperCtx = try? await WhisperContext.createContext(path: modelURL.path)
        }
    }

    func setupHotKey() {
        let keyCodeGermanY: UInt32 = UInt32(kVK_ANSI_Z) // "Y" on German keyboard layout
        let modifiers: UInt32 = UInt32(controlKey)

        let hotKeyID = EventHotKeyID(signature: OSType(32), id: 1)
        var hotKeyRef: EventHotKeyRef?
        RegisterEventHotKey(keyCodeGermanY, modifiers, hotKeyID, GetEventDispatcherTarget(), 0, &hotKeyRef)

        InstallEventHandler(
            GetEventDispatcherTarget(),
            hotKeyHandler,
            1,
            [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))],
            nil,
            nil
        )

        NotificationCenter.default.addObserver(forName: .toggleRecordingHotKey, object: nil, queue: .main) { _ in
            toggleRecording()
        }
    }

}


struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}

    