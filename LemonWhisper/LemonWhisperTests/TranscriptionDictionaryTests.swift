import Testing
@testable import LemonWhisper

struct TranscriptionDictionaryTests {
    @Test func replacesWholePhrasesOnceAndPrefersSpecificAlias() {
        let dictionary = TranscriptionDictionary(entries: [
            .init(term: "Greptile", alias: "Graptile"),
            .init(term: "Reviewer", alias: "Greptile"),
            .init(term: "Voxtral Mini", alias: "vox trail mini"),
            .init(term: "Voxtral", alias: "vox trail"),
            .init(term: "make down")
        ])
        let raw = "GRAPTILE, GraptileKit, Graptile_ID, vox trail mini, and make down."
        #expect(dictionary.applyingCorrections(to: raw) == "Greptile, GraptileKit, Graptile_ID, Voxtral Mini, and make down.")
    }

    @Test func hintsContainCanonicalSpellingsAndFitPromptBudget() throws {
        let dictionary = TranscriptionDictionary(entries: [
            .init(term: "Tailscale", alias: "tail scale"),
            .init(term: "Tailscale"),
            .init(term: "make down")
        ])
        #expect(dictionary.context(additional: "Project names") == "Project names\nVocabulary: Tailscale, make down")
        let longContext = try #require(dictionary.context(additional: String(repeating: "あ", count: 200)))
        #expect(longContext.utf8.count <= 512)
    }
    @Test func removesCopiedVocabularyButKeepsSpokenTerms() {
        let context = "Project names\nVocabulary: Qwen, Tailscale, wrun"
        #expect(TranscriptionDictionary.removingVocabularyEcho(
            from: "Vocabulary: Qwen, Tailscale, wrun.....", context: context
        ).isEmpty)
        #expect(TranscriptionDictionary.removingVocabularyEcho(
            from: "Can you explain Qwen? Qwen, Tailscale, wrun. Vocabulary: Qwen, Tailscale, wrun.....",
            context: context
        ) == "Can you explain Qwen?")
        #expect(TranscriptionDictionary.removingVocabularyEcho(
            from: "Qwen.", context: "Vocabulary: Qwen"
        ) == "Qwen.")
        #expect(TranscriptionDictionary.removingVocabularyEcho(
            from: "Vocabulary: Qwen Vocabulary: Qwen.", context: "Vocabulary: Qwen"
        ).isEmpty)
    }

    @Test func removesRepeatedLabeledVocabularyBetweenSpokenPhrases() {
        let list = "Vocabulary: ElevenLabs, Tailscale, Greptile, Voxtral, Qwen, Feuerwehrmann Sam"
        let spokenStart = "Why do we have so little data about the moral decisions?"
        let spokenEnd = "Or what is the problem here?"
        #expect(TranscriptionDictionary.removingVocabularyEcho(
            from: "\(spokenStart) \(list). \(list). \(list). \(spokenEnd)", context: "Project names\n\(list)"
        ) == "\(spokenStart) \(spokenEnd)")
        #expect(TranscriptionDictionary.removingVocabularyEcho(
            from: "\(list.uppercased())\n\(spokenStart)", context: list
        ) == spokenStart)
    }

    @Test func keepsSpokenListsAndVocabularyPhrasesWithinTranscripts() {
        let list = "Vocabulary: Qwen, Tailscale, wrun"
        let spoken = "I said Qwen, Tailscale, wrun. Vocabulary: Qwen, Tailscale, and wrun are project terms."
        #expect(TranscriptionDictionary.removingVocabularyEcho(from: spoken, context: list) == spoken)
        #expect(TranscriptionDictionary.removingVocabularyEcho(from: list, context: nil) == list)
        let singleTerm = "Vocabulary: Qwen is the first term."
        #expect(TranscriptionDictionary.removingVocabularyEcho(
            from: singleTerm, context: "Vocabulary: Qwen"
        ) == singleTerm)
    }

    @Test(arguments: [
        ("Jeffry.", "Jeffry"), ("Hello world.", "Hello world."),
        ("Jeffry?", "Jeffry?"), ("Wait...", "Wait..."), ("U.S.", "U.S.")
    ])
    func removesOnlySingleWordPeriods(input: String, expected: String) {
        #expect(TranscriptionDictionary.removingSingleWordPeriod(from: input) == expected)
    }
}
