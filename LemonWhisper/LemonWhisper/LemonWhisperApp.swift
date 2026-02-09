import SwiftUI
import AVFoundation
import ApplicationServices
import Carbon
import AppKit
import Darwin

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
    @Published var selectedBackend: TranscriptionBackend = .whisper
    @Published var isPreparingVoxtral = false
    @Published var processMemoryMB: Int = 0

    @Published var selectedWhisperModelID: String = WhisperModelCatalog.selectedModelID()
    @Published var selectedVoxtralModelID: String = ""
    @Published var downloadedWhisperModels: [WhisperModelOption] = []
    @Published var downloadedVoxtralModels: [VoxtralModelOption] = []

    @Published var whisperStatus: String?
    @Published var voxtralStatus: String?

    private var whisperOperationsInFlight: Set<String> = []
    private var voxtralOperationsInFlight: Set<String> = []

    private let recorder = AudioRecorder()
    private var targetBundleIdentifier: String?
    private var targetProcessID: pid_t?
    private var toggleHotKeyRef: EventHotKeyRef?
    private var statusTimer: Timer?

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

    var whisperCatalog: [WhisperModelOption] {
        WhisperModelCatalog.models
    }

    var voxtralCatalog: [VoxtralModelOption] {
        get async {
            await VoxtralService.shared.availableModels()
        }
    }

    init() {
        if let storedBackend = UserDefaults.standard.string(forKey: "selectedTranscriptionBackend"),
           let backend = TranscriptionBackend(rawValue: storedBackend) {
            selectedBackend = backend
        }

        requestMicrophonePermission()
        requestAccessibilityPermission()
        setupHotKeys()
        setupHotKeyObservers()
        startStatusPolling()

        Task { @MainActor in
            await initializeModelsAndBackend()
        }
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
            backend: selectedBackend,
            targetBundleIdentifier: targetBundleIdentifier,
            targetProcessID: targetProcessID
        )
    }

    func setBackend(_ backend: TranscriptionBackend) {
        switch backend {
        case .whisper:
            selectedBackend = .whisper
            UserDefaults.standard.set(TranscriptionBackend.whisper.rawValue, forKey: "selectedTranscriptionBackend")
            Task {
                await VoxtralService.shared.unload()
            }
            preloadWhisperIfNeeded()
        case .voxtral:
            Task { @MainActor in
                await prepareAndMaybeSwitchToVoxtral()
            }
        }
    }

    func selectDownloadedWhisperModelAndActivate(_ id: String) {
        selectWhisperModel(id)
        setBackend(.whisper)
    }

    func selectDownloadedVoxtralModelAndActivate(_ id: String) {
        Task { @MainActor in
            await selectVoxtralModel(id)
            setBackend(.voxtral)
        }
    }

    func selectWhisperModel(_ id: String) {
        guard WhisperModelCatalog.option(for: id) != nil else { return }
        selectedWhisperModelID = id
        WhisperModelCatalog.setSelectedModelID(id)
        WhisperContext.clearShared()
    }

    func selectVoxtralModel(_ id: String) async {
        await VoxtralService.shared.setSelectedModel(id)
        selectedVoxtralModelID = await VoxtralService.shared.currentSelectedModelID()
    }

    func downloadWhisperModel(_ id: String) {
        guard !whisperOperationsInFlight.contains(id),
              let option = WhisperModelCatalog.option(for: id) else {
            return
        }

        whisperOperationsInFlight.insert(id)
        whisperStatus = "Downloading \(option.title)..."

        Task { @MainActor in
            defer {
                whisperOperationsInFlight.remove(id)
            }

            do {
                try await WhisperModelCatalog.downloadModel(option)
                whisperStatus = "Downloaded \(option.title)"
                refreshWhisperDownloads()
                if selectedWhisperModelID == id {
                    WhisperContext.clearShared()
                }
            } catch {
                whisperStatus = "Whisper download failed: \(error.localizedDescription)"
            }
        }
    }

    func removeWhisperModel(_ id: String) {
        guard !whisperOperationsInFlight.contains(id),
              let option = WhisperModelCatalog.option(for: id) else {
            return
        }

        whisperOperationsInFlight.insert(id)
        defer { whisperOperationsInFlight.remove(id) }

        do {
            try WhisperModelCatalog.removeModel(option)
            whisperStatus = "Removed \(option.title)"
            refreshWhisperDownloads()

            if selectedWhisperModelID == id {
                if let fallback = downloadedWhisperModels.first {
                    selectWhisperModel(fallback.id)
                }
                WhisperContext.clearShared()
            }
        } catch {
            whisperStatus = "Could not remove \(option.title): \(error.localizedDescription)"
        }
    }

    func downloadVoxtralModel(_ id: String) {
        guard !voxtralOperationsInFlight.contains(id) else { return }
        voxtralOperationsInFlight.insert(id)
        voxtralStatus = "Downloading Voxtral model..."

        Task { @MainActor in
            defer {
                voxtralOperationsInFlight.remove(id)
            }

            do {
                try await VoxtralService.shared.downloadModel(id) { progress, status in
                    let pct = Int(progress * 100)
                    Task { @MainActor in
                        self.voxtralStatus = "[\(pct)%] \(status)"
                    }
                }
                voxtralStatus = "Voxtral model downloaded"
                await refreshVoxtralDownloads()
            } catch {
                voxtralStatus = "Voxtral download failed: \(error.localizedDescription)"
            }
        }
    }

    func removeVoxtralModel(_ id: String) {
        guard !voxtralOperationsInFlight.contains(id) else { return }
        voxtralOperationsInFlight.insert(id)
        defer { voxtralOperationsInFlight.remove(id) }

        Task { @MainActor in
            do {
                try await VoxtralService.shared.removeModel(id)
                voxtralStatus = "Voxtral model removed"
                await refreshVoxtralDownloads()

                if selectedVoxtralModelID == id {
                    if let fallback = downloadedVoxtralModels.first {
                        await selectVoxtralModel(fallback.id)
                    }
                }
            } catch {
                voxtralStatus = "Could not remove Voxtral model: \(error.localizedDescription)"
            }
        }
    }

    func isWhisperModelDownloaded(_ id: String) -> Bool {
        downloadedWhisperModels.contains(where: { $0.id == id })
    }

    func isVoxtralModelDownloaded(_ id: String) -> Bool {
        downloadedVoxtralModels.contains(where: { $0.id == id })
    }

    func isWhisperBusy(_ id: String) -> Bool {
        whisperOperationsInFlight.contains(id)
    }

    func isVoxtralBusy(_ id: String) -> Bool {
        voxtralOperationsInFlight.contains(id)
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

    private func initializeModelsAndBackend() async {
        selectedWhisperModelID = WhisperModelCatalog.selectedModelID()
        selectedVoxtralModelID = await VoxtralService.shared.currentSelectedModelID()

        refreshWhisperDownloads()
        await refreshVoxtralDownloads()

        if downloadedWhisperModels.isEmpty,
           let defaultOption = WhisperModelCatalog.option(for: WhisperModelCatalog.defaultModelID) {
            whisperStatus = "No Whisper model found locally. Downloading default model..."
            downloadWhisperModel(defaultOption.id)
        }

        switch selectedBackend {
        case .whisper:
            preloadWhisperIfNeeded()
        case .voxtral:
            await prepareAndMaybeSwitchToVoxtral()
        }
    }

    private func refreshWhisperDownloads() {
        downloadedWhisperModels = WhisperModelCatalog.downloadedModels()

        if !downloadedWhisperModels.contains(where: { $0.id == selectedWhisperModelID }),
           let fallback = downloadedWhisperModels.first {
            selectWhisperModel(fallback.id)
        }
    }

    private func refreshVoxtralDownloads() async {
        downloadedVoxtralModels = await VoxtralService.shared.downloadedModels()
        selectedVoxtralModelID = await VoxtralService.shared.currentSelectedModelID()
    }

    private func preloadWhisperIfNeeded() {
        Task {
            do {
                guard let selected = WhisperModelCatalog.selectedModelIfDownloaded() else {
                    print("❌ No downloaded Whisper model available")
                    return
                }

                _ = try await WhisperContext.createContext(path: selected.localURL.path)
                try await WhisperModelCatalog.ensureVADDownloadedIfNeeded()
                if let context = WhisperContext.getShared() {
                    await context.setVADModelPath(WhisperModelCatalog.vadLocalURL.path)
                }
                print("✅ Whisper model ready: \(selected.title)")
            } catch {
                print("❌ Failed to load Whisper model: \(error)")
            }
        }
    }

    private func prepareAndMaybeSwitchToVoxtral() async {
        if isPreparingVoxtral {
            return
        }

        guard downloadedVoxtralModels.contains(where: { $0.id == selectedVoxtralModelID }) else {
            selectedBackend = .whisper
            UserDefaults.standard.set(TranscriptionBackend.whisper.rawValue, forKey: "selectedTranscriptionBackend")
            voxtralStatus = "Selected Voxtral model is not downloaded. Staying on Whisper."
            return
        }

        if await VoxtralService.shared.isReady {
            selectedBackend = .voxtral
            UserDefaults.standard.set(TranscriptionBackend.voxtral.rawValue, forKey: "selectedTranscriptionBackend")
            print("✅ Voxtral is ready. Switched backend.")
            return
        }

        isPreparingVoxtral = true
        print("⏳ Preparing Voxtral in background. Staying on Whisper until ready.")
        defer { isPreparingVoxtral = false }

        do {
            try await VoxtralService.shared.warmupModel()
            selectedBackend = .voxtral
            UserDefaults.standard.set(TranscriptionBackend.voxtral.rawValue, forKey: "selectedTranscriptionBackend")
            print("✅ Voxtral ready. Switched backend.")
        } catch {
            selectedBackend = .whisper
            UserDefaults.standard.set(TranscriptionBackend.whisper.rawValue, forKey: "selectedTranscriptionBackend")
            if let details = await VoxtralService.shared.latestError {
                print("❌ Voxtral preparation failed. Staying on Whisper: \(details)")
            } else {
                print("❌ Voxtral preparation failed. Staying on Whisper: \(error.localizedDescription)")
            }
            await VoxtralService.shared.unload()
        }
    }

    var canSelectVoxtralNow: Bool {
        !isPreparingVoxtral
    }

    private func startStatusPolling() {
        refreshRuntimeStatus()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshRuntimeStatus()
            }
        }
    }

    private func refreshRuntimeStatus() {
        processMemoryMB = currentProcessMemoryMB()
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
        let keyCodeGermanY: UInt32 = UInt32(kVK_ANSI_Z)
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

private struct MenuBarContentView: View {
    @ObservedObject var controller: LemonWhisperController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
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

        Menu("Model") {
            Section("Downloaded Whisper") {
                if controller.downloadedWhisperModels.isEmpty {
                    Text("No Whisper models downloaded")
                } else {
                    ForEach(controller.downloadedWhisperModels) { option in
                        Button {
                            controller.selectDownloadedWhisperModelAndActivate(option.id)
                        } label: {
                            if controller.selectedBackend == .whisper && controller.selectedWhisperModelID == option.id {
                                Text("✓ \(option.title)")
                            } else {
                                Text(option.title)
                            }
                        }
                    }
                }
            }

            Section("Downloaded Voxtral") {
                if controller.downloadedVoxtralModels.isEmpty {
                    Text("No Voxtral models downloaded")
                } else {
                    ForEach(controller.downloadedVoxtralModels) { option in
                        Button {
                            controller.selectDownloadedVoxtralModelAndActivate(option.id)
                        } label: {
                            if controller.selectedBackend == .voxtral && controller.selectedVoxtralModelID == option.id {
                                Text("✓ \(option.title)")
                            } else {
                                Text(option.title)
                            }
                        }
                        .disabled(!controller.canSelectVoxtralNow)
                    }
                }
            }
        }

        Divider()
        Text("Process memory: \(controller.processMemoryMB) MB")
            .font(.caption2)

        Button("Open Lemon") {
            openWindow(id: "open-lemon")
            NSApp.activate(ignoringOtherApps: true)
        }

        Button("Quit LemonWhisper") {
            NSApplication.shared.terminate(nil)
        }
    }
}

@main
struct LemonWhisperApp: App {
    @StateObject private var controller = LemonWhisperController()

    var body: some Scene {
        Window("Open Lemon", id: "open-lemon") {
            ContentView(controller: controller)
        }
        .defaultSize(width: 760, height: 540)

        MenuBarExtra {
            MenuBarContentView(controller: controller)
        } label: {
            Image("MenuBarIcon")
                .renderingMode(.original)
        }
    }
}

private func currentProcessMemoryMB() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return 0 }
    return Int(info.phys_footprint / 1_048_576)
}
