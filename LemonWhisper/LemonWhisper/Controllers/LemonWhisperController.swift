import SwiftUI
import Carbon

@MainActor
final class LemonWhisperController: ObservableObject {
    @Published var isRecording = false
    @Published var selectedLanguageCode = "en"
    @Published var selectedBackend: TranscriptionBackend = .whisper
    @Published var isPreparingVoxtral = false
    @Published var setupState: SetupState = .bootstrapping
    @Published var processMemoryMB: Int = 0

    @Published var selectedWhisperModelID: String = WhisperModelCatalog.selectedModelID()
    @Published var selectedVoxtralModelID: String = ""
    @Published var downloadedWhisperModels: [WhisperModelOption] = []
    @Published var downloadedVoxtralModels: [VoxtralModelOption] = []

    @Published var whisperStatus: String?
    @Published var voxtralStatus: String?
    @Published var whisperDownloadProgress: [String: Double] = [:]
    @Published var voxtralDownloadProgress: [String: Double] = [:]

    @Published var selectedMicrophoneID: String? = AppSettingsStore.selectedMicrophoneUniqueID
    @Published var availableMicrophones: [MicrophoneDevice] = MicrophoneManager.availableDevices()
    @Published var recordingShortcut: RecordingShortcut = AppSettingsStore.recordingShortcut
    @Published var modelLoadingMode: ModelLoadingMode = AppSettingsStore.modelLoadingMode
    @Published var modelIdleTimeout: ModelIdleTimeout = AppSettingsStore.modelIdleTimeout

    var whisperOperationsInFlight: Set<String> = []
    var voxtralOperationsInFlight: Set<String> = []

    let recorder = AudioRecorder()
    var targetBundleIdentifier: String?
    var targetProcessID: pid_t?
    var recordingStartedAt: Date?
    var lastRecordingDuration: TimeInterval?
    var idleUnloadTimer: Timer?
    var toggleHotKeyRef: EventHotKeyRef?

    let selectedBackendDefaultsKey = "selectedTranscriptionBackend"
    let previewInitialSetup: Bool
    let permissionManager = PermissionManager()
    let statusPollingManager = StatusPollingManager()

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

    init(launchArguments: Set<String> = Set(CommandLine.arguments)) {
        self.previewInitialSetup = launchArguments.contains("--codex-preview-initial-setup")

        debugLog("🚀 LemonWhisper launch. bundle=\(Bundle.main.bundleIdentifier ?? "unknown") preview=\(previewInitialSetup)")
        permissionManager.logMicrophonePermissionState()
        permissionManager.requestAccessibilityPermission()
        permissionManager.requestMicrophonePermissionIfNeeded()
        setupHotKeys()
        setupHotKeyObservers()
        startStatusPolling()

        Task { @MainActor in
            if previewInitialSetup {
                selectedBackend = supportsVoxtral ? .voxtral : .whisper
                selectedVoxtralModelID = VoxtralService.defaultModelID
                voxtralStatus = "Previewing first-run setup."
                setupState = .awaitingModelSelection(supportsVoxtral: supportsVoxtral)
                return
            }

            WhisperModelCatalog.cleanupInterruptedDownloads()
            await VoxtralService.shared.cleanupInterruptedDownloads()
            await initializeModelsAndBackend()
        }
    }
}
