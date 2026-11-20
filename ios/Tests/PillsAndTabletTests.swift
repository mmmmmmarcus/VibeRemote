import XCTest
import UIKit
@testable import vvhisper

@MainActor final class PillsAndTabletTests: XCTestCase {
    func testDoubleSpaceIsOwnedTimedAndLanguageAware() {
        for language in [KeyboardLanguage.english, .chinese] {
            let proxy = TextViewProxy("hello ", selection: .init(location: 6, length: 0))
            let spaces = DoubleSpacePeriod(); spaces.remember(in: proxy, now: 10)
            XCTAssertTrue(spaces.replaceIfMatching(in: proxy, language: language, now: 10.2))
            XCTAssertEqual(proxy.editor.text, language == .chinese ? "hello。" : "hello. ")
            XCTAssertFalse(spaces.replaceIfMatching(in: proxy, language: language, now: 10.3))
        }
        for variant in 0..<5 {
            let proxy = TextViewProxy("hello ", selection: .init(location: 6, length: 0))
            let spaces = DoubleSpacePeriod(); spaces.remember(in: proxy, now: 10)
            switch variant {
            case 0: proxy.documentIdentifier = UUID()
            case 1: proxy.insertText("changed")
            case 2: proxy.keyboardType = .URL
            case 3: proxy.editor.selectedRange = .init(location: 0, length: 0)
            default: break
            }
            XCTAssertFalse(spaces.replaceIfMatching(in: proxy, language: .english, now: variant == 4 ? 11 : 10.2))
        }
    }
    func testEmptyDictationIsQuietAndDoesNotDeleteSelectionOrSend() {
        let proxy = TextViewProxy("keep this", selection: .init(location: 0, length: 4))
        proxy.returnKeyType = .send
        let id = UUID()
        let active = DictationTextSession(id: id, proxy: proxy)
        active.finishRecording(submitAfterPolish: true)
        XCTAssertEqual(active.receive(VoiceReply(id: id, text: "", isFinal: true), in: proxy), .finished)
        XCTAssertEqual(proxy.editor.text, "keep this"); XCTAssertFalse(active.needsManualSend)
    }
    private func descendants(_ view: UIView) -> [UIView] { view.subviews.flatMap { [$0] + descendants($0) } }
    func testTabletLayoutUsesFiveRowsAndNarrowWindowFallsBack() {
        let saved = UserDefaults.standard.object(forKey: KeyboardLayoutMode.preferenceKey)
        KeyboardLayoutMode.full.save()
        defer { UserDefaults.standard.set(saved, forKey: KeyboardLayoutMode.preferenceKey) }
        let keyboard = KeyboardViewController()
        keyboard.testingTablet = true; keyboard.testingLandscape = true
        keyboard.testingDocumentProxy = TextViewProxy("", selection: .init(location: 0, length: 0))
        keyboard.loadViewIfNeeded()
        defer { keyboard.viewWillDisappear(false) }
        for width: CGFloat in [744, 834, 1194, 1366] {
            let metrics = KeyboardMetrics(width: width, landscape: true, tablet: true)
            keyboard.view.frame = CGRect(x: 0, y: 0, width: width, height: metrics.contentHeight)
            keyboard.viewDidLayoutSubviews(); keyboard.view.layoutIfNeeded()
            let keys = descendants(keyboard.view).compactMap { $0 as? KeyControl }
            XCTAssertTrue(metrics.tablet); XCTAssertFalse(metrics.split)
            for value in ["1", "0", "tab", "return", "space", "left", "right", "emoji", "language"] { XCTAssertTrue(keys.contains { $0.value == value }, value) }
            XCTAssertEqual(keys.filter { $0.value == "space" }.count, 1)
            let rows = Set(keys.map { Int($0.convert(.zero, to: keyboard.view).y.rounded()) })
            XCTAssertEqual(rows.count, 5)
            XCTAssertTrue(keys.allSatisfy { $0.bounds.width >= 28 && $0.bounds.height >= 44 })
            let image = UIGraphicsImageRenderer(bounds: keyboard.view.bounds).image { keyboard.view.layer.render(in: $0.cgContext) }
            try? image.pngData()?.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("vvhisper-ipad-\(Int(width)).png"))
        }
        XCTAssertFalse(KeyboardMetrics(width: 375, tablet: true).tablet)
    }
    func testPillsAreOnOppositeEdgesAndExpandedShortcutsStayInBounds() throws {
        let saved = UserDefaults.standard.object(forKey: KeyboardLayoutMode.preferenceKey)
        KeyboardLayoutMode.full.save()
        defer { UserDefaults.standard.set(saved, forKey: KeyboardLayoutMode.preferenceKey) }
        let keyboard = KeyboardViewController(); keyboard.testingTablet = false; keyboard.testingLandscape = false
        keyboard.testingDocumentProxy = TextViewProxy("", selection: .init(location: 0, length: 0)); keyboard.loadViewIfNeeded()
        defer { keyboard.viewWillDisappear(false) }
        for width: CGFloat in [375, 466, 655] {
            keyboard.view.frame = CGRect(x: 0, y: 0, width: width, height: KeyboardMetrics(width: width).contentHeight)
            keyboard.viewDidLayoutSubviews(); keyboard.view.layoutIfNeeded()
            let toggle = try XCTUnwrap(descendants(keyboard.view).first { $0.accessibilityIdentifier == "keyboard.shortcut-pill" } as? UIButton)
            let pill = try XCTUnwrap(descendants(keyboard.view).first { $0 is GesturePill })
            XCTAssertLessThan(toggle.convert(toggle.bounds, to: keyboard.view).maxX, 60)
            XCTAssertGreaterThan(pill.frame.minX, width - 80)
            toggle.sendActions(for: .touchUpInside); keyboard.view.layoutIfNeeded()
            for id in ["keyboard.paste", "keyboard.clipboard-history", "keyboard.open-1password", "keyboard.open-messages", "keyboard.open-phone"] {
                let button = try XCTUnwrap(descendants(keyboard.view).first { $0.accessibilityIdentifier == id })
                XCTAssertFalse(button.isHidden)
                XCTAssertEqual(button.bounds.width, 44)
                let scroller = try XCTUnwrap(button.superview?.superview as? UIScrollView)
                XCTAssertLessThanOrEqual(scroller.convert(scroller.bounds, to: keyboard.view).maxX, pill.frame.minX)
            }
            toggle.sendActions(for: .touchUpInside); keyboard.view.layoutIfNeeded()
        }
    }
}
