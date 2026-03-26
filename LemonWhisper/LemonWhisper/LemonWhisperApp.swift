import SwiftUI

@MainActor
@main
struct LemonWhisperApp: App {
    private let controller: LemonWhisperController
    private let historyStore: TranscriptionHistoryStore
    private let navigationState: AppNavigationState
    private let windowController: AppWindowController

    init() {
        let launchArguments = Set(CommandLine.arguments)
        let controller = LemonWhisperController(launchArguments: launchArguments)
        let historyStore = TranscriptionHistoryStore.shared
        let navigationState = AppNavigationState()
        let windowController = AppWindowController.shared

        self.controller = controller
        self.historyStore = historyStore
        self.navigationState = navigationState
        self.windowController = windowController

        historyStore.ensureLoaded()

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
        } else if launchArguments.contains("--codex-preview-initial-setup") {
            DispatchQueue.main.async {
                navigationState.goHome()
                windowController.show(
                    controller: controller,
                    historyStore: historyStore,
                    navigationState: navigationState
                )
            }
        } else {
            Task { @MainActor in
                let hasNoWhisperModels = WhisperModelCatalog.downloadedModels().isEmpty
                let hasNoVoxtralModels = await VoxtralService.shared.downloadedModels().isEmpty
                let shouldShowInitialSetup = hasNoWhisperModels && hasNoVoxtralModels
                guard shouldShowInitialSetup else { return }

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
