import XCTest
import UIKit
@testable import vvhisper

@MainActor final class EmojiSuggestionsTests: XCTestCase {
    func testLocalizedNamesAndKeywordsAreExactBoundedAndDeduplicated() {
        XCTAssertEqual(EmojiCatalog.suggestions(for: ["fire"]).first, "🔥")
        XCTAssertEqual(EmojiCatalog.suggestions(for: ["heart"]).first, "❤️")
        XCTAssertEqual(EmojiCatalog.suggestions(for: ["咖啡"]), ["☕"])
        XCTAssertEqual(EmojiCatalog.suggestions(for: ["爱心"]).first, "❤️")
        XCTAssertEqual(EmojiCatalog.suggestions(for: ["  SMILE  "]).first, "🙂")
        let result = EmojiCatalog.suggestions(for: ["smile", "smile", "开心"])
        XCTAssertEqual(result.count, 3); XCTAssertEqual(Set(result).count, result.count)
        XCTAssertTrue(EmojiCatalog.suggestions(for: ["smilexyz", "not-an-emoji-name"]).isEmpty)
    }
    func testEnglishSelectionReplacesOnlyOwnedWordWithoutAutoConversion() {
        let proxy = TextViewProxy("keep ", selection: .init(location: 5, length: 0))
        let typing = TypingAssistance()
        for letter in "fire" { typing.insert(String(letter), into: proxy, correction: false, spacing: true) }
        XCTAssertEqual(proxy.editor.text, "keep fire")
        XCTAssertTrue(typing.acceptEmoji("🔥", in: proxy))
        XCTAssertEqual(proxy.editor.text, "keep 🔥"); XCTAssertTrue(typing.word.isEmpty)
        XCTAssertFalse(typing.acceptEmoji("🔥", in: proxy))
        typing.insert(" ", into: proxy, correction: false, spacing: true)
        for letter in "fire" { typing.insert(String(letter), into: proxy, correction: false, spacing: true) }
        proxy.documentIdentifier = UUID()
        XCTAssertFalse(typing.acceptEmoji("🔥", in: proxy))
        XCTAssertTrue(proxy.editor.text.hasSuffix("fire"))
    }
    func testCompactPanelKeepsNavigationAndGainsEmojiRows() throws {
        let panel = EmojiPanel()
        for size in [CGSize(width: 375, height: 280), CGSize(width: 802, height: 208)] {
            panel.frame = CGRect(origin: .zero, size: size); panel.layoutIfNeeded()
            let grid = try XCTUnwrap(panel.subviews.compactMap { $0 as? UICollectionView }.first)
            XCTAssertEqual(grid.frame.minY, 48)
            XCTAssertEqual(grid.frame.maxY, size.height)
            XCTAssertNotNil(panel.subviews.first { $0.accessibilityIdentifier == "emoji.system-keyboard" })
            let close = try XCTUnwrap(panel.subviews.first { $0.accessibilityIdentifier == "emoji.close" } as? UIButton)
            var closed = false; panel.onClose = { closed = true }; close.sendActions(for: .touchUpInside)
            XCTAssertTrue(closed)
            XCTAssertFalse(panel.subviews.contains { $0 is UILabel })
        }
    }
    func testChineseEmojiChoiceReplacesComposition() async throws {
        let language = KeyboardLanguage.load(), mode = KeyboardLayoutMode.load()
        KeyboardLanguage.chinese.save(); KeyboardLayoutMode.full.save()
        defer { language.save(); mode.save() }
        let keyboard = KeyboardViewController(), proxy = TextViewProxy("", selection: .init(location: 0, length: 0))
        keyboard.testingDocumentProxy = proxy; keyboard.loadViewIfNeeded()
        await withCheckedContinuation { c in PinyinEngine.shared.perform(.clear) { _ in c.resume() } }
        defer { keyboard.viewWillDisappear(false) }
        keyboard.view.frame = CGRect(x: 0, y: 0, width: 466, height: 280)
        keyboard.viewDidLayoutSubviews(); keyboard.view.layoutIfNeeded()
        func descendants(_ view: UIView) -> [UIView] { view.subviews.flatMap { [$0] + descendants($0) } }
        for letter in "kafei" {
            let key = try XCTUnwrap(descendants(keyboard.view).compactMap { $0 as? KeyControl }.first { $0.value == String(letter) })
            XCTAssertTrue(key.accessibilityActivate())
        }
        let deadline = Date().addingTimeInterval(5)
        var choice: CandidateButton?
        while choice == nil, Date() < deadline {
            keyboard.view.layoutIfNeeded()
            if proxy.editor.text == "ka fei" {
                choice = descendants(keyboard.view).compactMap { $0 as? CandidateButton }.first { $0.accessibilityLabel == "☕" && $0.isEnabled }
            }
            if choice == nil { try await Task.sleep(for: .milliseconds(20)) }
        }
        XCTAssertTrue(try XCTUnwrap(choice).accessibilityActivate())
        while proxy.editor.markedTextRange != nil, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(proxy.editor.text, "☕")
    }
}
