import XCTest
@testable import VibeRemote

final class DictationDictionaryTests: XCTestCase {
    private func entry(_ word: String) -> DictationDictionaryEntry {
        DictationDictionaryEntry(word: word)
    }

    func testWordsAreCaseCorrected() {
        let dictionary = [entry("VibeRemote"), entry("Codex"), entry("豆包")]
        XCTAssertEqual(DictationDictionary.apply(dictionary, to: "Open viberemote"), "Open VibeRemote")
        // Whole words only.
        XCTAssertEqual(DictationDictionary.apply(dictionary, to: "ask codex, not codexes"), "ask Codex, not codexes")
        // Latin words still match beside Chinese, which has no spaces.
        XCTAssertEqual(DictationDictionary.apply(dictionary, to: "用codex写，问豆包"), "用Codex写，问豆包")
        // Longer words win over shorter ones they contain.
        XCTAssertEqual(DictationDictionary.apply([entry("Claude"), entry("Claude Code")], to: "claude code and claude"),
                       "Claude Code and Claude")
        // Template characters in the word are written literally.
        XCTAssertEqual(DictationDictionary.apply([entry("$HOME")], to: "echo $home"), "echo $HOME")
        XCTAssertEqual(DictationDictionary.apply([], to: "unchanged"), "unchanged")
    }

    func testSavedEntriesWithTheRemovedHeardAsKeyStillLoad() throws {
        let json = #"[{"id":"7B5C9A10-1F7B-4C3E-9E2A-5D7A1C2B3E4F","word":"Codex","heardAs":"code x"}]"#
        let entries = try JSONDecoder().decode([DictationDictionaryEntry].self, from: Data(json.utf8))
        XCTAssertEqual(entries.map(\.word), ["Codex"])
    }

    func testHotwordsAreCleanedDedupedAndBudgeted() {
        XCTAssertEqual(DictationDictionary.hotwords([entry("Gestalt-X!"), entry("  "), entry("豆包"), entry("豆包")]),
                       ["Gestalt X", "豆包"])
        XCTAssertEqual(DictationDictionary.tokenEstimate("豆包"), 2)
        XCTAssertEqual(DictationDictionary.tokenEstimate("ProseMirror"), 3)
        let many = (0..<100).map { entry("Word\($0)") }
        let kept = DictationDictionary.hotwords(many)
        XCTAssertLessThanOrEqual(kept.reduce(0) { $0 + DictationDictionary.tokenEstimate($1) }, DictationDictionary.hotwordBudget)
        XCTAssertEqual(kept.first, "Word0", "the list's order is the user's priority")
    }

    func testSeedContextIsAJSONStringOfHotwords() throws {
        XCTAssertNil(DictationDictionary.seedContext([]))
        let context = try XCTUnwrap(DictationDictionary.seedContext([entry("VibeRemote"), entry("豆包")]))
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(context.utf8)) as? [String: [[String: String]]])
        XCTAssertEqual(parsed["hotwords"]?.map { $0["word"] }, ["VibeRemote", "豆包"])
    }

    func testFlashRequestCarriesHotwordsButTheStreamDoesNotByDefault() throws {
        let audio = DictationAudio(samples: [0, 0.1, -0.1])
        let flash = SeedASRDictationEngine.request(audio: audio, accessKey: "k", appID: "", resourceID: "r", context: "{\"hotwords\":[]}")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(flash.httpBody)) as? [String: Any])
        let corpus = (body["request"] as? [String: Any])?["corpus"] as? [String: String]
        XCTAssertEqual(corpus?["context"], "{\"hotwords\":[]}", "the context is a JSON string, not an object")
        let plain = SeedASRDictationEngine.request(audio: audio, accessKey: "k", appID: "", resourceID: "r")
        let plainBody = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(plain.httpBody)) as? [String: Any])
        XCTAssertNil((plainBody["request"] as? [String: Any])?["corpus"])
        let stream = try XCTUnwrap(JSONSerialization.jsonObject(with: SeedStreamFrame.requestJSON(appID: "")) as? [String: Any])
        XCTAssertNil((stream["request"] as? [String: Any])?["corpus"])
    }

    func testEditorTextBecomesDialogContextBesideTheHotwords() throws {
        XCTAssertNil(DictationDictionary.seedContext([], editorText: "  \n "), "blank editor text sends nothing")
        let both = try XCTUnwrap(DictationDictionary.seedContext([entry("Codex")], editorText: "Ask Codex to fix it\n"))
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(both.utf8)) as? [String: Any])
        XCTAssertEqual((parsed["hotwords"] as? [[String: String]])?.map { $0["word"] }, ["Codex"])
        XCTAssertEqual(parsed["context_type"] as? String, "dialog_ctx")
        XCTAssertEqual(parsed["context_data"] as? [[String: String]], [["text": "Ask Codex to fix it"]])
        let alone = try XCTUnwrap(DictationDictionary.seedContext([], editorText: "上一句话"))
        XCTAssertNil((try JSONSerialization.jsonObject(with: Data(alone.utf8)) as? [String: Any])?["hotwords"])
    }

    func testEditorContextKeepsTheTextNearestTheCaret() {
        let long = String(repeating: "a", count: 600) + "END"
        let kept = DictationEditorContext.trimmed(long)
        XCTAssertEqual(kept?.count, DictationEditorContext.characterLimit)
        XCTAssertTrue(kept?.hasSuffix("END") == true)
        // UTF-16 caret locations, including after an emoji (two code units).
        XCTAssertEqual(DictationEditorContext.textBefore(location: 7, in: "Hi 👋 there"), "Hi 👋 t")
        XCTAssertEqual(DictationEditorContext.textBefore(location: 2, in: "你好世界"), "你好")
        XCTAssertNil(DictationEditorContext.textBefore(location: 0, in: "text"), "nothing before the caret")
        XCTAssertNil(DictationEditorContext.textBefore(location: 99, in: "text"))
    }

    func testFillerRemovalFlagReachesBothRequests() throws {
        let audio = DictationAudio(samples: [0, 0.1, -0.1])
        func options(_ request: URLRequest) throws -> [String: Any] {
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
            return try XCTUnwrap(body["request"] as? [String: Any])
        }
        XCTAssertEqual(try options(SeedASRDictationEngine.request(audio: audio, accessKey: "k", appID: "", resourceID: "r",
                                                                   removeFillers: true))["enable_ddc"] as? Bool, true)
        XCTAssertEqual(try options(SeedASRDictationEngine.request(audio: audio, accessKey: "k", appID: "",
                                                                   resourceID: "r"))["enable_ddc"] as? Bool, false)
        let stream = try XCTUnwrap(JSONSerialization.jsonObject(with: SeedStreamFrame.requestJSON(appID: "", removeFillers: true)) as? [String: Any])
        XCTAssertEqual((stream["request"] as? [String: Any])?["enable_ddc"] as? Bool, true)
    }

    func testFillerRemovalAndEditorContextDefaultOn() throws {
        let suite = "DictationDictionaryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fresh = DictationSettings.load(from: defaults)
        XCTAssertTrue(fresh.seedRemoveFillers)
        XCTAssertTrue(fresh.seedEditorContext)
        var changed = fresh
        changed.seedRemoveFillers = false
        changed.seedEditorContext = false
        changed.save(to: defaults)
        let loaded = DictationSettings.load(from: defaults)
        XCTAssertFalse(loaded.seedRemoveFillers)
        XCTAssertFalse(loaded.seedEditorContext)
    }

    func testOpenAIGetsTheVocabularyAsItsPrompt() throws {
        XCTAssertNil(DictationDictionary.openAIPrompt([entry("  ")]))
        let prompt = try XCTUnwrap(DictationDictionary.openAIPrompt([entry("VibeRemote"), entry("Codex")]))
        XCTAssertEqual(prompt, "Vocabulary: VibeRemote, Codex.")
        let request = OpenAIDictationEngine.request(audio: DictationAudio(samples: [0]), apiKey: "k", model: "m",
                                                    language: "", prompt: prompt, boundary: "B")
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"prompt\"\r\n\r\nVocabulary: VibeRemote, Codex.\r\n"))
    }

    func testDictionaryRoundTripsWithTheOtherSettings() throws {
        let suite = "DictationDictionaryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = DictationSettings.load(from: defaults)
        XCTAssertTrue(settings.dictionary.isEmpty)
        settings.dictionary = [entry("VibeRemote"), entry("")]
        settings.save(to: defaults)
        let loaded = DictationSettings.load(from: defaults)
        XCTAssertEqual(loaded.dictionary.map(\.word), ["VibeRemote"], "blank rows are not saved")
    }
}
