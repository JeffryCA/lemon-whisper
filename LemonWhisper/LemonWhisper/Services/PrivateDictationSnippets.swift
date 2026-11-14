import Foundation

/// A separate dictionary of spoken shortcuts. Only the final insertion path expands values.
enum PrivateDictationSnippets {
    struct Entry: Codable, Equatable {
        let trigger: String
        let value: String

        var key: String { PrivateDictationSnippets.triggerKey(for: trigger) }
    }

    private static let fileURL = TranscriptionDictionary.fileURL.deletingLastPathComponent()
        .appendingPathComponent("Replacements.json")

    static func load(from url: URL = fileURL) throws -> [Entry] {
        do {
            return try JSONDecoder().decode([Entry].self, from: Data(contentsOf: url))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        }
    }

    static func save(_ entries: [Entry], to url: URL = fileURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(entries).write(to: url, options: .atomic)
    }

    static func triggerKey(for text: String) -> String {
        let normalized = text.lowercased().precomposedStringWithCanonicalMapping
        let words = normalized
            .components(separatedBy: .punctuationCharacters.union(.whitespacesAndNewlines))
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return words.replacingOccurrences(of: #"\be mail\b"#, with: "email", options: .regularExpression)
    }

    static func expanding(in text: String) -> String {
        guard let entries = try? load() else { return text }
        return expanding(in: text, using: entries)
    }

    static func expanding(in text: String, using entries: [Entry]) -> String {
        let key = triggerKey(for: text)
        guard !key.isEmpty else { return text }
        let matches = entries.filter { $0.key == key }
        if matches.count == 1 { return matches[0].value }
        // Older entries can become equivalent under the broader punctuation rules.
        let exact = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return matches.first(where: { $0.trigger.caseInsensitiveCompare(exact) == .orderedSame })?.value ?? text
    }
}
