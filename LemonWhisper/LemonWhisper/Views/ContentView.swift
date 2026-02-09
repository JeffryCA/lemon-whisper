import SwiftUI

struct ContentView: View {
    @ObservedObject var controller: LemonWhisperController

    var body: some View {
        NavigationStack {
            List {
                Section("Whisper Models") {
                    ForEach(controller.whisperCatalog) { model in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(model.title)
                                    .font(.body)
                                Text(model.sizeLabel)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if controller.isWhisperModelDownloaded(model.id) {
                                Button(controller.selectedWhisperModelID == model.id ? "Selected" : "Select") {
                                    controller.selectWhisperModel(model.id)
                                }
                                .disabled(controller.selectedWhisperModelID == model.id)

                                Button("Remove", role: .destructive) {
                                    controller.removeWhisperModel(model.id)
                                }
                                .disabled(controller.isWhisperBusy(model.id))
                            } else {
                                Button("Download") {
                                    controller.downloadWhisperModel(model.id)
                                }
                                .disabled(controller.isWhisperBusy(model.id))
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section("Voxtral Models") {
                    VoxtralModelsSection(controller: controller)
                }
            }
            .navigationTitle("Open Lemon")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button(controller.isRecording ? "Stop" : "Record") {
                        controller.toggleRecording()
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Status")
                    .font(.headline)
                Text(controller.whisperStatus ?? "Whisper idle")
                    .foregroundStyle(.secondary)
                Text(controller.voxtralStatus ?? "Voxtral idle")
                    .foregroundStyle(.secondary)
                Text("Process memory: \(controller.processMemoryMB) MB")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding()
            .frame(minWidth: 220)
        }
    }
}

private struct VoxtralModelsSection: View {
    @ObservedObject var controller: LemonWhisperController
    @State private var availableModels: [VoxtralModelOption] = []

    var body: some View {
        Group {
            if availableModels.isEmpty {
                Text("Loading Voxtral catalog...")
                    .foregroundStyle(.secondary)
                    .task {
                        await loadModels()
                    }
            } else {
                ForEach(availableModels) { model in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.title)
                                .font(.body)
                            Text(model.sizeLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(model.description)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if controller.isVoxtralModelDownloaded(model.id) {
                            Button(controller.selectedVoxtralModelID == model.id ? "Selected" : "Select") {
                                Task { @MainActor in
                                    await controller.selectVoxtralModel(model.id)
                                }
                            }
                            .disabled(controller.selectedVoxtralModelID == model.id)

                            Button("Remove", role: .destructive) {
                                controller.removeVoxtralModel(model.id)
                            }
                            .disabled(controller.isVoxtralBusy(model.id))
                        } else {
                            Button("Download") {
                                controller.downloadVoxtralModel(model.id)
                            }
                            .disabled(controller.isVoxtralBusy(model.id))
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .task {
            await loadModels()
        }
    }

    private func loadModels() async {
        availableModels = await controller.voxtralCatalog
    }
}
