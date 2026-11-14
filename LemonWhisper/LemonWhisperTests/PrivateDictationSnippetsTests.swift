import Testing
@testable import LemonWhisper

struct PrivateDictationSnippetsTests {
    @Test func expandsOnlyAStandaloneTrigger() {
        let entries = [
            PrivateDictationSnippets.Entry(trigger: "my email", value: "example@example.test"),
            PrivateDictationSnippets.Entry(trigger: "my phone number", value: "+1 212 555 0100")
        ]

        #expect(PrivateDictationSnippets.expanding(in: "  My EMAIL? ", using: entries) == "example@example.test")
        #expect(PrivateDictationSnippets.expanding(in: "My  phone number.", using: entries) == "+1 212 555 0100")
        #expect(PrivateDictationSnippets.expanding(in: "“MY, E-mail?!”", using: entries) == "example@example.test")
        #expect(PrivateDictationSnippets.expanding(in: "—my phone-number…", using: entries) == "+1 212 555 0100")
        #expect(PrivateDictationSnippets.expanding(in: "“My email,” please.", using: entries) == "“My email,” please.")
        #expect(PrivateDictationSnippets.expanding(in: "Tell me where my email is.", using: entries) == "Tell me where my email is.")
        #expect(PrivateDictationSnippets.expanding(in: "My phone number changed.", using: entries) == "My phone number changed.")
    }
}
