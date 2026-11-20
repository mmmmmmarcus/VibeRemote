import XCTest
import UIKit
@testable import vvhisper

@MainActor final class CompactKeyboardFeatureTests: XCTestCase {
    private func descendants(_ view: UIView) -> [UIView] { view.subviews.flatMap { [$0] + descendants($0) } }
    private func key(_ value: String, _ keyboard: KeyboardViewController) throws -> KeyControl {
        try XCTUnwrap(descendants(keyboard.view).compactMap { $0 as? KeyControl }.first { $0.value == value })
    }
    private func withKeyboard(_ body: (KeyboardViewController, TextViewProxy) throws -> Void) async rethrows {
        let mode = UserDefaults.standard.object(forKey: KeyboardLayoutMode.preferenceKey)
        let language = UserDefaults.standard.object(forKey: KeyboardLanguage.preferenceKey)
        KeyboardLayoutMode.full.save(); KeyboardLanguage.english.save()
        defer {
            UserDefaults.standard.set(mode, forKey: KeyboardLayoutMode.preferenceKey)
            UserDefaults.standard.set(language, forKey: KeyboardLanguage.preferenceKey)
        }
        let keyboard = KeyboardViewController(), proxy = TextViewProxy("alpha beta gamma", selection: .init(location: 16, length: 0))
        keyboard.testingDocumentProxy = proxy; keyboard.testingVoiceAvailable = true
        keyboard.loadViewIfNeeded()
        await withCheckedContinuation { c in PinyinEngine.shared.perform(.clear) { _ in c.resume() } }
        keyboard.view.frame = CGRect(x: 0, y: 0, width: 466, height: KeyboardMetrics(width: 466).contentHeight)
        keyboard.viewDidLayoutSubviews(); keyboard.view.layoutIfNeeded()
        defer { keyboard.viewWillDisappear(false) }
        try body(keyboard, proxy)
    }
    private func press(_ key: KeyControl) { XCTAssertTrue(key.press(at: 0, point: CGPoint(x: key.bounds.midX, y: key.bounds.midY))) }

    func testMiniDeletesWholeWordsWaitsForAcknowledgementAndExpands() async throws {
        try await withKeyboard { keyboard, proxy in
            keyboard.setMiniMode(true, animated: false)
            keyboard.view.frame.size.height = KeyboardMetrics(width: 466, mini: true).contentHeight
            keyboard.viewDidLayoutSubviews(); keyboard.view.layoutIfNeeded()
            let controls = descendants(keyboard.view).compactMap { $0 as? KeyControl }
            XCTAssertEqual(controls.map(\.value), ["expand", "dictate", "delete", "return"])
            let y = try XCTUnwrap(controls.first).convert(.zero, to: keyboard.view).y
            for key in controls { XCTAssertEqual(key.convert(.zero, to: keyboard.view).y, y, accuracy: 0.1) }
            proxy.defersTextEdits = true
            let delete = try key("delete", keyboard)
            press(delete); delete.advancePress(to: 0.5)
            let backspaces = proxy.backspaces
            XCTAssertEqual(backspaces, 5)
            delete.advancePress(to: 0.7)
            XCTAssertEqual(proxy.backspaces, backspaces, "Do not delete the next word before acknowledgement")
            proxy.flushTextEdits(); keyboard.textDidChange(nil)
            XCTAssertEqual(proxy.editor.text, "alpha beta ")
            delete.advancePress(to: 0.9); proxy.flushTextEdits(); delete.releasePress()
            XCTAssertEqual(proxy.editor.text, "alpha ")
            _ = try key("expand", keyboard).accessibilityActivate()
            XCTAssertFalse(keyboard.isMiniMode); XCTAssertNotNil(try key("a", keyboard))
        }
    }
    func testMiniWordDeletionStopsIfDestinationChangesBeforeRepeat() async throws {
        try await withKeyboard { keyboard, proxy in
            keyboard.setMiniMode(true, animated: false); keyboard.view.layoutIfNeeded()
            let delete = try key("delete", keyboard)
            press(delete); proxy.documentIdentifier = UUID(); delete.advancePress(to: 0.5)
            XCTAssertEqual(proxy.editor.text, "alpha beta gamma"); XCTAssertEqual(proxy.backspaces, 0)
        }
    }
    func testDictationSubmitNeverAddsNewlineToDefaultSearchOrDoneFields() {
        for type in [UIReturnKeyType.default, .search, .done, .go, .send] {
            let proxy = TextViewProxy("", selection: .init(location: 0, length: 0))
            proxy.returnKeyType = type
            let session = DictationTextSession(id: UUID(), proxy: proxy)
            session.finishRecording(submitAfterPolish: true)
            XCTAssertEqual(session.receive(VoiceReply(id: session.id, text: "Ready.", isFinal: true), in: proxy), .finished)
            XCTAssertEqual(proxy.editor.text, type == .send ? "Ready.\n" : "Ready.")
            XCTAssertEqual(session.needsManualSend, type != .send)
            XCTAssertNil(proxy.editor.markedTextRange)
        }
    }
    func testEmojiCatalogHasCategoriesAndPreservesQualifiedSequencesAndTones() throws {
        XCTAssertEqual(EmojiCatalog.categories.count, 9)
        XCTAssertGreaterThan(EmojiCatalog.base.count, 1800)
        XCTAssertEqual(Set(EmojiCatalog.all.map(\.glyph)).count, EmojiCatalog.all.count)
        let hand = try XCTUnwrap(EmojiCatalog.base.first { $0.glyph == "👋" })
        XCTAssertEqual(EmojiCatalog.applying(tone: 3, to: hand).glyph, "👋🏽")
        XCTAssertEqual(EmojiCatalog.applying(tone: 0, to: hand).glyph, "👋")
        let smile = try XCTUnwrap(EmojiCatalog.base.first { $0.glyph == "😀" })
        XCTAssertEqual(EmojiCatalog.applying(tone: 5, to: smile).glyph, "😀")
        XCTAssertTrue(EmojiCatalog.base.contains { $0.glyph == "👨‍👩‍👧‍👦" })
    }
    func testEmojiPanelInsertsWithoutChangingKeyboardAndRejectsStaleSelection() async throws {
        try await withKeyboard { keyboard, proxy in
            let smiley = try XCTUnwrap(descendants(keyboard.view).first { $0.accessibilityIdentifier == "keyboard.key.globe" } as? UIButton)
            smiley.sendActions(for: .touchUpInside); keyboard.view.layoutIfNeeded()
            XCTAssertTrue(keyboard.showingEmoji)
            let panel = try XCTUnwrap(descendants(keyboard.view).compactMap { $0 as? EmojiPanel }.first)
            XCTAssertFalse(panel.isHidden)
            let surface = try XCTUnwrap(descendants(keyboard.view).first { $0 is KeyboardTouchSurface })
            XCTAssertTrue(surface.isHidden)
            panel.onPress?(); panel.onSelect?("👨‍👩‍👧‍👦")
            XCTAssertEqual(proxy.editor.text, "alpha beta gamma👨‍👩‍👧‍👦")
            panel.onPress?(); proxy.documentIdentifier = UUID(); panel.onSelect?("😀")
            XCTAssertEqual(proxy.editor.text, "alpha beta gamma👨‍👩‍👧‍👦")
            panel.onClose?(); XCTAssertFalse(keyboard.showingEmoji); XCTAssertFalse(surface.isHidden)
            XCTAssertNotNil(try key("a", keyboard))
        }
    }
    func testLightFeedbackNeverAddsBlackInkAndHasWhiteHalo() {
        let key = KeyControl(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        key.overrideUserInterfaceStyle = .light
        key.quietFeedback.setRecording(true, dimBase: true, mini: false)
        key.quietFeedback.setLevel(1, position: 0.5)
        key.layoutIfNeeded()
        XCTAssertGreaterThan(key.layer.shadowOpacity, 0.5)
        let shade = key.quietFeedback.layer.sublayers!.first!
        XCTAssertEqual(shade.opacity, 0)
        XCTAssertEqual(key.layer.shadowColor, UIColor.white.cgColor)
        key.quietFeedback.reset(animated: false)
        XCTAssertEqual(key.layer.shadowOpacity, 0)
    }
}
