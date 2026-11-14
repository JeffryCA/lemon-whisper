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
}
