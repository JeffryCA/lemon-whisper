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
    @Published var whisperDownloadProgress: [String: Double] = [:]
    @Published var voxtralDownloadProgress: [String: Double] = [:]

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
        logMicrophonePermissionState()
        requestAccessibilityPermission()
        setupHotKeys()
        setupHotKeyObservers()
        startStatusPolling()

        Task { @MainActor in
            WhisperModelCatalog.cleanupInterruptedDownloads()
            await VoxtralService.shared.cleanupInterruptedDownloads()
            await initializeModelsAndBackend()
        }
    }

    func toggleRecording() {
        if isRecording {
            recorder.stopRecording()
            RecordingPulseHUD.shared.showPulse(isRecording: false)
            transcribeLatestRecording()
            isRecording = false
            return
        }

        startRecordingIfPermitted()
    }

    private func startRecordingIfPermitted() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            capturePasteTargetApp()
            recorder.startRecording()
            RecordingPulseHUD.shared.showPulse(isRecording: true)
            isRecording = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                guard let self else { return }
                DispatchQueue.main.async {
                    if granted {
                        print("✅ Microphone permission granted")
                        self.capturePasteTargetApp()
                        self.recorder.startRecording()
                        RecordingPulseHUD.shared.showPulse(isRecording: true)
                        self.isRecording = true
                    } else {
                        print("❌ Microphone permission denied")
                    }
                }
            }
        case .denied, .restricted:
            print("❌ Microphone permission denied")
        @unknown default:
            print("⚠️ Unknown microphone permission status")
        }
    }

    private func transcribeLatestRecording() {
        guard let wavURL = recorder.latestWavURL else { return }
        TranscriptionManager.shared.transcribe(
            from: wavURL,
            language: selectedLanguageCode,
            backend: selectedBackend,
            targetBundleIdentifier: targetBundleIdentifier,
            targetProcessID: targetProcessID
        ) { isActive in
            if isActive {
                TranscriptionLoadingHUD.shared.show()
            } else {
                TranscriptionLoadingHUD.shared.hide()
            }
        }
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
        whisperDownloadProgress[id] = 0
        whisperStatus = "Downloading \(option.title)..."

        Task { @MainActor in
            defer {
                whisperOperationsInFlight.remove(id)
                whisperDownloadProgress[id] = nil
            }

            do {
                try await WhisperModelCatalog.downloadModel(option) { progress in
                    Task { @MainActor in
                        self.whisperDownloadProgress[id] = progress
                    }
                }
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
        voxtralDownloadProgress[id] = 0
        voxtralStatus = "Downloading Voxtral model..."

        Task { @MainActor in
            defer {
                voxtralOperationsInFlight.remove(id)
                voxtralDownloadProgress[id] = nil
            }

            do {
                try await VoxtralService.shared.downloadModel(id) { progress, status in
                    let pct = Int(progress * 100)
                    Task { @MainActor in
                        self.voxtralDownloadProgress[id] = progress
                        self.voxtralStatus = "[\(pct)%] \(status)"
                    }
                }
                voxtralStatus = "Voxtral model downloaded"
                await refreshVoxtralDownloads()
                if id == selectedVoxtralModelID {
                    _ = await prepareAndMaybeSwitchToVoxtral()
                }
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

    func whisperProgress(_ id: String) -> Double? {
        whisperDownloadProgress[id]
    }

    func voxtralProgress(_ id: String) -> Double? {
        voxtralDownloadProgress[id]
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

        if !downloadedVoxtralModels.contains(where: { $0.id == selectedVoxtralModelID }) {
            voxtralStatus = "Downloading Voxtral Mini 3B (4-bit mixed) by default..."
            downloadVoxtralModel(selectedVoxtralModelID)
            ensureWhisperFallbackIfNeeded()
            return
        }

        if await prepareAndMaybeSwitchToVoxtral() {
            return
        }

        ensureWhisperFallbackIfNeeded()
    }

    private func ensureWhisperFallbackIfNeeded() {
        if downloadedWhisperModels.isEmpty,
           let defaultOption = WhisperModelCatalog.option(for: WhisperModelCatalog.defaultModelID) {
            whisperStatus = "Downloading Whisper fallback model..."
            downloadWhisperModel(defaultOption.id)
            return
        }

        preloadWhisperIfNeeded()
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

    @discardableResult
    private func prepareAndMaybeSwitchToVoxtral() async -> Bool {
        if isPreparingVoxtral {
            return selectedBackend == .voxtral
        }

        guard downloadedVoxtralModels.contains(where: { $0.id == selectedVoxtralModelID }) else {
            voxtralStatus = "Voxtral Mini 3B (4-bit mixed) is still downloading."
            return false
        }

        if await VoxtralService.shared.isReady {
            selectedBackend = .voxtral
            UserDefaults.standard.set(TranscriptionBackend.voxtral.rawValue, forKey: "selectedTranscriptionBackend")
            print("✅ Voxtral is ready. Switched backend.")
            return true
        }

        isPreparingVoxtral = true
        print("⏳ Preparing Voxtral in background.")
        defer { isPreparingVoxtral = false }

        do {
            try await VoxtralService.shared.warmupModel()
            selectedBackend = .voxtral
            UserDefaults.standard.set(TranscriptionBackend.voxtral.rawValue, forKey: "selectedTranscriptionBackend")
            print("✅ Voxtral ready. Switched backend.")
            return true
        } catch {
            selectedBackend = .whisper
            UserDefaults.standard.set(TranscriptionBackend.whisper.rawValue, forKey: "selectedTranscriptionBackend")
            if let details = await VoxtralService.shared.latestError {
                print("❌ Voxtral preparation failed. Staying on Whisper: \(details)")
            } else {
                print("❌ Voxtral preparation failed. Staying on Whisper: \(error.localizedDescription)")
            }
            await VoxtralService.shared.unload()
            return false
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

    private func logMicrophonePermissionState() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            print("✅ Microphone permission granted")
        case .notDetermined:
            print("ℹ️ Microphone permission not determined yet")
        case .denied, .restricted:
            print("❌ Microphone permission denied")
        @unknown default:
            print("⚠️ Unknown microphone permission status")
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

        if let point = pointerPosition() {
            panel.setFrameOrigin(NSPoint(x: point.x - (dotSize / 2), y: point.y + 18))
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

    private func pointerPosition() -> NSPoint? {
        let point = NSEvent.mouseLocation
        return point.x.isFinite && point.y.isFinite ? point : nil
    }
}

@MainActor
final class TranscriptionLoadingHUD {
    static let shared = TranscriptionLoadingHUD()

    private var panel: NSPanel?
    private var spinner: NSProgressIndicator?
    private let size: CGFloat = 24

    private init() {}

    func show() {
        ensurePanel()
        guard let panel else { return }

        if let point = pointerPosition() {
            panel.setFrameOrigin(NSPoint(x: point.x - (size / 2), y: point.y + 18))
        }

        panel.alphaValue = 1
        panel.orderFrontRegardless()
        spinner?.startAnimation(nil)
    }

    func hide() {
        spinner?.stopAnimation(nil)
        panel?.orderOut(nil)
    }

    private func ensurePanel() {
        guard panel == nil else { return }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: size, height: size),
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

        let container = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        container.material = .hudWindow
        container.blendingMode = .withinWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = size / 2

        let spinner = NSProgressIndicator(frame: NSRect(x: 5, y: 5, width: size - 10, height: size - 10))
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.isDisplayedWhenStopped = false
        spinner.startAnimation(nil)
        container.addSubview(spinner)

        panel.contentView = container

        self.panel = panel
        self.spinner = spinner
    }

    private func pointerPosition() -> NSPoint? {
        let point = NSEvent.mouseLocation
        return point.x.isFinite && point.y.isFinite ? point : nil
    }
}

private struct MenuBarContentView: View {
    @ObservedObject var controller: LemonWhisperController
    @ObservedObject var historyStore: TranscriptionHistoryStore
    @ObservedObject var navigationState: AppNavigationState
    let windowController: AppWindowController

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

        Menu("Transcriptions") {
            Button("Open History") {
                navigationState.show(.transcriptions)
                windowController.show(
                    controller: controller,
                    historyStore: historyStore,
                    navigationState: navigationState
                )
            }

            Divider()

            if historyStore.items.isEmpty {
                Text("No saved transcriptions yet")
            } else {
                let recentItems = Array(historyStore.items.prefix(10))

                ForEach(recentItems) { item in
                    Button {
                        historyStore.copyToClipboard(item)
                    } label: {
                        Label(item.menuTitle, systemImage: "doc.on.doc")
                    }
                }

                if historyStore.items.count > recentItems.count {
                    Divider()
                    Text("\(historyStore.items.count - recentItems.count) more in History")
                }
            }
        }

        Divider()
        Text("Process memory: \(controller.processMemoryMB) MB")
            .font(.caption2)

        Button("Open Lemon") {
            navigationState.goHome()
            windowController.show(
                controller: controller,
                historyStore: historyStore,
                navigationState: navigationState
            )
        }

        Button("Quit LemonWhisper") {
            NSApplication.shared.terminate(nil)
        }
    }
}

@MainActor
@main
struct LemonWhisperApp: App {
    private let controller: LemonWhisperController
    private let historyStore: TranscriptionHistoryStore
    private let navigationState: AppNavigationState
    private let windowController: AppWindowController

    init() {
        let controller = LemonWhisperController()
        let historyStore = TranscriptionHistoryStore.shared
        let navigationState = AppNavigationState()
        let windowController = AppWindowController.shared

        self.controller = controller
        self.historyStore = historyStore
        self.navigationState = navigationState
        self.windowController = windowController

        historyStore.ensureLoaded()

        let launchArguments = Set(CommandLine.arguments)
        if launchArguments.contains("--codex-open-transcriptions") {
            DispatchQueue.main.async {
                navigationState.show(.transcriptions)
                windowController.show(
                    controller: controller,
                    historyStore: historyStore,
                    navigationState: navigationState
                )
            }
        } else if launchArguments.contains("--codex-open-manage-models") {
            DispatchQueue.main.async {
                navigationState.show(.manageModels)
                windowController.show(
                    controller: controller,
                    historyStore: historyStore,
                    navigationState: navigationState
                )
            }
        } else if launchArguments.contains("--codex-open-main-window") {
            DispatchQueue.main.async {
                navigationState.goHome()
                windowController.show(
                    controller: controller,
                    historyStore: historyStore,
                    navigationState: navigationState
                )
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(
                controller: controller,
                historyStore: historyStore,
                navigationState: navigationState,
                windowController: windowController
            )
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
