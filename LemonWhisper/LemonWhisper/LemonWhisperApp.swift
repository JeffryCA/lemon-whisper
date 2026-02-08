import SwiftUI
import AVFoundation
import ApplicationServices
import Carbon
import AppKit

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

@MainActor
final class LemonWhisperController: ObservableObject {
    @Published var isRecording = false
    @Published var selectedLanguageCode = "en"

    private let recorder = AudioRecorder()
    private var targetBundleIdentifier: String?
    private var targetProcessID: pid_t?
    private var toggleHotKeyRef: EventHotKeyRef?

    struct LanguageOption: Identifiable {
        let id: String
        let title: String
    }

    let languageOptions: [LanguageOption] = [
        LanguageOption(id: "auto", title: "Auto Detect"),
        LanguageOption(id: "en", title: "English"),
        LanguageOption(id: "es", title: "Spanish"),
        LanguageOption(id: "de", title: "German"),
        LanguageOption(id: "fr", title: "French"),
        LanguageOption(id: "it", title: "Italian"),
        LanguageOption(id: "pt", title: "Portuguese"),
        LanguageOption(id: "nl", title: "Dutch"),
        LanguageOption(id: "ru", title: "Russian"),
        LanguageOption(id: "ja", title: "Japanese"),
        LanguageOption(id: "ko", title: "Korean"),
        LanguageOption(id: "zh", title: "Chinese")
    ]

    init() {
        requestMicrophonePermission()
        requestAccessibilityPermission()
        setupHotKeys()
        setupHotKeyObservers()
        preloadWhisperModel()
    }

    func toggleRecording() {
        if isRecording {
            recorder.stopRecording()
            transcribeLatestRecording()
        } else {
            capturePasteTargetApp()
            recorder.startRecording()
        }
        isRecording.toggle()
    }

    private func transcribeLatestRecording() {
        guard let wavURL = recorder.latestWavURL else { return }
        TranscriptionManager.shared.transcribe(
            from: wavURL,
            language: selectedLanguageCode,
            targetBundleIdentifier: targetBundleIdentifier,
            targetProcessID: targetProcessID
        )
    }

    private func capturePasteTargetApp() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        targetBundleIdentifier = frontmost?.bundleIdentifier
        targetProcessID = frontmost?.processIdentifier
        if let appName = frontmost?.localizedName, let pid = targetProcessID {
            print("🎯 Paste target captured: \(appName) (pid: \(pid))")
        } else {
            print("⚠️ Could not capture frontmost app for paste target")
        }
    }

    private func preloadWhisperModel() {
        Task {
            do {
                guard let modelPath = Bundle.main.path(forResource: "ggml-large-v3-turbo", ofType: "bin") else {
                    print("❌ Whisper model not found in bundle resources")
                    return
                }
                _ = try await WhisperContext.createContext(path: modelPath)
            } catch {
                print("❌ Failed to load Whisper model: \(error)")
            }
        }
    }

    private func requestMicrophonePermission() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            if granted {
                print("✅ Microphone permission granted")
            } else {
                print("❌ Microphone permission denied")
            }
        }
    }

    private func requestAccessibilityPermission() {
        if !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
    }

    private func setupHotKeys() {
        let keyCodeGermanY: UInt32 = UInt32(kVK_ANSI_Z) // "Y" on German keyboard layout
        let modifiers: UInt32 = UInt32(controlKey)

        let toggleHotKeyID = EventHotKeyID(signature: OSType(32), id: 1)
        RegisterEventHotKey(
            keyCodeGermanY,
            modifiers,
            toggleHotKeyID,
            GetEventDispatcherTarget(),
            0,
            &toggleHotKeyRef
        )

        InstallEventHandler(
            GetEventDispatcherTarget(),
            hotKeyHandler,
            1,
            [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))],
            nil,
            nil
        )
    }

    private func setupHotKeyObservers() {
        NotificationCenter.default.addObserver(forName: .toggleRecordingHotKey, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.toggleRecording()
            }
        }
    }
}

@main
struct LemonWhisperApp: App {
    @StateObject private var controller = LemonWhisperController()

    var body: some Scene {
        MenuBarExtra {
            Button(controller.isRecording ? "Stop Recording" : "Start Recording (Ctrl+Y)") {
                controller.toggleRecording()
            }
            .keyboardShortcut("y", modifiers: [.control])

            Divider()

            Menu("Language") {
                ForEach(controller.languageOptions) { option in
                    Button {
                        controller.selectedLanguageCode = option.id
                    } label: {
                        if controller.selectedLanguageCode == option.id {
                            Text("✓ \(option.title)")
                        } else {
                            Text(option.title)
                        }
                    }
                }
            }

            Button("Quit LemonWhisper") {
                NSApplication.shared.terminate(nil)
            }
        } label: {
            Label(
                controller.isRecording ? "LemonWhisper Recording" : "LemonWhisper",
                systemImage: controller.isRecording ? "waveform.circle.fill" : "mic.circle.fill"
            )
        }
    }
}
