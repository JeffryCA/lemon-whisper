import Darwin
import Foundation

struct TranscriptionDictionary: Codable, Sendable {
    struct Entry: Codable, Equatable, Hashable, Sendable {
        let term: String
        var alias: String? = nil

        var match: String { (alias ?? term).lowercased() }
    }

    var entries: [Entry] = []

    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/LemonWhisper/Dictionary.json")

    static func load(from url: URL = fileURL) throws -> Self {
        do {
            let dictionary = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
            guard dictionary.entries.allSatisfy({ isValid($0.term) && ($0.alias.map(isValid) ?? true) }),
                  Set(dictionary.entries.map(\.match)).count == dictionary.entries.count else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return dictionary
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return Self()
        }
    }

    // Take the same advisory lock as the dictionary CLI. Readers see the previous or new file.
    static func update(_ change: (inout Self) -> Void) throws -> Self {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(fileURL.path + ".lock", O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

        var dictionary = try load()
        change(&dictionary)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(dictionary).write(to: fileURL, options: .atomic)
        return dictionary
    }

    static func isValid(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 160
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && value.rangeOfCharacter(from: .controlCharacters) == nil
    }

    func applyingCorrections(to text: String) -> String {
        let rules = entries.compactMap { entry in
            entry.alias.map { (alias: $0, term: entry.term) }
        }.sorted { $0.alias.utf16.count > $1.alias.utf16.count }
        guard !rules.isEmpty else { return text }

        // Capture the chosen rule's index so matching uses ICU case folding throughout.
        let alternatives = rules.map { "(\(NSRegularExpression.escapedPattern(for: $0.alias)))" }
        let boundary = #"[\p{L}\p{M}\p{N}_]"#
        let pattern = "(?<!\(boundary))(?:\(alternatives.joined(separator: "|")))(?!\(boundary))"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return text }

        let output = NSMutableString(string: text)
        let range = NSRange(location: 0, length: output.length)
        for match in regex.matches(in: text, range: range).reversed() {
            if let index = rules.indices.first(where: { match.range(at: $0 + 1).location != NSNotFound }) {
                output.replaceCharacters(in: match.range, with: rules[index].term)
            }
        }
        return output as String
    }

    /// Decoders can copy the labeled vocabulary between spoken phrases or at the end.
    static func removingVocabularyEcho(from text: String, context: String?) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let hint = context?.split(whereSeparator: \.isNewline).last,
              hint.hasPrefix("Vocabulary: ") else { return result }
        let terms = hint.dropFirst("Vocabulary: ".count)
        let hasMultipleTerms = terms.contains(", ")
        let labeledList = NSRegularExpression.escapedPattern(for: String(hint))
        // A single term can be part of a spoken sentence after the word "vocabulary".
        let singleTermBoundary = hasMultipleTerms ? "" : #"(?=[.!?…]|[^\S\r\n]*(?:\r|\n|$))"#
        result = result.replacingOccurrences(
            of: "(?<!\\S)\(labeledList)\(singleTermBoundary)[.!?…]*(?=\\s|$)\\s*", with: "",
            options: [.regularExpression, .caseInsensitive]
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        // At the end, also accept an unlabeled multi-term list or repeated single-term hints.
        let trailingList = hasMultipleTerms ? NSRegularExpression.escapedPattern(for: String(terms)) : labeledList
        let pattern = "(?<!\\S)\(trailingList)[.!?…]*$"
        while let echo = result.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
            result = result[..<echo.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    static func removingSingleWordPeriod(from text: String) -> String {
        guard text.hasSuffix(".") else { return text }
        let word = text.dropLast()
        guard word.contains(where: \.isLetter),
              !word.contains(where: { $0.isWhitespace || $0 == "." }) else { return text }
        return String(word)
    }

    func context(additional: String) -> String? {
        let budget = 512
        let extra = additional.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\0", with: "")
        var result = ""
        for character in extra {
            guard result.utf8.count + character.utf8.count <= budget else { break }
            result.append(character)
        }

        var seen: Set<String> = []
        var terms: [String] = []
        let prefix = result.isEmpty ? "" : "\n"
        let heading = "Vocabulary: "
        var remaining = budget - result.utf8.count - prefix.utf8.count - heading.utf8.count
        for entry in entries where seen.insert(entry.term.lowercased()).inserted {
            let cost = entry.term.utf8.count + (terms.isEmpty ? 0 : 2)
            guard cost <= remaining else { continue }
            terms.append(entry.term)
            remaining -= cost
        }
        if !terms.isEmpty { result += prefix + heading + terms.joined(separator: ", ") }
        return result.isEmpty ? nil : result
    }
}
