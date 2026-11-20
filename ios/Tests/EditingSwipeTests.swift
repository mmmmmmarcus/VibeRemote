import XCTest
import UIKit
@testable import vvhisper

@MainActor final class WordEditingTests: XCTestCase {
    func testWordBoundariesIncludeTrailingSpacesAndKeepEmojiWhole() {
        XCTAssertEqual(WordDeletion.suffix(in: "hello world!  "), "world!  ")
        XCTAssertEqual(WordDeletion.suffix(in: "hello don't"), "don't")
        XCTAssertEqual(WordDeletion.suffix(in: "你好 世界 "), "世界 ")
        XCTAssertEqual(WordDeletion.suffix(in: "hello 👨‍👩‍👧‍👦"), "👨‍👩‍👧‍👦")
        XCTAssertEqual(WordDeletion.suffix(in: "hello e\u{301}"), "e\u{301}")
        XCTAssertEqual(WordDeletion.suffix(in: "hello\n"), "\n")
        XCTAssertEqual(WordDeletion.suffix(in: "hello !!!"), "!!!")
        XCTAssertNil(WordDeletion.suffix(in: ""))
        XCTAssertNil(WordDeletion.suffix(in: String(repeating: "x", count: 129)))
    }
    func testConsecutiveWordDeletesRestoreInOrderOnlyOnce() {
        let proxy = TextViewProxy("one two three ", selection: NSRange(location: 14, length: 0))
        let edits = WordEditingSession()
        XCTAssertTrue(edits.deleteWord(in: proxy)); XCTAssertEqual(proxy.editor.text, "one two ")
        XCTAssertTrue(edits.deleteWord(in: proxy)); XCTAssertEqual(proxy.editor.text, "one ")
        XCTAssertTrue(edits.restoreWord(in: proxy)); XCTAssertEqual(proxy.editor.text, "one two ")
        XCTAssertTrue(edits.restoreWord(in: proxy)); XCTAssertEqual(proxy.editor.text, "one two three ")
        XCTAssertFalse(edits.restoreWord(in: proxy))
    }
    func testHistoryCannotRestoreIntoChangedFieldCursorOrText() {
        for change in 0..<4 {
            let proxy = TextViewProxy("hello world", selection: NSRange(location: 11, length: 0))
            let edits = WordEditingSession(); XCTAssertTrue(edits.deleteWord(in: proxy))
            switch change {
            case 0: proxy.documentIdentifier = UUID()
            case 1: proxy.editor.selectedRange = NSRange(location: 2, length: 0)
            case 2: proxy.insertText("changed")
            default: proxy.hidesContext = true
            }
            let text = proxy.editor.text
            XCTAssertFalse(edits.restoreWord(in: proxy)); XCTAssertEqual(proxy.editor.text, text)
        }
    }
    func testDelayedAcknowledgementsDoNotRepeatOrLoseUndo() {
        let proxy = TextViewProxy("hello world", selection: NSRange(location: 11, length: 0))
        proxy.defersTextEdits = true; proxy.nilAtEmptyContext = true
        let edits = WordEditingSession()
        XCTAssertTrue(edits.deleteWord(in: proxy)); XCTAssertEqual(proxy.backspaces, 5)
        XCTAssertFalse(edits.deleteWord(in: proxy)); XCTAssertFalse(edits.restoreWord(in: proxy))
        XCTAssertEqual(proxy.backspaces, 5)
        proxy.flushTextEdits(); XCTAssertTrue(edits.observe(proxy)); XCTAssertEqual(proxy.editor.text, "hello ")
        XCTAssertTrue(edits.restoreWord(in: proxy)); XCTAssertFalse(edits.restoreWord(in: proxy))
        proxy.flushTextEdits(); XCTAssertEqual(proxy.editor.text, "hello world")
    }
    func testDeletionRefusesSelectionsAndUnavailableContext() {
        let proxy = TextViewProxy("hello world", selection: NSRange(location: 0, length: 5))
        let edits = WordEditingSession()
        XCTAssertFalse(edits.deleteWord(in: proxy)); XCTAssertEqual(proxy.backspaces, 0)
        proxy.editor.selectedRange = NSRange(location: 11, length: 0); proxy.hidesContext = true
        XCTAssertFalse(edits.deleteWord(in: proxy)); XCTAssertEqual(proxy.backspaces, 0)
    }
    func testDeletingLastWordStillRestoresWhenEmptyHostHasNilContext() {
        let proxy = TextViewProxy("hello", selection: NSRange(location: 5, length: 0))
        proxy.nilAtEmptyContext = true
        let edits = WordEditingSession()
        XCTAssertTrue(edits.deleteWord(in: proxy)); XCTAssertEqual(proxy.editor.text, "")
        XCTAssertTrue(edits.restoreWord(in: proxy)); XCTAssertEqual(proxy.editor.text, "hello")
    }
}

@MainActor final class EditingSwipeTests: XCTestCase {
    private func descendants(_ view: UIView) -> [UIView] { view.subviews.flatMap { [$0] + descendants($0) } }
    private func key(_ value: String, _ keyboard: KeyboardViewController) throws -> KeyControl {
        try XCTUnwrap(descendants(keyboard.view).compactMap { $0 as? KeyControl }.first { $0.value == value })
    }
    private func withKeyboard(language: KeyboardLanguage = .english,
                              _ body: (KeyboardViewController, TextViewProxy) async throws -> Void) async throws {
        let previous = UserDefaults.standard.string(forKey: KeyboardLanguage.preferenceKey)
        let previousMode = UserDefaults.standard.object(forKey: KeyboardLayoutMode.preferenceKey)
        KeyboardLayoutMode.full.save()
        language.save()
        await withCheckedContinuation { c in PinyinEngine.shared.perform(.clear) { _ in c.resume() } }
        let keyboard = KeyboardViewController(), proxy = TextViewProxy("hello world", selection: NSRange(location: 11, length: 0))
        keyboard.testingDocumentProxy = proxy; keyboard.testingVoiceAvailable = true; keyboard.testingLandscape = false
        keyboard.loadViewIfNeeded(); keyboard.view.frame = CGRect(x: 0, y: 0, width: 466, height: KeyboardMetrics(width: 466).contentHeight)
        keyboard.viewDidLayoutSubviews(); keyboard.view.layoutIfNeeded()
        await withCheckedContinuation { c in PinyinEngine.shared.perform(.prepare) { _ in c.resume() } }
        defer {
            keyboard.viewWillDisappear(false)
            if let previousMode { UserDefaults.standard.set(previousMode, forKey: KeyboardLayoutMode.preferenceKey) }
            else { UserDefaults.standard.removeObject(forKey: KeyboardLayoutMode.preferenceKey) }
            if let previous { UserDefaults.standard.set(previous, forKey: KeyboardLanguage.preferenceKey) }
            else { UserDefaults.standard.removeObject(forKey: KeyboardLanguage.preferenceKey) }
        }
        try await body(keyboard, proxy)
    }
    private func swipe(_ key: KeyControl, dx: CGFloat = 0, dy: CGFloat = 0) {
        let point = CGPoint(x: key.bounds.midX, y: key.bounds.midY)
        XCTAssertTrue(key.press(at: 10, point: point))
        XCTAssertTrue(key.movePress(to: CGPoint(x: point.x + dx, y: point.y + dy), at: 10.15))
        key.advancePress(to: 12); key.releasePress()
    }
    private func pill(_ keyboard: KeyboardViewController, _ action: KeyboardEditSwipe) throws {
        let control = try XCTUnwrap(descendants(keyboard.view).compactMap { $0 as? GesturePill }.first)
        control.onBegin?(); control.onAction?(action)
    }
    func testPillDeletesRestoresAndInsertsLineWithoutSending() async throws {
        try await withKeyboard { keyboard, proxy in
            try pill(keyboard, .deleteWord); XCTAssertEqual(proxy.editor.text, "hello ")
            try pill(keyboard, .restoreWord); XCTAssertEqual(proxy.editor.text, "hello world")
            try pill(keyboard, .restoreWord); XCTAssertEqual(proxy.editor.text, "hello world")
            proxy.returnKeyType = .send
            try pill(keyboard, .lineBreak); XCTAssertEqual(proxy.editor.text, "hello world\u{2028}")
            XCTAssertTrue(keyboard.testingVoiceCommands.isEmpty)
        }
    }
    func testKeySwipesNoLongerDeleteOrInsertLines() async throws {
        try await withKeyboard { keyboard, proxy in
            for value in ["a", "delete", "space", "return"] { XCTAssertNil(try key(value, keyboard).onEditSwipe) }
            swipe(try key("a", keyboard), dx: -48)
            XCTAssertEqual(proxy.editor.text, "hello worlda")
            XCTAssertTrue(keyboard.testingVoiceCommands.isEmpty)
        }
    }
    func testPillRejectsChangedDestinationAndTypedTextInvalidatesUndo() async throws {
        try await withKeyboard { keyboard, proxy in
            let control = try XCTUnwrap(descendants(keyboard.view).compactMap { $0 as? GesturePill }.first)
            control.onBegin?(); proxy.documentIdentifier = UUID(); control.onAction?(.deleteWord)
            XCTAssertEqual(proxy.editor.text, "hello world")
            try pill(keyboard, .deleteWord)
            _ = try key("b", keyboard).accessibilityActivate()
            try pill(keyboard, .restoreWord); XCTAssertEqual(proxy.editor.text, "hello b")
        }
    }
    func testChineseCompositionCommitsBeforePillLineBreak() async throws {
        try await withKeyboard(language: .chinese) { keyboard, proxy in
            for value in "haode" { _ = try key(String(value), keyboard).accessibilityActivate() }
            for _ in 0..<100 { if proxy.editor.text.hasSuffix("haode") { break }; try await Task.sleep(for: .milliseconds(10)) }
            try pill(keyboard, .lineBreak)
            for _ in 0..<100 { if proxy.editor.text.hasSuffix("好的\u{2028}") { break }; try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(proxy.editor.text.hasSuffix("好的\u{2028}"))
        }
    }
    func testEndOfTextMovesInAcknowledgedChunks() {
        let text = String(repeating: "word ", count: 70)
        let proxy = TextViewProxy(text, selection: NSRange(location: 10, length: 0))
        let cursor = CursorDragSession(proxy: proxy, point: .zero)
        for _ in 0..<20 { if !cursor.advanceToEnd(in: proxy) { break } }
        XCTAssertEqual(proxy.editor.selectedRange.location, text.utf16.count)
    }
}
