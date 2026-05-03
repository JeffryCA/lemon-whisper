import SwiftUI

struct ManageModelsView: View {
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

        let allModels = controller.supportsVoxtral ? (whisper + voxtral) : whisper
        return allModels.sorted(by: { $0.title < $1.title })
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

        let all = (controller.supportsVoxtral ? (whisper + voxtral) : whisper)
            .sorted(by: { $0.title < $1.title })
        return all.filter { !isDownloaded($0) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ModelSectionCard(title: "Downloaded Models") {
                    if downloadedModels.isEmpty {
                        EmptySectionText("No local models yet. Download one model below to use the app.")
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
                                isBusy: isBusy(model),
                                showsInlineProgress: true
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
        .lemonWindowBackground()
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
        .lemonSurface(showsBorder: true, showsShadow: true)
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
            .buttonStyle(NeutralIconButtonStyle(foreground: .secondary))
            .accessibilityLabel("Remove model")
        }
        .padding(.vertical, 10)
    }
}

private struct AvailableModelRow: View {
    let model: LocalModelItem
    let progress: Double?
    let isBusy: Bool
    let showsInlineProgress: Bool
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
                    .buttonStyle(NeutralActionButtonStyle())
                    .disabled(isBusy)
            }

            if showsInlineProgress, let progress, isBusy {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .lemonNeutralProgressTint()
            } else if showsInlineProgress, isBusy {
                ProgressView()
                    .progressViewStyle(.linear)
                    .lemonNeutralProgressTint()
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
