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
            // Request Accessibility permission
            if !AXIsProcessTrusted() {
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            }
            Task {
                let modelURL = Bundle.main.url(forResource: "ggml-large-v3-turbo", withExtension: "bin")!
                whisperCtx = try? await WhisperContext.createContext(path: modelURL.path)
            }

            // Hotkey setup: control + Y (German keyboard: Y is kVK_ANSI_Z)
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

    func toggleRecording() {
        if isRecording {
            recorder.stopRecording()
            transcribe()
        } else {
            previouslyActiveApp = NSWorkspace.shared.frontmostApplication
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

                // 2. Use previously loaded Whisper context
                guard let whisperCtx = whisperCtx else {
                    throw NSError(domain: "ModelNotReady", code: -1)
                }

                // 3. Run transcription
                let ok = await whisperCtx.fullTranscribe(samples: samples)
                let result = ok ? await whisperCtx.getTranscription() : "Transcription failed."

                // 4. Update UI on main thread
                await MainActor.run {
                    transcription = result
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(result, forType: .string)
                    // Hide our app and activate the previously focused app
                    if let prevApp = previouslyActiveApp {
                        prevApp.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
                    }
                    NSApp.hide(nil)

                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                        let cmdDown = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Command), keyDown: true)
                        let vDown = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
                        let vUp = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
                        let cmdUp = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Command), keyDown: false)

                        vDown?.flags = .maskCommand
                        vUp?.flags = .maskCommand

                        cmdDown?.post(tap: .cgAnnotatedSessionEventTap)
                        vDown?.post(tap: .cgAnnotatedSessionEventTap)
                        vUp?.post(tap: .cgAnnotatedSessionEventTap)
                        cmdUp?.post(tap: .cgAnnotatedSessionEventTap)
                    }
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
