import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct TranscriptionHistoryView: View {
    @ObservedObject var store: TranscriptionHistoryStore
    @State private var exportErrorMessage: String?

    var body: some View {
        ZStack {
            LemonChrome.windowBackground
                .ignoresSafeArea()

            VStack(spacing: 0) {
                historyHeader
                    .padding(.horizontal, 18)
                    .padding(.top, 18)
                    .padding(.bottom, 12)

                Group {
                    if store.isLoadingInitialPage && store.items.isEmpty {
                        ProgressView("Loading transcriptions…")
                            .lemonNeutralProgressTint()
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    } else if store.items.isEmpty {
                        ContentUnavailableView(
                            "No transcriptions yet",
                            systemImage: "text.bubble",
                            description: Text(store.lastError ?? "Saved transcriptions will appear here after you stop a recording.")
                        )
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 14) {
                                ForEach(store.items) { item in
                                    TranscriptionHistoryCard(
                                        item: item,
                                        onCopy: { store.copyToClipboard(item) },
                                        onDelete: { store.delete(item) }
                                    )
                                    .task(id: item.id) {
                                        await store.loadMoreIfNeeded(currentItem: item)
                                    }
                                }

                                if store.isLoadingMorePages {
                                    ProgressView("Loading older transcriptions…")
                                        .lemonNeutralProgressTint()
                                        .frame(maxWidth: .infinity, alignment: .center)
                                        .padding(.top, 4)
                                } else if store.hasMoreItems {
                                    Text("Scroll down to load older transcriptions")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .center)
                                        .padding(.top, 4)
                                }
                            }
                            .padding(.horizontal, 18)
                            .padding(.bottom, 18)
                        }
                    }
                }
            }
        }
        .task {
            store.ensureLoaded()
        }
        .alert("Export failed", isPresented: Binding(
            get: { exportErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    exportErrorMessage = nil
                }
            }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportErrorMessage ?? "")
        }
    }

    private var historyHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(historySummary)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            ForEach(TranscriptionExportFormat.allCases, id: \.self) { format in
                Button(format.buttonTitle) {
                    export(format)
                }
                .buttonStyle(NeutralActionButtonStyle())
            }
        }
    }

    private var historySummary: String {
        if store.items.isEmpty {
            return "Newest first"
        }
        return store.hasMoreItems ? "\(store.items.count)+ loaded" : "\(store.items.count) loaded"
    }

    private func export(_ format: TranscriptionExportFormat) {
        Task {
            do {
                let data = try await store.exportAll(as: format)
                try await saveExportData(data, as: format)
            } catch {
                await MainActor.run {
                    exportErrorMessage = error.localizedDescription
                }
            }
        }
    }

    @MainActor
    private func saveExportData(_ data: Data, as format: TranscriptionExportFormat) throws {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = suggestedExportFilename(for: format)
        panel.title = format.buttonTitle
        panel.allowedContentTypes = [contentType(for: format)]

        guard panel.runModal() == .OK, let destinationURL = panel.url else {
            return
        }

        try data.write(to: destinationURL, options: .atomic)
    }

    private func suggestedExportFilename(for format: TranscriptionExportFormat) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "lemon-transcriptions-\(formatter.string(from: Date())).\(format.fileExtension)"
    }

    private func contentType(for format: TranscriptionExportFormat) -> UTType {
        switch format {
        case .csv:
            return .commaSeparatedText
        case .json:
            return .json
        }
    }
}

private struct TranscriptionHistoryCard: View {
    let item: TranscriptionRecord
    let onCopy: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.timestampLabel)
                        .font(.headline)
                        .foregroundStyle(.primary)
                }

                Spacer()

                HStack(spacing: 10) {
                    HistoryActionButton(
                        systemName: "doc.on.doc",
                        foreground: .primary,
                        accessibilityLabel: "Copy transcription",
                        action: onCopy
                    )

                    HistoryActionButton(
                        systemName: "trash",
                        foreground: .secondary,
                        accessibilityLabel: "Delete transcription",
                        action: onDelete
                    )
                }
            }

            Text(item.displayText)
                .font(.body)
                .foregroundStyle(.primary)
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .lemonSurface(cornerRadius: 20, showsBorder: true, showsShadow: true)
    }
}

private struct HistoryActionButton: View {
    let systemName: String
    let foreground: Color
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
        }
        .buttonStyle(NeutralIconButtonStyle(foreground: foreground))
        .accessibilityLabel(accessibilityLabel)
    }
}
