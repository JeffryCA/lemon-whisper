import SwiftUI

private enum ModelEngine: String {
    case whisper = "Whisper"
    case voxtral = "Voxtral"
}

private struct LocalModelItem: Identifiable, Hashable {
    let engine: ModelEngine
    let baseID: String
    let title: String
    let downloadSizeLabel: String
    let expectedPeakMemoryLabel: String
    let description: String

    var id: String { "\(engine.rawValue):\(baseID)" }

    var subtitle: String {
        "\(engine.rawValue) • Download \(downloadSizeLabel) • Peak \(expectedPeakMemoryLabel)"
    }
}

struct ContentView: View {
    @ObservedObject var controller: LemonWhisperController

    @State private var availableVoxtralModels: [VoxtralModelOption] = []
    @State private var selectedModelKey: String = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Form {
                    Section {
                        Picker("Language", selection: $controller.selectedLanguageCode) {
                            ForEach(controller.languageOptions) { option in
                                Text(option.title).tag(option.id)
                            }
                        }

                        Picker("Model", selection: $selectedModelKey) {
                            if downloadedModels.isEmpty {
                                Text("No downloaded models").tag("")
                            } else {
                                ForEach(downloadedModels) { model in
                                    Text(model.title).tag(model.id)
                                }
                            }
                        }
                        .disabled(downloadedModels.isEmpty)
                        .onChange(of: selectedModelKey) { _, newValue in
                            guard !newValue.isEmpty else { return }
                            applyModelSelection(key: newValue)
                        }

                        NavigationLink("Manage local models") {
                            ManageModelsView(
                                controller: controller,
                                availableVoxtralModels: availableVoxtralModels
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .formStyle(.grouped)
                .padding(.horizontal, 2)
                .padding(.vertical, 2)

                Divider()

                Text(statusLine)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
            }
            .navigationTitle("Lemon Whisper")
            .frame(minWidth: 420, idealWidth: 460, maxWidth: 520)
            .fixedSize(horizontal: false, vertical: true)
        }
        .task {
            await loadModels()
            syncSelectedModelKey()
        }
        .onChange(of: controller.selectedBackend) { _, _ in syncSelectedModelKey() }
        .onChange(of: controller.selectedWhisperModelID) { _, _ in syncSelectedModelKey() }
        .onChange(of: controller.selectedVoxtralModelID) { _, _ in syncSelectedModelKey() }
        .onChange(of: controller.downloadedWhisperModels.map(\.id)) { _, _ in syncSelectedModelKey() }
        .onChange(of: controller.downloadedVoxtralModels.map(\.id)) { _, _ in syncSelectedModelKey() }
    }

    private var downloadedModels: [LocalModelItem] {
        let whisper = controller.downloadedWhisperModels.map { model in
            LocalModelItem(
                engine: .whisper,
                baseID: model.id,
                title: model.title,
                downloadSizeLabel: model.downloadSizeLabel,
                expectedPeakMemoryLabel: model.expectedPeakMemoryLabel,
                description: model.family
            )
        }

        let voxtral = controller.downloadedVoxtralModels.map { model in
            LocalModelItem(
                engine: .voxtral,
                baseID: model.id,
                title: model.title,
                downloadSizeLabel: model.downloadSizeLabel,
                expectedPeakMemoryLabel: model.expectedPeakMemoryLabel,
                description: model.description
            )
        }

        return (whisper + voxtral).sorted(by: { $0.title < $1.title })
    }

    private var statusLine: String {
        "Process memory: \(controller.processMemoryMB) MB"
    }

    private func loadModels() async {
        availableVoxtralModels = await controller.voxtralCatalog
    }

    private func syncSelectedModelKey() {
        if let current = currentSelectedDownloadedModelKey() {
            selectedModelKey = current
            return
        }
        if let fallback = downloadedModels.first {
            selectedModelKey = fallback.id
            applyModelSelection(key: fallback.id)
            return
        }
        selectedModelKey = ""
    }

    private func currentSelectedDownloadedModelKey() -> String? {
        switch controller.selectedBackend {
        case .whisper:
            let key = "\(ModelEngine.whisper.rawValue):\(controller.selectedWhisperModelID)"
            return downloadedModels.contains(where: { $0.id == key }) ? key : nil
        case .voxtral:
            let key = "\(ModelEngine.voxtral.rawValue):\(controller.selectedVoxtralModelID)"
            return downloadedModels.contains(where: { $0.id == key }) ? key : nil
        }
    }

    private func applyModelSelection(key: String) {
        guard let model = downloadedModels.first(where: { $0.id == key }) else { return }
        switch model.engine {
        case .whisper:
            controller.selectDownloadedWhisperModelAndActivate(model.baseID)
        case .voxtral:
            controller.selectDownloadedVoxtralModelAndActivate(model.baseID)
        }
    }
}

private struct ManageModelsView: View {
    @ObservedObject var controller: LemonWhisperController
    let availableVoxtralModels: [VoxtralModelOption]

    private var downloadedModels: [LocalModelItem] {
        let whisper = controller.downloadedWhisperModels.map { model in
            LocalModelItem(
                engine: .whisper,
                baseID: model.id,
                title: model.title,
                downloadSizeLabel: model.downloadSizeLabel,
                expectedPeakMemoryLabel: model.expectedPeakMemoryLabel,
                description: model.family
            )
        }

        let voxtral = controller.downloadedVoxtralModels.map { model in
            LocalModelItem(
                engine: .voxtral,
                baseID: model.id,
                title: model.title,
                downloadSizeLabel: model.downloadSizeLabel,
                expectedPeakMemoryLabel: model.expectedPeakMemoryLabel,
                description: model.description
            )
        }

        return (whisper + voxtral).sorted(by: { $0.title < $1.title })
    }

    private var availableModels: [LocalModelItem] {
        let whisper = controller.whisperCatalog.map { model in
            LocalModelItem(
                engine: .whisper,
                baseID: model.id,
                title: model.title,
                downloadSizeLabel: model.downloadSizeLabel,
                expectedPeakMemoryLabel: model.expectedPeakMemoryLabel,
                description: model.family
            )
        }

        let voxtral = availableVoxtralModels.map { model in
            LocalModelItem(
                engine: .voxtral,
                baseID: model.id,
                title: model.title,
                downloadSizeLabel: model.downloadSizeLabel,
                expectedPeakMemoryLabel: model.expectedPeakMemoryLabel,
                description: model.description
            )
        }

        let all = (whisper + voxtral).sorted(by: { $0.title < $1.title })
        return all.filter { !isDownloaded($0) }
    }

    var body: some View {
        List {
            Section("Downloaded Models") {
                if downloadedModels.isEmpty {
                    Text("No local models yet")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(downloadedModels) { model in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.title)
                                Text(model.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                remove(model)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }

            Section("Available Downloads") {
                if availableModels.isEmpty {
                    Text("All listed models are already downloaded")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(availableModels) { model in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(model.title)
                                    Text(model.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(model.description)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(isBusy(model) ? "Downloading..." : "Download") {
                                    download(model)
                                }
                                .disabled(isBusy(model))
                            }

                            if let progress = downloadProgress(for: model), isBusy(model) {
                                HStack(spacing: 8) {
                                    ProgressView(value: progress)
                                        .progressViewStyle(.linear)
                                    Text("\(Int(progress * 100))%")
                                        .font(.caption2)
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Manage Local Models")
    }

    private func isDownloaded(_ model: LocalModelItem) -> Bool {
        switch model.engine {
        case .whisper:
            controller.isWhisperModelDownloaded(model.baseID)
        case .voxtral:
            controller.isVoxtralModelDownloaded(model.baseID)
        }
    }

    private func download(_ model: LocalModelItem) {
        switch model.engine {
        case .whisper:
            controller.downloadWhisperModel(model.baseID)
        case .voxtral:
            controller.downloadVoxtralModel(model.baseID)
        }
    }

    private func remove(_ model: LocalModelItem) {
        switch model.engine {
        case .whisper:
            controller.removeWhisperModel(model.baseID)
        case .voxtral:
            controller.removeVoxtralModel(model.baseID)
        }
    }

    private func isBusy(_ model: LocalModelItem) -> Bool {
        switch model.engine {
        case .whisper:
            controller.isWhisperBusy(model.baseID)
        case .voxtral:
            controller.isVoxtralBusy(model.baseID)
        }
    }

    private func downloadProgress(for model: LocalModelItem) -> Double? {
        switch model.engine {
        case .whisper:
            controller.whisperProgress(model.baseID)
        case .voxtral:
            controller.voxtralProgress(model.baseID)
        }
    }
}
