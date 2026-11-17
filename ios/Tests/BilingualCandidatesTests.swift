import XCTest
import UIKit
@testable import vvhisper

@MainActor
final class BilingualCandidatesTests: XCTestCase {
    func testRecognizedEnglishAndChineseAppearTogetherWithMatchingSpaceChoice() {
        let checker = ControlledEnglishChecker()
        checker.words = ["can"]
        let choices = BilingualCandidates(checker: checker).choices(
            for: .init(input: "can", commitPreview: "才", candidates: ["才", "餐"]), letterCase: .lowercase)
        XCTAssertEqual(choices.map(\.text), ["can", "才", "餐"])
        guard case .english("can ") = choices.first?.spaceAction else { return XCTFail("Space should accept English with a space") }
        guard case .english("can") = choices.first?.action else { return XCTFail("Tapping should accept the word alone") }
    }

    func testChinesePhraseOmitsRawSpellingAndKeepsSpaceSelection() {
        let checker = ControlledEnglishChecker()
        let choices = BilingualCandidates(checker: checker).choices(
            for: .init(input: "haode", commitPreview: "好的", candidates: ["好的", "好得"]), letterCase: .lowercase)
        XCTAssertEqual(choices.map(\.text), ["好的", "好得"])
        guard case .choose(0) = choices.first?.spaceAction else { return XCTFail("Space should accept the first Chinese candidate") }
    }

    func testMissingEnglishDictionaryDoesNotClassifyEveryPinyinPhraseAsEnglish() {
        let checker = ControlledEnglishChecker()
        checker.dictionaryUnavailable = true
        let provider = BilingualCandidates(checker: checker)
        let chinese = provider.choices(for: .init(input: "wozhidaole", commitPreview: "我知道了", candidates: ["我知道了"]), letterCase: .lowercase)
        XCTAssertEqual(chinese.map(\.text), ["我知道了"])
        let latin = provider.choices(for: .init(input: "hello", commitPreview: "hello", candidates: ["和"]), letterCase: .lowercase)
        XCTAssertEqual(latin.first?.text, "hello")
        let capital = provider.choices(for: .init(input: "can", commitPreview: "才", candidates: ["才"]), letterCase: .initialCapital)
        XCTAssertEqual(capital.first?.text, "Can")
    }

    func testCompletionsAreBoundedUniqueAndKeepChineseChoiceIndices() {
        let checker = ControlledEnglishChecker()
        checker.suggestions = ["hel", "hello", "Hello", "help", "helicopter"]
        let choices = BilingualCandidates(checker: checker).choices(
            for: .init(input: "hel", commitPreview: "和l", candidates: ["和", "何"]), letterCase: .initialCapital)
        XCTAssertEqual(choices.map(\.text), ["Hel", "和", "Hello", "Help", "何"])
        guard case .choose(1) = choices.last?.action else { return XCTFail("Chinese index must remain the Rime index") }
    }

    func testPagingKeepsPagedChineseFirstAndDefaultProviderStaysChineseOnly() {
        let checker = ControlledEnglishChecker(); checker.words = ["can"]
        let snapshot = PinyinEngine.Snapshot(input: "can", commitPreview: "参", candidates: ["参", "灿"], page: 1)
        let choices = BilingualCandidates(checker: checker).choices(for: snapshot, letterCase: .lowercase)
        XCTAssertEqual(choices.map(\.text), ["参", "can", "灿"])
        guard case .choose(0) = choices.first?.spaceAction else { return XCTFail("Space should accept this page's first candidate") }
        XCTAssertEqual(PinyinCandidates().choices(for: snapshot, letterCase: .uppercase).map(\.text), snapshot.candidates)
    }
}

private final class ControlledEnglishChecker: UITextChecker {
    var words: Set<String> = []
    var suggestions: [String] = []
    var dictionaryUnavailable = false
    override func rangeOfMisspelledWord(in stringToCheck: String, range: NSRange, startingAt startingOffset: Int,
                                        wrap wrapFlag: Bool, language: String) -> NSRange {
        dictionaryUnavailable || words.contains(stringToCheck)
            ? NSRange(location: NSNotFound, length: 0) : range
    }
    override func completions(forPartialWordRange range: NSRange, in string: String, language: String) -> [String]? {
        suggestions
    }
}
