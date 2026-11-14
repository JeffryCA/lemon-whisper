import SwiftUI

struct DictationSettingsView: View {
    let backend: TranscriptionBackend

    @AppStorage(AppSettingsStore.vocabularyHintsEnabledKey) private var hintsEnabled = false
    @AppStorage(AppSettingsStore.transcriptionContextKey) private var context = ""
    @AppStorage(AppSettingsStore.livePreviewEnabledKey) private var livePreview = false
    @State private var dictionary = TranscriptionDictionary()
    @State private var term = ""
    @State private var alias = ""
    @State private var errorMessage: String?
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("Vocabulary hints") {
                    VStack(alignment: .leading, spacing: 8) {
                        if backend.supportsVocabularyHints {
                            Toggle("Use dictionary terms and context during recognition", isOn: $hintsEnabled)
                            TextField("Additional context (optional)", text: $context, axis: .vertical)
                                .lineLimit(2...4)
                                .disabled(!hintsEnabled)
                        } else {
                            Text("Available with Qwen3-ASR and Whisper.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Live dictation") {
                    VStack(alignment: .leading, spacing: 8) {
                        if backend.supportsLivePreview {
                            Toggle("Stream text into the focused field", isOn: $livePreview)
                        }
                        Text(backend.supportsLivePreview
                             ? "Words appear as you speak in supported text fields. Moving the caret or switching fields pauses live edits."
                             : "Available with Qwen3-ASR.")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                PrivateDictationSnippetsView()

                GroupBox("Dictionary") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Enter a preferred term for vocabulary hints. Add a mishearing to replace it locally with any model.")
                            .foregroundStyle(.secondary)
                        HStack {
                            TextField("Mishearing (optional)", text: $alias)
                            TextField("Preferred term", text: $term)
                                .onSubmit(addEntry)
                            Button("Add", action: addEntry)
                                .disabled(!canAdd)
                        }
                        if let errorMessage {
                            Text(errorMessage)
                                .foregroundStyle(.red)
                        }
                        ForEach(dictionary.entries, id: \.self) { entry in
                            HStack {
                                Text(entry.alias.map { "\($0) → \(entry.term)" } ?? entry.term)
                                    .textSelection(.enabled)
                                Spacer()
                                Button(role: .destructive) {
                                    update { $0.entries.removeAll { $0 == entry } }
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Remove \(entry.alias ?? entry.term)")
                            }
                        }
                        Button("Reload", action: reload)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(20)
        }
        .onAppear(perform: reload)
        .onChange(of: appearsActive) { _, active in
            if active { reload() }
        }
    }

    private var cleanTerm: String { term.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var cleanAlias: String { alias.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canAdd: Bool {
        TranscriptionDictionary.isValid(cleanTerm)
            && (cleanAlias.isEmpty || TranscriptionDictionary.isValid(cleanAlias))
    }

    private func addEntry() {
        guard canAdd else { return }
        let entry = TranscriptionDictionary.Entry(term: cleanTerm, alias: cleanAlias.isEmpty ? nil : cleanAlias)
        if update({ current in
            current.entries.removeAll { $0.match == entry.match }
            current.entries.append(entry)
        }) {
            term = ""
            alias = ""
        }
    }

    private func reload() {
        do {
            dictionary = try TranscriptionDictionary.load()
            errorMessage = nil
        } catch {
            errorMessage = "Could not read the dictionary. \(error.localizedDescription)"
        }
    }

    @discardableResult
    private func update(_ change: (inout TranscriptionDictionary) -> Void) -> Bool {
        do {
            dictionary = try TranscriptionDictionary.update(change)
            errorMessage = nil
            return true
        } catch {
            errorMessage = "Could not save the dictionary. \(error.localizedDescription)"
            return false
        }
    }
}
