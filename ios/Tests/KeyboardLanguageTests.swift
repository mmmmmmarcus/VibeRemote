import XCTest
import UIKit
@testable import vvhisper

@MainActor
final class KeyboardLanguageTests: XCTestCase {
    private func controls(in view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + controls(in: $0) }
    }
    private func control(_ id: String, in keyboard: KeyboardViewController) -> UIView? {
        controls(in: keyboard.view).first { $0.accessibilityIdentifier == id }
    }
    private func tap(_ value: String, in keyboard: KeyboardViewController) throws {
        let key = try XCTUnwrap(control("keyboard.key.\(value)", in: keyboard) as? KeyControl)
        XCTAssertTrue(key.accessibilityActivate())
    }
    private func type(_ text: String, in keyboard: KeyboardViewController) throws {
        for character in text { try tap(character == " " ? "space" : String(character), in: keyboard) }
    }
    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), file: file, line: line)
    }
    private func withKeyboard(_ language: KeyboardLanguage,
                              _ body: (KeyboardViewController, TextViewProxy) async throws -> Void) async throws {
        let previous = UserDefaults.standard.string(forKey: KeyboardLanguage.preferenceKey)
        language.save()
        await withCheckedContinuation { continuation in
            PinyinEngine.shared.perform(.clear) { _ in continuation.resume() }
        }
        let proxy = TextViewProxy("", selection: NSRange(location: 0, length: 0))
        let keyboard = KeyboardViewController()
        keyboard.testingDocumentProxy = proxy
        keyboard.loadViewIfNeeded()
        keyboard.applyKeyboardPreferences(KeyboardPreferences())
        keyboard.view.frame = CGRect(x: 0, y: 0, width: 466, height: 320)
        keyboard.viewDidLayoutSubviews()
        defer {
            keyboard.viewWillDisappear(false)
            if let previous { UserDefaults.standard.set(previous, forKey: KeyboardLanguage.preferenceKey) }
            else { UserDefaults.standard.removeObject(forKey: KeyboardLanguage.preferenceKey) }
        }
        try await body(keyboard, proxy)
    }

    func testEnglishInsertsDirectlyWithoutChineseCandidatesOrMarkedText() async throws {
        try await withKeyboard(.english) { keyboard, proxy in
            try type("haode wozhidaole hello world meeting", in: keyboard)
            XCTAssertEqual(proxy.editor.text, "haode wozhidaole hello world meeting")
            XCTAssertNil(proxy.editor.markedTextRange)
            XCTAssertNil(control("candidate.0", in: keyboard))
            try tap("return", in: keyboard)
            XCTAssertTrue(proxy.editor.text.hasSuffix("\n"))
            let delete = try XCTUnwrap(control("keyboard.key.delete", in: keyboard) as? KeyControl)
            delete.press(at: 0, point: .zero); delete.advancePress(to: 0.4)
            delete.advancePress(to: 0.5); delete.releasePress()
            XCTAssertTrue(proxy.editor.text.hasSuffix("meetin"))
            XCTAssertEqual(proxy.backspaces, 2)
        }
    }

    func testChineseInlineCompositionAndSpaceCommitRemainChinese() async throws {
        try await withKeyboard(.chinese) { keyboard, proxy in
            try type("wozhidaole", in: keyboard)
            try await waitUntil { control("candidate.0", in: keyboard)?.accessibilityLabel == "我知道了" }
            XCTAssertNotNil(proxy.editor.markedTextRange)
            XCTAssertNil(control("candidate.english", in: keyboard))
            try tap("space", in: keyboard)
            try await waitUntil { proxy.editor.text == "我知道了" && proxy.editor.markedTextRange == nil }
        }
    }

    func testSwitchPreservesVisibleSpellingAndAllowsChineseAgain() async throws {
        try await withKeyboard(.chinese) { keyboard, proxy in
            try type("nihao", in: keyboard)
            try await waitUntil { control("candidate.0", in: keyboard)?.accessibilityLabel == "你好" }
            let visibleSpelling = proxy.editor.text!
            try tap("language", in: keyboard)
            XCTAssertEqual(control("keyboard.key.language", in: keyboard)?.accessibilityLabel, "English")
            XCTAssertEqual(proxy.editor.text, visibleSpelling)
            XCTAssertNil(proxy.editor.markedTextRange)
            try type(" hello ", in: keyboard)
            XCTAssertEqual(proxy.editor.text, visibleSpelling + " hello ")
            try tap("language", in: keyboard)
            try type("haode", in: keyboard); try tap("space", in: keyboard)
            try await waitUntil { proxy.editor.text == visibleSpelling + " hello 好的" }
            XCTAssertEqual(control("keyboard.key.language", in: keyboard)?.accessibilityLabel, "Chinese")
        }
    }

    func testSwitchQueuedDuringPinyinPreservesSubsequentEnglishTaps() async throws {
        try await withKeyboard(.chinese) { keyboard, proxy in
            try type("ni", in: keyboard)
            try tap("language", in: keyboard)
            try type("hello", in: keyboard)
            try await waitUntil { proxy.editor.text == "nihello" }
            XCTAssertEqual(control("keyboard.key.language", in: keyboard)?.accessibilityLabel, "English")
            XCTAssertNil(proxy.editor.markedTextRange)
            XCTAssertNil(control("candidate.0", in: keyboard))
            XCTAssertEqual(KeyboardLanguage.load(), .english)
            let reopened = KeyboardViewController()
            reopened.testingDocumentProxy = proxy
            reopened.loadViewIfNeeded()
            XCTAssertEqual(control("keyboard.key.language", in: reopened)?.accessibilityLabel, "English")
        }
    }

    func testSwitchIsAvailableBesideEmojiOnSymbolPages() async throws {
        try await withKeyboard(.chinese) { keyboard, _ in
            try tap("123", in: keyboard)
            try await waitUntil { control("keyboard.key.#+=", in: keyboard) != nil }
            try tap("#+=", in: keyboard)
            let language = try XCTUnwrap(control("keyboard.key.language", in: keyboard))
            let emoji = try XCTUnwrap(control("keyboard.key.globe", in: keyboard))
            let row = try XCTUnwrap(language.superview as? UIStackView)
            let index = try XCTUnwrap(row.arrangedSubviews.firstIndex(of: language))
            XCTAssertTrue(row.arrangedSubviews[index + 1] === emoji)
            try tap("language", in: keyboard)
            XCTAssertNotNil(control("keyboard.key.a", in: keyboard))
            XCTAssertEqual(control("keyboard.key.language", in: keyboard)?.accessibilityLabel, "English")
        }
    }

    func testLanguagePreferenceDefaultsToChineseAndPersistsIndependently() throws {
        let suite = "vvhisper-language-test-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(KeyboardLanguage.load(from: defaults), .chinese)
        KeyboardLanguage.english.save(to: defaults)
        XCTAssertEqual(KeyboardLanguage.load(from: defaults), .english)
        defaults.set("mixed", forKey: KeyboardLanguage.preferenceKey)
        XCTAssertEqual(KeyboardLanguage.load(from: defaults), .chinese)
    }

    func testExperimentKeepsEnglishModeDirectAndLanguageSwitchAvailable() async throws {
        try await withKeyboard(.english) { keyboard, proxy in
            keyboard.applyKeyboardPreferences(KeyboardPreferences(mixedTypingEnabled: true))
            try type("haode hello ", in: keyboard)
            XCTAssertEqual(proxy.editor.text, "haode hello ")
            XCTAssertNil(proxy.editor.markedTextRange)
            XCTAssertNil(control("candidate.0", in: keyboard))
            try tap("language", in: keyboard)
            let key = try XCTUnwrap(control("keyboard.key.language", in: keyboard) as? KeyControl)
            XCTAssertEqual(key.label.text, "中英")
            XCTAssertEqual(key.accessibilityLabel, "Mixed Chinese and English")
            try type("haode ", in: keyboard)
            try await waitUntil { proxy.editor.text == "haode hello 好的" }
            XCTAssertNil(control("candidate.english", in: keyboard))
            keyboard.applyKeyboardPreferences(KeyboardPreferences())
            XCTAssertEqual(key.label.text, "中")
            XCTAssertEqual(KeyboardLanguage.load(), .chinese)
        }
    }

    func testEnablingExperimentKeepsCurrentWordAndAppliesToNextWord() async throws {
        try await withKeyboard(.chinese) { keyboard, proxy in
            try type("haode", in: keyboard)
            try await waitUntil { control("candidate.0", in: keyboard)?.accessibilityLabel == "好的" }
            let spelling = proxy.editor.text
            keyboard.applyKeyboardPreferences(KeyboardPreferences(mixedTypingEnabled: true))
            XCTAssertEqual(proxy.editor.text, spelling)
            XCTAssertNotNil(proxy.editor.markedTextRange)
            XCTAssertNil(control("candidate.english", in: keyboard))
            try tap("space", in: keyboard)
            try await waitUntil { proxy.editor.text == "好的" && proxy.editor.markedTextRange == nil }
            try tap("shift", in: keyboard)
            try type("can", in: keyboard)
            try await waitUntil { control("candidate.english", in: keyboard)?.accessibilityLabel == "Can" }
            XCTAssertNotNil(control("candidate.0", in: keyboard))
            XCTAssertTrue(control("candidate.english", in: keyboard)?.accessibilityTraits.contains(.selected) == true)
            try tap("space", in: keyboard)
            try await waitUntil { proxy.editor.text == "好的Can " && proxy.editor.markedTextRange == nil }
        }
    }

    func testDisablingDuringPendingTypingPreservesQueuedMixedWordThenRestoresChinese() async throws {
        try await withKeyboard(.chinese) { keyboard, proxy in
            keyboard.applyKeyboardPreferences(KeyboardPreferences(mixedTypingEnabled: true))
            // Wait for startup so the first key starts a composition immediately.
            try type("a", in: keyboard)
            try await waitUntil { control("candidate.0", in: keyboard) != nil }
            try tap("delete", in: keyboard)
            try await waitUntil { proxy.editor.text.isEmpty && proxy.editor.markedTextRange == nil }
            try tap("shift", in: keyboard)
            try type("can", in: keyboard)
            keyboard.applyKeyboardPreferences(KeyboardPreferences())
            try tap("space", in: keyboard)
            try await waitUntil { proxy.editor.text == "Can " && proxy.editor.markedTextRange == nil }
            try type("haode", in: keyboard)
            try await waitUntil { control("candidate.0", in: keyboard)?.accessibilityLabel == "好的" }
            XCTAssertNil(control("candidate.english", in: keyboard))
            XCTAssertEqual((control("keyboard.key.language", in: keyboard) as? KeyControl)?.label.text, "中")
            try tap("space", in: keyboard)
            try await waitUntil { proxy.editor.text == "Can 好的" }
        }
    }
}
