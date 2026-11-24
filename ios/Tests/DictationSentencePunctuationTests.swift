import XCTest
import UIKit
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
}

@MainActor final class DictationOutputSettingsTests: XCTestCase {
    func testSettingDefaultsOnPersistsAndDoesNotDependOnPolishing() throws {
        let suite = "vvhisper.punctuation-test.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(DictationOutputSettings.load(defaults).sentencePunctuation)
        var polish = DictationPolishSettings(); polish.enabled = false; polish.save(defaults)
        let page = MainSettingsViewController(loadPreferences: { .init() }, savePreferences: { _ in }, outputDefaults: defaults)
        page.loadViewIfNeeded()
        let cell = page.tableView(page.tableView, cellForRowAt: .init(row: 2, section: 0))
        let toggle = try XCTUnwrap(cell.accessoryView as? UISwitch)
        XCTAssertTrue(toggle.isOn); XCTAssertTrue(toggle.isEnabled)
        toggle.isOn = false; toggle.sendActions(for: .valueChanged)
        XCTAssertFalse(DictationOutputSettings.load(defaults).sentencePunctuation)
        XCTAssertFalse(DictationPolishSettings.load(defaults).enabled)
        let reopened = MainSettingsViewController(loadPreferences: { .init() }, savePreferences: { _ in }, outputDefaults: defaults)
        reopened.loadViewIfNeeded()
        let saved = reopened.tableView(reopened.tableView, cellForRowAt: .init(row: 2, section: 0))
        XCTAssertFalse(try XCTUnwrap(saved.accessoryView as? UISwitch).isOn)
    }

    func testHoldSettingsStayLatchedWhenPreferenceChanges() throws {
        let suite = "vvhisper.punctuation-hold.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let held = DictationOutputSettings.load(defaults)
        DictationOutputSettings(sentencePunctuation: false).save(defaults)
        XCTAssertEqual(held.finalize("你好"), "你好。")
        XCTAssertEqual(DictationOutputSettings.load(defaults).finalize("你好。"), "你好")
    }

    func testFinalPolicyRunsAfterSuccessfulDisabledAndFailedPolish() async throws {
        for punctuation in [true, false] {
            let settings = DictationOutputSettings(sentencePunctuation: punctuation)
            let disabled = await DictationPolisher.polish("Hello!", enabled: false, key: nil) { _ in
                XCTFail("Disabled polishing must not make a request"); throw URLError(.badURL)
            }
            XCTAssertEqual(settings.finalize(disabled.text), punctuation ? "Hello!" : "Hello")
            let missing = await DictationPolisher.polish("你好", enabled: true, key: nil) { _ in
                XCTFail("No request without a key"); throw URLError(.badURL)
            }
            XCTAssertEqual(settings.finalize(missing.text), punctuation ? "你好。" : "你好")
            let failed = await DictationPolisher.polish("Hello.", enabled: true, key: "synthetic") { _ in throw URLError(.timedOut) }
            XCTAssertNotNil(failed.notice)
            XCTAssertEqual(settings.finalize(failed.text), punctuation ? "Hello." : "Hello")
            let success = await DictationPolisher.polish("I is ready", enabled: true, key: "synthetic") { request in
                let content = String(data: try JSONSerialization.data(withJSONObject: ["text": "I am ready!"]), encoding: .utf8)!
                let data = try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "stop", "message": ["content": content]]]])
                return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            XCTAssertEqual(settings.finalize(success.text), punctuation ? "I am ready!" : "I am ready")
        }
    }
}
