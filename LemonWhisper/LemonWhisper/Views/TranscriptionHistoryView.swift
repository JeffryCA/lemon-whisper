import SwiftUI

struct TranscriptionHistoryView: View {
    @ObservedObject var store: TranscriptionHistoryStore

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            Group {
                if store.items.isEmpty {
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
                            }
                        }
                        .padding(18)
                    }
                }
            }
        }
        .task {
            await store.loadRecent()
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

                    HStack(spacing: 8) {
                        HistoryPill(text: item.backendLabel)
                        HistoryPill(text: item.languageLabel)
                    }
                }

                Spacer()

                HStack(spacing: 10) {
                    HistoryActionButton(
                        systemName: "doc.on.doc",
                        foreground: .primary,
                        background: Color(nsColor: .windowBackgroundColor),
                        accessibilityLabel: "Copy transcription",
                        action: onCopy
                    )

                    HistoryActionButton(
                        systemName: "trash",
                        foreground: .secondary,
                        background: Color(nsColor: .windowBackgroundColor),
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
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.08), radius: 10, x: 0, y: 4)
        )
    }
}

private struct HistoryPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(Color(nsColor: .windowBackgroundColor))
            )
            .foregroundStyle(.secondary)
    }
}

private struct HistoryActionButton: View {
    let systemName: String
    let foreground: Color
    let background: Color
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 34, height: 34)
                .foregroundStyle(foreground)
                .background(
                    Circle()
                        .fill(background)
                )
                .overlay(
                    Circle()
                        .stroke(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}
