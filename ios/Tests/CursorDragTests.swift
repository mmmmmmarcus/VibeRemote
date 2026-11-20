import XCTest
import UIKit
@testable import vvhisper

@MainActor final class CursorDragTests: XCTestCase {
    private func descendants(_ view: UIView) -> [UIView] { view.subviews.flatMap { [$0] + descendants($0) } }
    private func key(_ value: String, _ keyboard: KeyboardViewController) throws -> KeyControl {
        try XCTUnwrap(descendants(keyboard.view).compactMap { $0 as? KeyControl }.first { $0.value == value })
    }
    private func withKeyboard(width: CGFloat = 466, landscape: Bool = false, language: KeyboardLanguage = .english,
                              _ body: (KeyboardViewController, TextViewProxy) async throws -> Void) async throws {
        let previous = UserDefaults.standard.string(forKey: KeyboardLanguage.preferenceKey)
        let previousMode = UserDefaults.standard.object(forKey: KeyboardLayoutMode.preferenceKey)
        KeyboardLayoutMode.full.save()
        language.save()
        await withCheckedContinuation { c in PinyinEngine.shared.perform(.clear) { _ in c.resume() } }
        let keyboard = KeyboardViewController(), proxy = TextViewProxy("abcdef", selection: NSRange(location: 3, length: 0))
        keyboard.testingDocumentProxy = proxy; keyboard.testingVoiceAvailable = true; keyboard.testingLandscape = landscape
        keyboard.loadViewIfNeeded()
        keyboard.view.frame = CGRect(x: 0, y: 0, width: width, height: KeyboardMetrics(width: width, landscape: landscape).contentHeight)
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
    @discardableResult private func hold(_ key: KeyControl) -> CGPoint {
        let point = CGPoint(x: key.bounds.midX, y: key.bounds.midY)
        XCTAssertTrue(key.press(at: 10, point: point)); key.advancePress(to: 10.4)
        return point
    }
    private func move(_ key: KeyControl, _ point: CGPoint, dx: CGFloat, dy: CGFloat = 0) {
        XCTAssertTrue(key.movePress(to: CGPoint(x: point.x + dx, y: point.y + dy), at: 10.5))
    }

    func testDistanceReversalJitterAndClampedBoundaryHaveNoMovementDebt() {
        let proxy = TextViewProxy("abcdefgh", selection: NSRange(location: 4, length: 0))
        let drag = CursorDragSession(proxy: proxy, point: .zero)
        XCTAssertTrue(drag.move(to: CGPoint(x: 7, y: 4), in: proxy)); XCTAssertEqual(proxy.editor.selectedRange.location, 4)
        XCTAssertTrue(drag.move(to: CGPoint(x: 24, y: 4), in: proxy)); XCTAssertEqual(proxy.editor.selectedRange.location, 7)
        XCTAssertTrue(drag.move(to: CGPoint(x: 8, y: 4), in: proxy)); XCTAssertEqual(proxy.editor.selectedRange.location, 5)
        XCTAssertTrue(drag.move(to: CGPoint(x: 1000, y: 4), in: proxy)); XCTAssertEqual(proxy.editor.selectedRange.location, 8)
        XCTAssertTrue(drag.move(to: CGPoint(x: 992, y: 4), in: proxy)); XCTAssertEqual(proxy.editor.selectedRange.location, 7)
        XCTAssertEqual(proxy.editor.text, "abcdefgh")
    }
    func testChineseEmojiAndCombiningCharactersStayWhole() {
        let clusters = ["你", "👨‍👩‍👧‍👦", "e\u{301}", "好"]
        let proxy = TextViewProxy(clusters.joined(), selection: NSRange(location: 0, length: 0))
        let drag = CursorDragSession(proxy: proxy, point: .zero)
        for index in 1...4 {
            XCTAssertTrue(drag.move(to: CGPoint(x: index * 8, y: 0), in: proxy))
            XCTAssertEqual(proxy.editor.selectedRange.location, clusters.prefix(index).joined().utf16.count)
        }
        for index in (0..<4).reversed() {
            XCTAssertTrue(drag.move(to: CGPoint(x: index * 8, y: 0), in: proxy))
            XCTAssertEqual(proxy.editor.selectedRange.location, clusters.prefix(index).joined().utf16.count)
        }
        XCTAssertEqual(proxy.editor.text, clusters.joined())
    }
    func testVerticalMovementKeepsColumnAcrossShortLinesAndDoesNotGuessWrapping() {
        let proxy = TextViewProxy("abcdef\nx\nabcdef", selection: NSRange(location: 4, length: 0))
        let drag = CursorDragSession(proxy: proxy, point: .zero)
        XCTAssertTrue(drag.move(to: CGPoint(x: 0, y: 28), in: proxy)); XCTAssertEqual(proxy.editor.selectedRange.location, 8)
        XCTAssertTrue(drag.move(to: CGPoint(x: 0, y: 56), in: proxy)); XCTAssertEqual(proxy.editor.selectedRange.location, 13)
        XCTAssertTrue(drag.move(to: CGPoint(x: 0, y: 0), in: proxy)); XCTAssertEqual(proxy.editor.selectedRange.location, 4)
        XCTAssertTrue(drag.move(to: CGPoint(x: 0, y: -28), in: proxy)); XCTAssertEqual(proxy.editor.selectedRange.location, 4)
        XCTAssertEqual(proxy.editor.text, "abcdef\nx\nabcdef")
    }
    func testSessionRejectsChangedTextSelectionAndDocument() {
        for change in 0..<3 {
            let proxy = TextViewProxy("abcdef", selection: NSRange(location: 3, length: 0))
            let drag = CursorDragSession(proxy: proxy, point: .zero)
            if change == 0 { proxy.editor.insertText("X") }
            if change == 1 { proxy.editor.selectedRange = NSRange(location: 1, length: 0) }
            if change == 2 { proxy.documentIdentifier = UUID() }
            let before = proxy.editor.selectedRange
            XCTAssertFalse(drag.move(to: CGPoint(x: 16, y: 0), in: proxy))
            XCTAssertEqual(proxy.editor.selectedRange, before)
        }
    }
    func testDelayedHostAcknowledgementsSerializeMovementAndKeepHoldAlive() {
        let proxy = TextViewProxy("abcdefgh", selection: NSRange(location: 8, length: 0))
        proxy.defersCursorMoves = true
        let drag = CursorDragSession(proxy: proxy, point: .zero)
        XCTAssertTrue(drag.move(to: CGPoint(x: -16, y: 0), in: proxy))
        XCTAssertEqual(proxy.pendingCursorMoves, [-2])
        XCTAssertTrue(drag.move(to: CGPoint(x: -24, y: 0), in: proxy))
        XCTAssertEqual(proxy.pendingCursorMoves, [-2])
        proxy.flushCursorMoves()
        XCTAssertTrue(drag.advance(in: proxy)); XCTAssertEqual(proxy.pendingCursorMoves, [-1])
        proxy.flushCursorMoves()
        XCTAssertTrue(drag.advance(in: proxy)); XCTAssertEqual(proxy.editor.selectedRange.location, 5)
        XCTAssertEqual(proxy.editor.text, "abcdefgh")
    }
    func testNilContextAtDocumentEdgesStillAllowsMovementAwayFromEdge() {
        let proxy = TextViewProxy("abcdef", selection: NSRange(location: 6, length: 0))
        proxy.nilAtEmptyContext = true; proxy.defersCursorMoves = true
        let drag = CursorDragSession(proxy: proxy, point: .zero)
        XCTAssertNil(proxy.documentContextAfterInput)
        XCTAssertTrue(drag.move(to: CGPoint(x: -48, y: 0), in: proxy))
        proxy.flushCursorMoves(); XCTAssertTrue(drag.advance(in: proxy))
        XCTAssertEqual(proxy.editor.selectedRange.location, 0); XCTAssertNil(proxy.documentContextBeforeInput)
        XCTAssertTrue(drag.move(to: CGPoint(x: -40, y: 0), in: proxy))
        proxy.flushCursorMoves(); XCTAssertTrue(drag.advance(in: proxy))
        XCTAssertEqual(proxy.editor.selectedRange.location, 1)
    }
    func testContextWindowRefreshAndTemporaryAbsenceDoNotCancelStationaryHold() {
        let proxy = TextViewProxy("0123456789abcdefghij", selection: NSRange(location: 10, length: 0))
        proxy.contextLimit = 4
        let drag = CursorDragSession(proxy: proxy, point: .zero)
        proxy.contextLimit = nil
        XCTAssertTrue(drag.advance(in: proxy))
        proxy.hidesContext = true
        XCTAssertTrue(drag.advance(in: proxy))
        proxy.hidesContext = false
        XCTAssertTrue(drag.move(to: CGPoint(x: 16, y: 0), in: proxy))
        XCTAssertEqual(proxy.editor.selectedRange.location, 12)
        proxy.editor.selectedRange = NSRange(location: 4, length: 0)
        XCTAssertFalse(drag.advance(in: proxy))
    }
    func testTapStillInsertsSpaceButHoldMovesWithoutTypingOrDictatingAcrossLayouts() async throws {
        for (width, landscape): (CGFloat, Bool) in [(375, false), (466, false), (655, false), (529, true), (802, true)] {
            try await withKeyboard(width: width, landscape: landscape) { keyboard, proxy in
                let space = try key("space", keyboard)
                XCTAssertTrue(space.press(at: 9, point: CGPoint(x: 10, y: 10))); space.releasePress()
                XCTAssertEqual(proxy.editor.text, "abc def")
                let point = hold(space)
                move(space, point, dx: -16); XCTAssertEqual(proxy.editor.selectedRange.location, 2)
                keyboard.selectionDidChange(nil) // Our own move must not cancel tracking.
                move(space, point, dx: 8); XCTAssertEqual(proxy.editor.selectedRange.location, 5)
                space.releasePress(); space.advancePress(to: 12)
                XCTAssertFalse(space.movePress(to: point, at: 12)); XCTAssertEqual(proxy.editor.text, "abc def")
                XCTAssertTrue(keyboard.testingVoiceCommands.isEmpty)
                keyboard.setMiniMode(true); keyboard.viewDidLayoutSubviews(); keyboard.view.layoutIfNeeded()
                XCTAssertFalse(descendants(keyboard.view).compactMap { $0 as? KeyControl }.contains { $0.value == "space" })
                XCTAssertEqual(proxy.editor.selectedRange.location, 5)
            }
        }
    }
    func testHoldingWithoutMovingDoesNotInsertSpaceAndSlidingOverDeleteDoesNotDelete() async throws {
        try await withKeyboard { keyboard, proxy in
            let space = try key("space", keyboard)
            _ = hold(space); space.releasePress(); XCTAssertEqual(proxy.editor.text, "abcdef")
            _ = hold(space)
            let delete = try key("delete", keyboard)
            let point = space.convert(CGPoint(x: delete.bounds.midX, y: delete.bounds.midY), from: delete)
            XCTAssertTrue(space.movePress(to: point, at: 10.6)); space.releasePress()
            XCTAssertEqual(proxy.backspaces, 0); XCTAssertEqual(proxy.editor.text, "abcdef")
            XCTAssertTrue(keyboard.testingVoiceCommands.isEmpty)
        }
    }
    func testFieldChangeDismissalAndMiniGestureCancelCursorTouch() async throws {
        for reason in 0..<3 {
            try await withKeyboard { keyboard, proxy in
                let space = try key("space", keyboard), point = hold(space)
                if reason == 0 { proxy.documentIdentifier = UUID(); keyboard.selectionDidChange(nil) }
                if reason == 1 { keyboard.viewWillDisappear(false) }
                if reason == 2 {
                    keyboard.beginModeChord(at: [space.convert(point, to: keyboard.view), CGPoint(x: 12, y: 60)])
                    keyboard.finishModeChord(direction: .inward, replayTaps: false)
                }
                XCTAssertFalse(space.movePress(to: CGPoint(x: point.x + 24, y: point.y), at: 11))
                space.releasePress(); XCTAssertEqual(proxy.editor.text, "abcdef"); XCTAssertEqual(proxy.editor.selectedRange.location, 3)
            }
        }
    }
    func testCursorHoldCommitsChineseCandidateBeforeMoving() async throws {
        try await withKeyboard(language: .chinese) { keyboard, proxy in
            proxy.editor.text = ""; proxy.editor.selectedRange = NSRange(location: 0, length: 0)
            for value in "haode" { _ = try key(String(value), keyboard).accessibilityActivate() }
            let space = try key("space", keyboard), point = hold(space)
            for _ in 0..<300 {
                if proxy.editor.text == "好的" { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(proxy.editor.text, "好的")
            move(space, point, dx: -8); space.releasePress()
            XCTAssertEqual(proxy.editor.selectedRange.location, 1); XCTAssertEqual(proxy.editor.text, "好的")
        }
    }
    func testGapBesideSpaceKeepsDictationAndCursorCancelsPendingPolish() async throws {
        try await withKeyboard { keyboard, proxy in
            let space = try key("space", keyboard)
            XCTAssertTrue(space.press(at: 0, point: CGPoint(x: -1, y: 10))); space.advancePress(to: 0.4)
            XCTAssertEqual(keyboard.testingVoiceCommands.last?.phase, .recording)
            let id = try XCTUnwrap(keyboard.testingVoiceCommands.last?.id)
            space.releasePress(); XCTAssertEqual(keyboard.testingVoiceCommands.last?.phase, .finish)
            let point = hold(space); move(space, point, dx: -8)
            XCTAssertEqual(keyboard.testingVoiceCommands.last?.phase, .cancel)
            XCTAssertFalse(keyboard.receiveVoiceReply(VoiceReply(id: id, text: "late", isFinal: true, error: nil, updatedAt: Date())))
            space.releasePress(); XCTAssertEqual(proxy.editor.text, "abcdef")
        }
    }
    func testBothSplitSpacesAndSymbolPageWorkWithoutVoiceReadiness() async throws {
        try await withKeyboard(width: 802, landscape: true) { keyboard, proxy in
            keyboard.testingVoiceAvailable = false
            _ = try key("123", keyboard).accessibilityActivate(); keyboard.view.layoutIfNeeded()
            let spaces = descendants(keyboard.view).compactMap { $0 as? KeyControl }.filter { $0.value == "space" }
            XCTAssertEqual(spaces.count, 2)
            for space in spaces {
                let point = hold(space); move(space, point, dx: -8); space.releasePress()
            }
            XCTAssertEqual(proxy.editor.selectedRange.location, 1)
            XCTAssertEqual(proxy.editor.text, "abcdef"); XCTAssertTrue(keyboard.testingVoiceCommands.isEmpty)
        }
    }
    func testPendingPasteAndAnotherKeyCannotContinueCursorHold() async throws {
        try await withKeyboard { keyboard, proxy in
            let request = try XCTUnwrap(keyboard.beginPaste(codeOnly: false))
            let space = try key("space", keyboard), point = hold(space)
            XCTAssertNil(keyboard.beginPaste(codeOnly: false))
            keyboard.completePaste("late paste", request: request)
            let letter = try key("a", keyboard)
            XCTAssertTrue(letter.press(at: 11, point: CGPoint(x: 10, y: 10))); letter.releasePress()
            XCTAssertFalse(space.movePress(to: CGPoint(x: point.x + 16, y: point.y), at: 11.1)); space.releasePress()
            XCTAssertEqual(proxy.editor.text?.lowercased(), "abcadef")
        }
    }
}
