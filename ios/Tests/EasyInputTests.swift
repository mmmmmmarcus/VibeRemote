import XCTest
import UIKit
@testable import vvhisper

final class VerificationCodeTests: XCTestCase {
    func testExtractsSingleExplicitlyCopiedCodeWithoutGuessingAmbiguousMessages() {
        for (text, code) in [("123456", "123456"), ("123 456", "123456"), ("A1B2C3", "A1B2C3"),
                             ("验证码：482913，5分钟内有效。", "482913"), ("Your verification code is 123-456.", "123456"),
                             ("Your code: X1Y2Z3", "X1Y2Z3")] {
            XCTAssertEqual(VerificationCode.extract(from: text), code)
        }
        for text in ["", "nothing here", "Meet me in 2026", "code: 123456 or 654321", "Your code is 12345678901", String(repeating: "x", count: 4097)] {
            XCTAssertNil(VerificationCode.extract(from: text), text)
        }
    }
}

@MainActor final class EasyInputTests: XCTestCase {
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
        await withCheckedContinuation { continuation in PinyinEngine.shared.perform(.clear) { _ in continuation.resume() } }
        let keyboard = KeyboardViewController(), proxy = TextViewProxy("", selection: NSRange(location: 0, length: 0))
        keyboard.testingDocumentProxy = proxy; keyboard.testingVoiceAvailable = true
        keyboard.loadViewIfNeeded()
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
    func testChinesePunctuationCapsInsertChineseAndKeepLatinAlternatives() async throws {
        try await withKeyboard(language: .chinese) { keyboard, proxy in
            for value in ["，", "。", "？", "！", "：", "；", "（", "）", "「", "」", "、"] {
                _ = try key("123", keyboard).accessibilityActivate(); keyboard.view.layoutIfNeeded()
                _ = try key(value, keyboard).accessibilityActivate()
                XCTAssertNotNil(try key("q", keyboard))
            }
            XCTAssertEqual(proxy.editor.text, "，。？！：；（）「」、")
            for (latin, chinese) in KeyboardSymbols.chinese {
                XCTAssertEqual(KeyboardSymbols.key(latin, language: .chinese), chinese)
                XCTAssertEqual(KeyboardSymbols.key(latin, language: .english), latin)
                let choices = KeyboardSymbols.alternatives(for: chinese)
                XCTAssertEqual(choices.first, chinese)
                XCTAssertTrue(choices.contains(latin), latin)
                XCTAssertEqual(Set(choices).count, choices.count)
            }
        }
    }
    func testURLFieldsKeepASCIIAndPasteDoesNotConvertPunctuation() async throws {
        try await withKeyboard(language: .chinese) { keyboard, proxy in
            proxy.keyboardType = .URL
            _ = try key("123", keyboard).accessibilityActivate(); keyboard.view.layoutIfNeeded()
            XCTAssertNotNil(try key(".", keyboard)); XCTAssertNotNil(try key("/", keyboard))
            let request = try XCTUnwrap(keyboard.beginPaste(codeOnly: false))
            keyboard.completePaste("https://example.com/?a=1,b=2", request: request)
            XCTAssertEqual(proxy.editor.text, "https://example.com/?a=1,b=2")
        }
    }
    func testHelpersOnlyOccupyEmptyCandidateStrip() async throws {
        try await withKeyboard(language: .chinese) { keyboard, _ in
            let helpers = try XCTUnwrap(descendants(keyboard.view).first { $0.accessibilityIdentifier == "keyboard.input-helpers" })
            XCTAssertFalse(helpers.isHidden)
            (descendants(helpers).first { $0.accessibilityIdentifier == "keyboard.shortcut-pill" } as? UIButton)?.sendActions(for: .touchUpInside)
            keyboard.view.layoutIfNeeded()
            for id in ["keyboard.paste", "keyboard.paste-code", "keyboard.open-1password"] {
                XCTAssertNotNil(descendants(helpers).first { $0.accessibilityIdentifier == id })
            }
            let password = try XCTUnwrap(descendants(helpers).first { $0.accessibilityIdentifier == "keyboard.open-1password" } as? UIButton)
            let paste = try XCTUnwrap(descendants(helpers).first { $0.accessibilityIdentifier == "keyboard.paste" } as? UIButton)
            XCTAssertNil(paste.configuration?.title); XCTAssertNotNil(paste.configuration?.image)
            XCTAssertEqual(paste.configuration?.background.backgroundColor, .clear)
            XCTAssertNil(password.configuration?.title); XCTAssertNotNil(password.configuration?.image)
            XCTAssertEqual(password.configuration?.image?.renderingMode, .alwaysTemplate)
            XCTAssertEqual(paste.configuration?.image?.size, CGSize(width: 20, height: 20))
            XCTAssertEqual(password.configuration?.image?.size, paste.configuration?.image?.size)
            XCTAssertLessThan(password.convert(password.bounds, to: helpers).midX, helpers.bounds.width)
            XCTAssertTrue(try XCTUnwrap(descendants(helpers).first { $0.accessibilityIdentifier == "keyboard.paste-code" }).isHidden)
            _ = try key("n", keyboard).accessibilityActivate()
            XCTAssertFalse(helpers.isHidden); XCTAssertNil(keyboard.beginPaste(codeOnly: false))
        }
    }
    func testPasteGuardsFieldChangesTypingAndDuplicateCallbacks() async throws {
        try await withKeyboard { keyboard, proxy in
            var request = try XCTUnwrap(keyboard.beginPaste(codeOnly: false))
            proxy.documentIdentifier = UUID()
            keyboard.completePaste("wrong field", request: request)
            XCTAssertEqual(proxy.editor.text, "")
            request = try XCTUnwrap(keyboard.beginPaste(codeOnly: false))
            _ = try key("a", keyboard).accessibilityActivate()
            keyboard.completePaste("late text", request: request)
            XCTAssertEqual(proxy.editor.text, "a")
            request = try XCTUnwrap(keyboard.beginPaste(codeOnly: false))
            keyboard.completePaste(" pasted", request: request); keyboard.completePaste(" pasted", request: request)
            XCTAssertEqual(proxy.editor.text, "a pasted")
            request = try XCTUnwrap(keyboard.beginPaste(codeOnly: false))
            keyboard.setMiniMode(true); keyboard.completePaste("late", request: request)
            XCTAssertEqual(proxy.editor.text, "a pasted")
        }
    }
    func testNewCopiedCodeIconPastesOnceAndHidesAfterUseOrClipboardChange() async throws {
        try await withKeyboard { keyboard, proxy in
            (descendants(keyboard.view).first { $0.accessibilityIdentifier == "keyboard.shortcut-pill" } as? UIButton)?.sendActions(for: .touchUpInside)
            let board = TestCodeClipboard()
            keyboard.copiedCodes = CopiedCodeMonitor(clipboard: board, defaults: nil, bootTime: { 100 })
            let button = try XCTUnwrap(descendants(keyboard.view).first { $0.accessibilityIdentifier == "keyboard.paste-code" } as? UIButton)
            keyboard.copiedCodes.refresh(); keyboard.refreshCopiedCodeIndicator(); XCTAssertTrue(button.isHidden)
            board.copy("Your code: 482913")
            keyboard.copiedCodes.refresh(); keyboard.refreshCopiedCodeIndicator(); keyboard.view.layoutIfNeeded()
            XCTAssertFalse(button.isHidden); XCTAssertNil(button.configuration?.title)
            XCTAssertGreaterThan(button.convert(button.bounds, to: keyboard.view).midX, 44)
            keyboard.pasteCopiedCode()
            XCTAssertEqual(proxy.editor.text, "482913"); XCTAssertTrue(button.isHidden)
            keyboard.pasteCopiedCode(); XCTAssertEqual(proxy.editor.text, "482913")
            board.copy("Your code: 827461"); keyboard.copiedCodes.refresh(); keyboard.refreshCopiedCodeIndicator()
            board.copy("changed text"); keyboard.pasteCopiedCode()
            XCTAssertTrue(button.isHidden); XCTAssertEqual(proxy.editor.text, "482913")
        }
    }
    func testNativePasteProviderExtractsCodeInOneTimeCodeField() async throws {
        try await withKeyboard { keyboard, proxy in
            proxy.textContentType = .oneTimeCode
            keyboard.paste(itemProviders: [NSItemProvider(object: "Your code is 827461" as NSString)])
            for _ in 0..<300 {
                if proxy.editor.text == "827461" { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(proxy.editor.text, "827461")
        }
    }
}
