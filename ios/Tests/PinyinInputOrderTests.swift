import XCTest
import UIKit
@testable import vvhisper

/// Digits and punctuation typed after a Pinyin spelling must land after it,
/// including in hosts that coalesce a main-loop turn's proxy output and apply
/// insertions before marked-text writes (owner report: "B03" became "0B3").
@MainActor
final class PinyinInputOrderTests: XCTestCase {
    private func descendants(_ view: UIView) -> [UIView] { view.subviews.flatMap { [$0] + descendants($0) } }
    private func key(_ value: String, _ keyboard: KeyboardViewController) -> KeyControl? {
        descendants(keyboard.view).compactMap { $0 as? KeyControl }.first { $0.value == value && !$0.isHidden }
    }
    private func tap(_ value: String, _ keyboard: KeyboardViewController,
                     file: StaticString = #filePath, line: UInt = #line) async throws {
        try await waitUntil(file: file, line: line) { self.key(value, keyboard) != nil }
        let control = try XCTUnwrap(key(value, keyboard), "missing key \(value)", file: file, line: line)
        XCTAssertTrue(control.accessibilityActivate(), file: file, line: line)
        keyboard.view.layoutIfNeeded()
    }
    private func waitUntil(file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), file: file, line: line)
    }
    private func settle(_ proxy: TextViewProxy) async throws {
        // Let pending Pinyin completions and coalesced host output apply.
        try await Task.sleep(for: .milliseconds(150))
        proxy.flushTurnOutput()
    }

    private func withKeyboard(coalesced: Bool,
                              _ body: (KeyboardViewController, TextViewProxy) async throws -> Void) async throws {
        let previous = UserDefaults.standard.string(forKey: KeyboardLanguage.preferenceKey)
        let previousMode = UserDefaults.standard.object(forKey: KeyboardLayoutMode.preferenceKey)
        KeyboardLayoutMode.full.save()
        KeyboardLanguage.chinese.save()
        await withCheckedContinuation { continuation in PinyinEngine.shared.perform(.clear) { _ in continuation.resume() } }
        let keyboard = KeyboardViewController(), proxy = TextViewProxy("", selection: NSRange(location: 0, length: 0))
        proxy.coalescesTurnOutput = coalesced
        // Real proxies were observed to exclude marked text from surrounding context.
        proxy.excludesMarkedContext = coalesced
        keyboard.testingDocumentProxy = proxy
        keyboard.loadViewIfNeeded()
        keyboard.applyKeyboardPreferences(KeyboardPreferences())
        keyboard.view.frame = CGRect(x: 0, y: 0, width: 466, height: KeyboardMetrics(width: 466).contentHeight)
        keyboard.viewDidLayoutSubviews(); keyboard.view.layoutIfNeeded()
        await withCheckedContinuation { continuation in PinyinEngine.shared.perform(.prepare) { _ in continuation.resume() } }
        defer {
            keyboard.viewWillDisappear(false)
            if let previousMode { UserDefaults.standard.set(previousMode, forKey: KeyboardLayoutMode.preferenceKey) }
            else { UserDefaults.standard.removeObject(forKey: KeyboardLayoutMode.preferenceKey) }
            if let previous { UserDefaults.standard.set(previous, forKey: KeyboardLanguage.preferenceKey) }
            else { UserDefaults.standard.removeObject(forKey: KeyboardLanguage.preferenceKey) }
        }
        try await body(keyboard, proxy)
    }

    private func forEachHost(_ body: (KeyboardViewController, TextViewProxy) async throws -> Void) async throws {
        for coalesced in [false, true] { try await withKeyboard(coalesced: coalesced, body) }
    }

    func testShiftedLetterThenDigitsKeepTypingOrder() async throws {
        try await forEachHost { keyboard, proxy in
            try await tap("shift", keyboard); try await tap("b", keyboard)
            try await waitUntil { proxy.editor.text == "B" && proxy.editor.markedTextRange != nil }
            try await tap("123", keyboard); try await tap("0", keyboard)
            try await settle(proxy)
            XCTAssertEqual(proxy.editor.text, "B0")
            try await tap("3", keyboard)
            try await settle(proxy)
            XCTAssertEqual(proxy.editor.text, "B03")
            XCTAssertNil(proxy.editor.markedTextRange)
            XCTAssertEqual(proxy.editor.selectedRange, NSRange(location: 3, length: 0))
        }
    }

    func testDigitsQueuedBehindCommitKeepTypingOrder() async throws {
        try await forEachHost { keyboard, proxy in
            try await tap("shift", keyboard); try await tap("b", keyboard)
            try await tap("123", keyboard)
            try await tap("0", keyboard); try await tap("3", keyboard)
            try await settle(proxy)
            XCTAssertEqual(proxy.editor.text, "B03")
            XCTAssertNil(proxy.editor.markedTextRange)
        }
    }

    func testLowercaseLetterThenDigits() async throws {
        try await forEachHost { keyboard, proxy in
            try await tap("b", keyboard)
            try await waitUntil { proxy.editor.markedTextRange != nil }
            try await tap("123", keyboard); try await tap("0", keyboard)
            try await settle(proxy)
            try await tap("3", keyboard)
            try await settle(proxy)
            XCTAssertEqual(proxy.editor.text, "b03")
            XCTAssertNil(proxy.editor.markedTextRange)
        }
    }

    func testDigitImmediatelyAfterPendingPinyinKey() async throws {
        try await forEachHost { keyboard, proxy in
            try await tap("n", keyboard); try await tap("i", keyboard)
            try await waitUntil { proxy.editor.text == "ni" }
            try await tap("123", keyboard); try await tap("3", keyboard)
            try await settle(proxy)
            XCTAssertEqual(proxy.editor.text, "ni3")
            XCTAssertNil(proxy.editor.markedTextRange)
        }
    }

    func testChinesePunctuationBetweenLetters() async throws {
        try await forEachHost { keyboard, proxy in
            try await tap("a", keyboard)
            try await waitUntil { proxy.editor.markedTextRange != nil }
            try await tap("123", keyboard); try await tap("，", keyboard)
            try await settle(proxy)
            try await tap("b", keyboard)
            try await settle(proxy)
            XCTAssertEqual(proxy.editor.text, "a，b")
            try await tap("return", keyboard)
            try await settle(proxy)
            XCTAssertEqual(proxy.editor.text, "a，b")
            XCTAssertNil(proxy.editor.markedTextRange)
        }
    }

    func testMultiErrorCandidateTapThenDigitCommitsWholeInputInOrder() async throws {
        try await forEachHost { keyboard, proxy in
            // Queue all letters without waiting for Rime; no auto-replacement.
            for letter in "woxhfiaole" { try await tap(String(letter), keyboard) }
            let panel = try XCTUnwrap(descendants(keyboard.view).first { $0 is CandidatePanel } as? CandidatePanel)
            try await waitUntil {
                keyboard.view.layoutIfNeeded(); panel.layoutIfNeeded()
                // Candidate delivery and the coalescing host's marked-text write
                // are separate acknowledgments; wait for both, not a partial spelling.
                return proxy.editor.text.filter(\.isLetter) == "woxhfiaole"
                    && self.descendants(panel).contains { $0.accessibilityLabel == "我知道了" }
            }
            XCTAssertNotNil(proxy.editor.markedTextRange)
            XCTAssertEqual(proxy.editor.text.filter(\.isLetter), "woxhfiaole")
            let candidate = try XCTUnwrap(descendants(panel).first { $0.accessibilityLabel == "我知道了" } as? CandidateButton)
            XCTAssertTrue(candidate.accessibilityActivate())
            try await tap("123", keyboard); try await tap("1", keyboard)
            try await waitUntil { proxy.editor.text == "我知道了1" }
            XCTAssertNil(proxy.editor.markedTextRange)
            XCTAssertEqual(proxy.editor.selectedRange.location, 5)
        }
    }

    func testDigitQueuedBehindCandidateCommit() async throws {
        try await forEachHost { keyboard, proxy in
            for letter in "nihao" { try await tap(String(letter), keyboard) }
            try await waitUntil { proxy.editor.markedTextRange != nil && proxy.editor.text.filter(\.isLetter) == "nihao" }
            try await tap("space", keyboard)
            try await tap("123", keyboard); try await tap("1", keyboard)
            try await settle(proxy)
            XCTAssertEqual(proxy.editor.text, "你好1")
            XCTAssertNil(proxy.editor.markedTextRange)
        }
    }
}
