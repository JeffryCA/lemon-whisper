import SwiftUI

struct MenuBarContentView: View {
    @ObservedObject var controller: LemonWhisperController
    @ObservedObject var historyStore: TranscriptionHistoryStore
    @ObservedObject var navigationState: AppNavigationState
    let windowController: AppWindowController

    var body: some View {
        Button(controller.recordingButtonTitle) {
            controller.toggleRecording()
        }
        .keyboardShortcut("y", modifiers: [.control])
        .disabled(!controller.isRecording && !controller.canStartNewRecording)

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
            if controller.supportsVoxtral {
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

            if historyStore.isLoadingInitialPage && historyStore.items.isEmpty {
                Text("Loading recent transcriptions…")
            } else if historyStore.items.isEmpty {
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

                if let footerText = historyStore.menuHistoryFooterText {
                    Divider()
                    Text(footerText)
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

        Button("Quit Lemon") {
            NSApplication.shared.terminate(nil)
        }
    }
}
