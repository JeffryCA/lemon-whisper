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
    @ObservedObject var historyStore: TranscriptionHistoryStore
    @ObservedObject var navigationState: AppNavigationState

    @State private var availableVoxtralModels: [VoxtralModelOption] = []
    @State private var selectedModelKey: String = ""

    var body: some View {
        VStack(spacing: 0) {
            currentContent

            Divider()

            Text(statusLine)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(
            minWidth: minimumContentWidth,
            idealWidth: idealContentWidth
        )
        .fixedSize(horizontal: false, vertical: navigationState.currentRoute == nil)
        .task {
            await loadModels()
            syncSelectedModelKey()
        }
        .onChange(of: controller.selectedBackend) { _, _ in syncSelectedModelKey() }
        .onChange(of: controller.selectedWhisperModelID) { _, _ in syncSelectedModelKey() }
        .onChange(of: controller.selectedVoxtralModelID) { _, _ in syncSelectedModelKey() }
        .onChange(of: controller.downloadedWhisperModels.map(\.id)) { _, _ in syncSelectedModelKey() }
        .onChange(of: controller.downloadedVoxtralModels.map(\.id)) { _, _ in syncSelectedModelKey() }
        .onChange(of: navigationState.currentRoute) { _, newRoute in
            AppWindowController.shared.updateWindowSize(for: newRoute)
        }
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

    @ViewBuilder
    private var currentContent: some View {
        switch navigationState.currentRoute {
        case .manageModels:
            DetailContainer(
                title: "Manage Local Models",
                onBack: navigationState.goHome
            ) {
                ManageModelsView(
                    controller: controller,
                    availableVoxtralModels: availableVoxtralModels
                )
            }
        case .transcriptions:
            DetailContainer(
                title: "Transcriptions",
                onBack: navigationState.goHome
            ) {
                TranscriptionHistoryView(store: historyStore)
            }
        case .none:
            homeContent
        }
    }

    private var homeContent: some View {
        VStack(spacing: 0) {
            HomeSettingsCard {
                HomeValueRow(title: "Language") {
                    Picker("", selection: $controller.selectedLanguageCode) {
                        ForEach(controller.languageOptions) { option in
                            Text(option.title).tag(option.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220, alignment: .trailing)
                }

                Divider()

                HomeValueRow(title: "Model") {
                    Picker("", selection: $selectedModelKey) {
                        if downloadedModels.isEmpty {
                            Text("No downloaded models").tag("")
                        } else {
                            ForEach(downloadedModels) { model in
                                Text(model.title).tag(model.id)
                            }
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220, alignment: .trailing)
                    .disabled(downloadedModels.isEmpty)
                    .onChange(of: selectedModelKey) { _, newValue in
                        guard !newValue.isEmpty else { return }
                        applyModelSelection(key: newValue)
                    }
                }

                Divider()

                Button {
                    navigationState.show(.manageModels)
                } label: {
                    HomeNavigationRow(
                        title: "Manage local models",
                        subtitle: modelStatusSummary
                    )
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
                .buttonStyle(.plain)

                Divider()

                Button {
                    navigationState.show(.transcriptions)
                } label: {
                    HomeNavigationRow(
                        title: "Transcriptions",
                        subtitle: transcriptionSummary
                    )
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var transcriptionSummary: String {
        if historyStore.items.isEmpty {
            return "No saved transcriptions yet"
        }
        return "\(historyStore.items.count) saved"
    }

    private var modelStatusSummary: String {
        let count = downloadedModels.count
        return count == 0 ? "No local models yet" : "\(count) downloaded"
    }

    private var minimumContentWidth: CGFloat {
        switch navigationState.currentRoute {
        case .manageModels:
            return 640
        case .transcriptions:
            return 720
        case .none:
            return 480
        }
    }

    private var idealContentWidth: CGFloat {
        switch navigationState.currentRoute {
        case .manageModels:
            return 720
        case .transcriptions:
            return 760
        case .none:
            return 520
        }
    }
}

private struct DetailContainer<Content: View>: View {
    let title: String
    let subtitle: String?
    let onBack: () -> Void
    let content: Content

    init(title: String, subtitle: String? = nil, onBack: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.onBack = onBack
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Button {
                    onBack()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                    if let subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 16)

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct HomeNavigationRow: View {
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct HomeSettingsCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}

private struct HomeValueRow<Accessory: View>: View {
    let title: String
    let accessory: Accessory

    init(title: String, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Text(title)
                .foregroundStyle(.primary)

            Spacer(minLength: 12)

            accessory
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
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
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ModelSectionCard(title: "Downloaded Models") {
                    if downloadedModels.isEmpty {
                        EmptySectionText("No local models yet")
                    } else {
                        ForEach(downloadedModels) { model in
                            DownloadedModelRow(model: model) {
                                remove(model)
                            }

                            if model.id != downloadedModels.last?.id {
                                Divider()
                            }
                        }
                    }
                }

                ModelSectionCard(title: "Available Downloads") {
                    if availableModels.isEmpty {
                        EmptySectionText("All listed models are already downloaded")
                    } else {
                        ForEach(availableModels) { model in
                            AvailableModelRow(
                                model: model,
                                progress: downloadProgress(for: model),
                                isBusy: isBusy(model)
                            ) {
                                download(model)
                            }

                            if model.id != availableModels.last?.id {
                                Divider()
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
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

private struct ModelSectionCard<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

            VStack(spacing: 0) {
                content
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}

private struct DownloadedModelRow: View {
    let model: LocalModelItem
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.title)
                    .foregroundStyle(.primary)

                Text(model.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(role: .destructive, action: onRemove) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 10)
    }
}

private struct AvailableModelRow: View {
    let model: LocalModelItem
    let progress: Double?
    let isBusy: Bool
    let onDownload: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.title)
                        .foregroundStyle(.primary)

                    Text(model.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(model.description)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                Button(isBusy ? "Downloading..." : "Download", action: onDownload)
                    .disabled(isBusy)
            }

            if let progress, isBusy {
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
        .padding(.vertical, 10)
    }
}

private struct EmptySectionText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
    }
}
