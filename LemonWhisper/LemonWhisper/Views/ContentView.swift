import SwiftUI

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
        .background(LemonChrome.windowBackground)
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

        let allModels = controller.supportsVoxtral ? (whisper + voxtral) : whisper
        return allModels.sorted(by: { $0.title < $1.title })
    }

    private var statusLine: String {
        controller.statusLineText
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
                onBack: navigationState.goHome,
                trailingContent: {
                    HistoryExportButton(store: historyStore)
                }
            ) {
                TranscriptionHistoryView(store: historyStore)
            }
        case .none:
            homeContent
        }
    }

    private var homeContent: some View {
        VStack(spacing: 0) {
            if controller.showsSetupCard {
                SetupStatusCard(
                    title: controller.setupCardTitle,
                    message: controller.setupCardMessage,
                    progress: controller.setupCardProgress,
                    showsProgress: controller.setupCardShowsProgress
                ) {
                    navigationState.show(.manageModels)
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 12)
            }

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
            .padding(.top, controller.showsSetupCard ? 0 : 20)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .background(LemonChrome.windowBackground)
    }

    private var transcriptionSummary: String {
        "Recent history"
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

private struct DetailContainer<Content: View, TrailingContent: View>: View {
    let title: String
    let subtitle: String?
    let onBack: () -> Void
    let trailingContent: TrailingContent
    let content: Content

    init(
        title: String,
        subtitle: String? = nil,
        onBack: @escaping () -> Void,
        @ViewBuilder trailingContent: () -> TrailingContent,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.onBack = onBack
        self.trailingContent = trailingContent()
        self.content = content()
    }

    init(title: String, subtitle: String? = nil, onBack: @escaping () -> Void, @ViewBuilder content: () -> Content)
    where TrailingContent == EmptyView {
        self.init(title: title, subtitle: subtitle, onBack: onBack, trailingContent: { EmptyView() }, content: content)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
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

                trailingContent
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 14)

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
        .lemonSurface()
    }
}

private struct SetupStatusCard: View {
    let title: String
    let message: String
    let progress: Double?
    let showsProgress: Bool
    let onManageModels: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.title3.weight(.semibold))

            Text(message)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if showsProgress {
                if let progress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .lemonNeutralProgressTint()
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .lemonNeutralProgressTint()
                }
            }

            if !showsProgress {
                Button("Download a model", action: onManageModels)
                    .buttonStyle(NeutralActionButtonStyle())
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lemonSurface()
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
