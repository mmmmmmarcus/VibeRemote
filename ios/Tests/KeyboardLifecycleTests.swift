import XCTest
import UIKit
@testable import vvhisper

@MainActor private final class NullableDocument: NSObject {
    @objc var documentIdentifier: NSUUID?
}

@MainActor final class KeyboardLifecycleTests: XCTestCase {
    func testNativePunctuationRowsKeepASCIIAndBothCornerQuotes() {
        let chinese = KeyboardSymbols.rows(page: 1, language: .chinese)
        XCTAssertEqual(chinese[1], ["-", "/", "：", "；", "（", "）", "$", "@", "「", "」"])
        XCTAssertEqual(chinese[2], ["#+=", "。", "，", "、", "？", "！", ".", "delete"])
        let more = KeyboardSymbols.rows(page: 2, language: .chinese)
        XCTAssertEqual(more[0], ["【", "】", "｛", "｝", "#", "%", "^", "*", "+", "="])
        XCTAssertEqual(more[1], ["_", "—", "\\", "｜", "～", "《", "》", "€", "&", "·"])
        XCTAssertTrue(more[2].contains("kaomoji"))
        XCTAssertEqual(KeyboardSymbols.rows(page: 1, language: .english)[1], ["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""])
        XCTAssertTrue(KeyboardSymbols.alternatives(for: "\"").contains("「"))
        XCTAssertTrue(KeyboardSymbols.alternatives(for: "'").contains("」"))
    }
    func testNullablePublicGetterDoesNotForceBridgeOrReuseIdentity() {
        let detached = NullableDocument()
        XCTAssertNil(KeyboardDocumentIdentity.read(detached))
        let id = UUID(); detached.documentIdentifier = id as NSUUID
        XCTAssertEqual(KeyboardDocumentIdentity.read(detached), id)
        detached.documentIdentifier = nil
        XCTAssertNil(KeyboardDocumentIdentity.read(detached))
        let proxy = TextViewProxy("", selection: .init(location: 0, length: 0))
        XCTAssertEqual(KeyboardDocumentIdentity.snapshot(proxy), proxy.documentIdentifier)
    }
    func testDisappearanceAndLateCallbacksNeverReadDetachedProxy() {
        let keyboard = KeyboardViewController()
        let proxy = TextViewProxy("", selection: .init(location: 0, length: 0))
        keyboard.testingDocumentProxy = proxy; keyboard.loadViewIfNeeded()
        // Real UIKit supplies a proxy with a nil UUID once detached. Returning
        // no testing proxy exercises that actual host-less UIKit implementation.
        keyboard.testingDocumentProxy = nil
        keyboard.viewWillDisappear(false)
        keyboard.textDidChange(nil); keyboard.selectionDidChange(nil)
    }
    func testRepeatedEmojiRoundTripsAndZeroSizeLayout() async throws {
        let saved = UserDefaults.standard.object(forKey: KeyboardLayoutMode.preferenceKey)
        KeyboardLayoutMode.full.save()
        defer { UserDefaults.standard.set(saved, forKey: KeyboardLayoutMode.preferenceKey) }
        let keyboard = KeyboardViewController()
        keyboard.testingDocumentProxy = TextViewProxy("", selection: .init(location: 0, length: 0))
        keyboard.loadViewIfNeeded()
        await withCheckedContinuation { continuation in PinyinEngine.shared.perform(.clear) { _ in continuation.resume() } }
        defer { keyboard.viewWillDisappear(false) }
        func descendants(_ view: UIView) -> [UIView] { view.subviews.flatMap { [$0] + descendants($0) } }
        for width: CGFloat in [466, 655, 956, 466] {
            keyboard.view.frame = CGRect(x: 0, y: 0, width: width, height: KeyboardMetrics(width: width).contentHeight)
            keyboard.viewDidLayoutSubviews(); keyboard.view.layoutIfNeeded()
            for _ in 0..<5 {
                let smile = try XCTUnwrap(descendants(keyboard.view).first { $0.accessibilityIdentifier == "keyboard.key.globe" } as? UIButton)
                smile.sendActions(for: .touchUpInside); keyboard.view.layoutIfNeeded()
                XCTAssertTrue(keyboard.showingEmoji)
                let close = try XCTUnwrap(descendants(keyboard.view).first { $0.accessibilityIdentifier == "emoji.close" } as? UIButton)
                close.sendActions(for: .touchUpInside); keyboard.view.layoutIfNeeded()
                XCTAssertFalse(keyboard.showingEmoji)
            }
        }
        let panel = EmojiPanel(frame: .zero)
        let grid = try XCTUnwrap(panel.subviews.compactMap { $0 as? UICollectionView }.first)
        let size = panel.collectionView(grid, layout: grid.collectionViewLayout, sizeForItemAt: IndexPath(item: 0, section: 0))
        XCTAssertGreaterThan(size.width, 0)
    }
    func testRecordingFadesOnlyBaseFillAndRestoresIt() {
        let key = KeyControl(frame: .init(x: 0, y: 0, width: 44, height: 44))
        key.overrideUserInterfaceStyle = .light
        key.quietFeedback.setRecording(true, dimBase: true, mini: false)
        XCTAssertEqual(key.quietFeedback.baseOpacity, 0.22)
        XCTAssertEqual(key.alpha, 1); XCTAssertEqual(key.icon.alpha, 1)
        key.quietFeedback.setLevel(1, position: 0.5)
        XCTAssertGreaterThan(key.quietFeedback.brightness, 0.8)
        key.quietFeedback.reset(animated: false)
        XCTAssertEqual(key.quietFeedback.baseOpacity, 1)
        XCTAssertEqual(key.layer.backgroundColor?.alpha ?? 0, 0.96, accuracy: 0.01)
    }
    func testActionReturnContrastSurvivesVoiceFeedbackAndFieldChanges() async throws {
        let keyboard = KeyboardViewController()
        let proxy = TextViewProxy("", selection: .init(location: 0, length: 0))
        keyboard.testingDocumentProxy = proxy; keyboard.loadViewIfNeeded()
        await withCheckedContinuation { continuation in PinyinEngine.shared.perform(.clear) { _ in continuation.resume() } }
        defer { keyboard.viewWillDisappear(false) }
        func descendants(_ view: UIView) -> [UIView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let key = try XCTUnwrap(descendants(keyboard.view).compactMap { $0 as? KeyControl }.first { $0.value == "return" })
        for type in [UIReturnKeyType.send, .search, .go, .done, .next, .continue, .default] {
            proxy.returnKeyType = type; keyboard.textDidChange(nil)
            XCTAssertEqual(key.isPrimaryAction, type != .default)
            for style in [UIUserInterfaceStyle.light, .dark] {
                let traits = UITraitCollection(userInterfaceStyle: style)
                let expected = type == .default ? KeyboardMetrics.keyFill.resolvedColor(with: traits) : (style == .dark ? UIColor.white : .black)
                key.quietFeedback.setRecording(true, dimBase: false, mini: false)
                key.quietFeedback.setLevel(1, position: 0.5)
                key.dictationFeedback = .send
                XCTAssertEqual(key.backgroundColor, .systemBlue)
                key.dictationFeedback = nil
                key.quietFeedback.reset(animated: false)
                XCTAssertEqual(key.backgroundColor?.resolvedColor(with: traits), expected)
                if type != .default {
                    XCTAssertEqual(key.label.textColor.resolvedColor(with: traits), style == .dark ? .black : .white)
                    XCTAssertEqual(key.quietFeedback.brightness, 0)
                }
            }
        }
    }
}
