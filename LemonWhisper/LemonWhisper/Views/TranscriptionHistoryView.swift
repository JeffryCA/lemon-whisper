import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct TranscriptionHistoryView: View {
    @ObservedObject var store: TranscriptionHistoryStore

    var body: some View {
        ZStack {
            LemonChrome.windowBackground
                .ignoresSafeArea()

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

                            historyPaginationFooter
                        }
                        .padding(.horizontal, 18)
                        .padding(.top, 18)
                        .padding(.bottom, 18)
                    }
                }
            }
        }
        .task {
            store.ensureLoaded()
        }
    }

    @ViewBuilder
    private var historyPaginationFooter: some View {
        if store.isLoadingMorePages {
            ProgressView("Loading older transcriptions…")
                .lemonNeutralProgressTint()
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 4)
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

struct HistoryExportButton: View {
    @ObservedObject var store: TranscriptionHistoryStore
    @State private var exportErrorMessage: String?

    var body: some View {
        Button {
            exportCSV()
        } label: {
            Image(systemName: "square.and.arrow.down")
        }
        .buttonStyle(NeutralIconButtonStyle())
        .accessibilityLabel("Export transcriptions as CSV")
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

    private func exportCSV() {
        Task {
            do {
                let data = try await store.exportAllCSV()
                try saveCSV(data)
            } catch {
                await MainActor.run {
                    exportErrorMessage = error.localizedDescription
                }
            }
        }
    }

    @MainActor
    private func saveCSV(_ data: Data) throws {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = suggestedExportFilename
        panel.title = "Export CSV"
        panel.allowedContentTypes = [.commaSeparatedText]

        guard panel.runModal() == .OK, let destinationURL = panel.url else {
            return
        }

        try data.write(to: destinationURL, options: .atomic)
    }

    private var suggestedExportFilename: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "lemon-transcriptions-\(formatter.string(from: Date())).csv"
    }
}

