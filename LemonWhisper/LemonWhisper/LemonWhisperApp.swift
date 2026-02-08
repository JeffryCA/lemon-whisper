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
            RecordingPulseHUD.shared.showPulse(isRecording: false)
            transcribeLatestRecording()
        } else {
            capturePasteTargetApp()
            recorder.startRecording()
            RecordingPulseHUD.shared.showPulse(isRecording: true)
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
                let context = try await WhisperContext.createContext(path: modelPath)

                if let vadPath = Bundle.main.path(forResource: "ggml-silero-v5.1.2", ofType: "bin") {
                    await context.setVADModelPath(vadPath)
                    print("✅ VAD model enabled")
                } else {
                    print("⚠️ VAD model not found in bundle resources")
                }
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

@MainActor
final class RecordingPulseHUD {
    static let shared = RecordingPulseHUD()

    private var panel: NSPanel?
    private var dotView: NSView?
    private var hideWorkItem: DispatchWorkItem?
    private let dotSize: CGFloat = 22

    private init() {}

    func showPulse(isRecording: Bool) {
        ensurePanel()
        guard let panel, let dotView else { return }

        hideWorkItem?.cancel()
        let pulseColor = isRecording
            ? NSColor(calibratedWhite: 0.55, alpha: 0.95)
            : NSColor(calibratedWhite: 0.72, alpha: 0.95)
        dotView.layer?.backgroundColor = pulseColor.cgColor

        if let screen = activeScreen() {
            let x = screen.frame.midX - (dotSize / 2)
            let y = screen.frame.minY + (screen.frame.height * 0.75)
            panel.setFrame(NSRect(x: x, y: y, width: dotSize, height: dotSize), display: false)
        }

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.10
            panel.animator().alphaValue = 1
        }

        let hideItem = DispatchWorkItem { [weak self] in
            guard let self, let panel = self.panel else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.16
                panel.animator().alphaValue = 0
            }, completionHandler: {
                panel.orderOut(nil)
            })
        }
        hideWorkItem = hideItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: hideItem)
    }

    private func ensurePanel() {
        guard panel == nil else { return }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: dotSize, height: dotSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let dotView = NSView(frame: NSRect(x: 0, y: 0, width: dotSize, height: dotSize))
        dotView.wantsLayer = true
        dotView.layer?.cornerRadius = dotSize / 2
        dotView.layer?.backgroundColor = NSColor.systemGray.cgColor
        panel.contentView = dotView

        self.panel = panel
        self.dotView = dotView
    }

    private func activeScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) {
            return screen
        }
        return NSScreen.main ?? NSScreen.screens.first
    }
}

@main
struct LemonWhisperApp: App {
    @StateObject private var controller = LemonWhisperController()

    var body: some Scene {
        MenuBarExtra {
            Text(controller.isRecording ? "Status: Recording" : "Status: Idle")
                .font(.caption)
                .foregroundStyle(controller.isRecording ? .red : .secondary)

            Divider()

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
            Image("MenuBarIcon")
                .renderingMode(.original)
        }
    }
}
