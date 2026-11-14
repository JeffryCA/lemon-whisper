import SwiftUI

struct PrivateDictationSnippetsView: View {
    @State private var entries: [PrivateDictationSnippets.Entry] = []
    @State private var trigger = ""
    @State private var value = ""
    @State private var errorMessage: String?
    @State private var hasLoaded = false

    var body: some View {
        GroupBox("Spoken replacements") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Say a shortcut by itself, such as “my email” or “my phone number.” Lemon Whisper inserts the saved value when you stop recording.")
                .foregroundStyle(.secondary)
                if hasLoaded {
                    HStack {
                        TextField("Spoken shortcut", text: $trigger)
                        TextField("Text to insert", text: $value)
                            .onSubmit(save)
                        Button(entries.contains { $0.key == triggerKey } ? "Update" : "Add", action: save)
                            .disabled(!canSave)
                    }
                    ForEach(entries, id: \.trigger) { entry in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Button(entry.trigger) {
                                    trigger = entry.trigger
                                    value = entry.value
                                }
                                .buttonStyle(.link)
                                .help("Edit this shortcut")
                                Text(entry.value)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                update(entries.filter { $0.trigger != entry.trigger })
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove \(entry.trigger)")
                        }
                    }
                }
                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
                if !hasLoaded {
                    Button("Reload", action: load)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { load() }
    }

    private var cleanTrigger: String { trigger.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var triggerKey: String { PrivateDictationSnippets.triggerKey(for: cleanTrigger) }
    private var cleanValue: String { value.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canSave: Bool {
        !triggerKey.isEmpty && TranscriptionDictionary.isValid(cleanTrigger)
            && !cleanValue.isEmpty && cleanValue.utf8.count <= 4096
    }

    private func save() {
        guard canSave else { return }
        let entry = PrivateDictationSnippets.Entry(trigger: cleanTrigger, value: cleanValue)
        var updated = entries.filter { $0.key != entry.key }
        updated.append(entry)
        if update(updated) {
            trigger = ""
            value = ""
        }
    }

    private func load() {
        do {
            entries = try PrivateDictationSnippets.load()
            errorMessage = nil
            hasLoaded = true
        } catch {
            errorMessage = "Could not read spoken replacements. \(error.localizedDescription)"
        }
    }

    @discardableResult
    private func update(_ updated: [PrivateDictationSnippets.Entry]) -> Bool {
        do {
            try PrivateDictationSnippets.save(updated)
            entries = updated
            errorMessage = nil
            return true
        } catch {
            errorMessage = "Could not save spoken replacements. \(error.localizedDescription)"
            return false
        }
    }
}
