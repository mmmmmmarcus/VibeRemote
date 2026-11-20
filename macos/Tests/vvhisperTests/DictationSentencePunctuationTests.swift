import XCTest
@testable import vvhisper

final class DictationSentencePunctuationTests: XCTestCase {
    func testShortSentenceEndingsAndInteriorPunctuation() {
        for (input, off, on) in [
            ("Hello", "Hello", "Hello."), ("Hello.", "Hello", "Hello."),
            ("Are you ready?!", "Are you ready", "Are you ready?!"),
            ("Yes, please!", "Yes, please", "Yes, please!"),
            ("你好", "你好", "你好。"), ("你好！", "你好", "你好！"),
            ("“Hello!”", "“Hello”", "“Hello!”"), ("“Hello”", "“Hello”", "“Hello.”"),
            ("Version 2.0.", "Version 2.0", "Version 2.0."),
            ("", "", ""), ("...", "...", "...")
        ] {
            XCTAssertEqual(DictationSentencePunctuation.apply(input, enabled: false), off, input)
            XCTAssertEqual(DictationSentencePunctuation.apply(input, enabled: true), on, input)
        }
    }
    func testParagraphsAndAmbiguousTextBypassBothModes() {
        let inputs = ["First sentence. Second sentence.", "第一句。第二句。", "First\nSecond.",
                      "Ask Dr. Smith.", "Visit example.com.", "https://example.com/path", "a@example.com",
                      String(repeating: "a", count: 121) + ".", String(repeating: "word ", count: 21) + "end.",
                      String(repeating: "中", count: 41) + "。"]
        for input in inputs {
            for enabled in [true, false] {
                XCTAssertEqual(DictationSentencePunctuation.apply(input, enabled: enabled), input)
            }
        }
    }
    func testBoundariesAreInclusive() {
        let latin = String(repeating: "a", count: 119) + "."
        XCTAssertEqual(DictationSentencePunctuation.apply(latin, enabled: false), String(latin.dropLast()))
        let han = String(repeating: "中", count: 39) + "。"
        XCTAssertEqual(DictationSentencePunctuation.apply(han, enabled: false), String(han.dropLast()))
        let words = Array(repeating: "a", count: 20).joined(separator: " ") + "."
        XCTAssertEqual(DictationSentencePunctuation.apply(words, enabled: false), String(words.dropLast()))
    }
    func testPreferenceDefaultsOnAndPersistsIndependentlyOfPolishing() throws {
        let name = "vvhisper.punctuation-test.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var settings = DictationSettings.load(from: defaults)
        XCTAssertTrue(settings.sentencePunctuation)
        settings.sentencePunctuation = false
        settings.polishDictation = false
        settings.save(to: defaults)
        let saved = DictationSettings.load(from: defaults)
        XCTAssertFalse(saved.sentencePunctuation)
        XCTAssertFalse(saved.polishDictation)
    }
}
