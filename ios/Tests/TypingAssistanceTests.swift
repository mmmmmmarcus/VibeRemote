import XCTest
import UIKit
@testable import vvhisper

@MainActor final class TypingAssistanceTests: XCTestCase {
    private func type(_ text: String, with session: TypingAssistance, in proxy: TextViewProxy,
                      correction: Bool = true, spacing: Bool = true) {
        for c in text { session.insert(String(c), into: proxy, correction: correction, spacing: spacing) }
    }
    func testCorrectionUndoAndRejectionPreserveOriginal() {
        let proxy = TextViewProxy("", selection: .init(location: 0, length: 0)), session = TypingAssistance()
        type("teh ", with: session, in: proxy)
        XCTAssertEqual(proxy.editor.text, "the ")
        session.delete(in: proxy); XCTAssertEqual(proxy.editor.text, "teh")
        type(" ", with: session, in: proxy); XCTAssertEqual(proxy.editor.text, "teh ")
        type("recieve!", with: session, in: proxy); XCTAssertEqual(proxy.editor.text, "teh receive! ")
        session.delete(in: proxy); XCTAssertEqual(proxy.editor.text, "teh recieve")
    }
    func testImContractionCorrectsAtBoundaryAndCanBeRejected() {
        for spelling in ["im", "Im"] {
            let proxy = TextViewProxy("hello ", selection: .init(location: 6, length: 0)), session = TypingAssistance()
            type(spelling, with: session, in: proxy)
            XCTAssertEqual(proxy.editor.text, "hello " + spelling)
            XCTAssertEqual(session.suggestions.first, "I'm")
            type(" ", with: session, in: proxy)
            XCTAssertEqual(proxy.editor.text, "hello I'm ")
            session.delete(in: proxy)
            XCTAssertEqual(proxy.editor.text, "hello " + spelling)
            type(" ", with: session, in: proxy)
            XCTAssertEqual(proxy.editor.text, "hello " + spelling + " ")
        }
        let proxy = TextViewProxy("", selection: .init(location: 0, length: 0)), session = TypingAssistance()
        type("im,", with: session, in: proxy)
        XCTAssertEqual(proxy.editor.text, "I'm, ")
        type("IM ", with: session, in: proxy)
        XCTAssertEqual(proxy.editor.text, "I'm, IM ")
        type("im ", with: session, in: proxy, correction: false)
        XCTAssertEqual(proxy.editor.text, "I'm, IM im ")
    }
    func testOneSlipAndMissingWordSpaceAreBounded() {
        for (a, b) in [("helllo", "hello"), ("helo", "hello"), ("desgin", "design"), ("wprld", "world")] {
            XCTAssertTrue(EnglishCorrection.isClose(a, b))
        }
        XCTAssertFalse(EnglishCorrection.isClose("vvhisper", "whisper"))
        XCTAssertFalse(EnglishCorrection.isClose("marcus", "marco"))
        let checker = CorrectionChecker()
        let corrector = EnglishCorrection(checker: checker)
        XCTAssertEqual(corrector.suggestions(for: "helloworld"), ["hello world"])
        let proxy = TextViewProxy("", selection: .init(location: 0, length: 0))
        type("helloworld ", with: TypingAssistance(corrector: corrector), in: proxy)
        XCTAssertEqual(proxy.editor.text, "hello world ")
    }
    func testPunctuationSpacingAndExplicitSpaces() {
        let proxy = TextViewProxy("", selection: .init(location: 0, length: 0)), session = TypingAssistance()
        type("hello ,world!?\n", with: session, in: proxy)
        XCTAssertEqual(proxy.editor.text, "hello, world!?\n")
        type("hello,world", with: session, in: proxy, spacing: false)
        XCTAssertTrue(proxy.editor.text.hasSuffix("hello,world"))
        type(" hello, world", with: session, in: proxy)
        XCTAssertTrue(proxy.editor.text.hasSuffix(" hello, world"))
    }
    func testSelectingCorrectionAddsSpaceAndUndoIsImmediateOnly() {
        let proxy = TextViewProxy("", selection: .init(location: 0, length: 0)), session = TypingAssistance()
        type("teh", with: session, in: proxy)
        XCTAssertEqual(session.suggestions, ["the"])
        XCTAssertTrue(session.accept("the", in: proxy, spacing: true)); XCTAssertEqual(proxy.editor.text, "the ")
        type("a", with: session, in: proxy); session.delete(in: proxy)
        XCTAssertEqual(proxy.editor.text, "the ")
    }
    func testKnownTermsPinyinAcronymsAndMissingContextStayLiteral() {
        let proxy = TextViewProxy("", selection: .init(location: 0, length: 0)), session = TypingAssistance()
        let text = "vvhisper Figma API haode wozhidaole "
        type(text, with: session, in: proxy); XCTAssertEqual(proxy.editor.text, text)
        type("teh ", with: session, in: proxy, correction: false); XCTAssertTrue(proxy.editor.text.hasSuffix("teh "))
        type("tehx", with: session, in: proxy, correction: false)
        session.delete(in: proxy, correction: false)
        XCTAssertTrue(session.suggestions.isEmpty)
        proxy.hidesContext = true
        type("adn ", with: session, in: proxy); XCTAssertTrue(proxy.editor.text.hasSuffix("adn "))
    }
    func testEmailURLCodeAndMidWordNeverCorrect() {
        for prefix in ["name@", "https://", "some_", "x", "3"] {
            let proxy = TextViewProxy(prefix, selection: .init(location: prefix.utf16.count, length: 0)), session = TypingAssistance()
            type("teh ", with: session, in: proxy); XCTAssertEqual(proxy.editor.text, prefix + "teh ")
        }
        let domain = TextViewProxy("", selection: .init(location: 0, length: 0))
        type("example.com", with: TypingAssistance(), in: domain)
        XCTAssertEqual(domain.editor.text, "example.com")
        let proxy = TextViewProxy("after", selection: .init(location: 0, length: 0)), session = TypingAssistance()
        type("teh ", with: session, in: proxy); XCTAssertEqual(proxy.editor.text, "teh after")
        for kind in [UIKeyboardType.emailAddress, .URL, .numberPad] {
            let field = TextViewProxy("", selection: .init(location: 0, length: 0)); field.keyboardType = kind
            type("teh,", with: TypingAssistance(), in: field); XCTAssertEqual(field.editor.text, "teh,")
        }
    }
    func testFieldAndCaretChangesDiscardUndoAndCandidates() {
        for move in [false, true] {
            let proxy = TextViewProxy("", selection: .init(location: 0, length: 0)), session = TypingAssistance()
            type("teh ", with: session, in: proxy)
            if move { proxy.editor.selectedRange = .init(location: 0, length: 0) }
            else { proxy.documentIdentifier = UUID() }
            session.delete(in: proxy)
            XCTAssertEqual(proxy.editor.text, move ? "the " : "the")
            XCTAssertTrue(session.suggestions.isEmpty)
        }
    }
    func testDelayedProxyEditsNeverDeleteUnacknowledgedText() {
        let proxy = TextViewProxy("", selection: .init(location: 0, length: 0)), session = TypingAssistance()
        proxy.defersTextEdits = true
        type("teh ", with: session, in: proxy)
        XCTAssertEqual(proxy.backspaces, 0)
        proxy.flushTextEdits(); XCTAssertEqual(proxy.editor.text, "teh ")
    }
    func testNilEmptyProxyContextsStillCorrectAtStartAndEnd() {
        let proxy = TextViewProxy("", selection: .init(location: 0, length: 0)), session = TypingAssistance()
        proxy.nilAtEmptyContext = true
        type("teh ", with: session, in: proxy)
        XCTAssertEqual(proxy.editor.text, "the ")
        type("recieve", with: session, in: proxy)
        XCTAssertTrue(session.accept("receive", in: proxy, spacing: true))
        XCTAssertEqual(proxy.editor.text, "the receive ")
    }
    func testTypingSettingsMigrateAndPersistIndependently() throws {
        var stored = try JSONDecoder().decode(KeyboardPreferences.self, from: Data("{}".utf8))
        XCTAssertTrue(stored.autoCorrectionEnabled); XCTAssertTrue(stored.smartSpacingEnabled)
        let page = TypingSettingsViewController(load: { stored }, save: { stored = $0 })
        page.loadViewIfNeeded()
        for row in 0...1 {
            let cell = page.tableView(page.tableView, cellForRowAt: .init(row: row, section: 0))
            let toggle = try XCTUnwrap(cell.accessoryView as? UISwitch)
            toggle.isOn = false; toggle.sendActions(for: .valueChanged)
        }
        XCTAssertFalse(stored.autoCorrectionEnabled); XCTAssertFalse(stored.smartSpacingEnabled)
        XCTAssertEqual(try JSONDecoder().decode(KeyboardPreferences.self, from: JSONEncoder().encode(stored)), stored)
        XCTAssertEqual(stored.hapticStrength, 0.45)
    }
}

private final class CorrectionChecker: UITextChecker {
    override func rangeOfMisspelledWord(in stringToCheck: String, range: NSRange, startingAt startingOffset: Int, wrap wrapFlag: Bool, language: String) -> NSRange { range }
    override func guesses(forWordRange range: NSRange, in string: String, language: String) -> [String]? {
        string == "helloworld" ? ["hello world", "something unrelated"] : []
    }
}
