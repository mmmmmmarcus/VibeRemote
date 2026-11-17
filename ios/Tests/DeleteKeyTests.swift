import XCTest
import UIKit
@testable import vvhisper

@MainActor
final class DeleteKeyTests: XCTestCase {
    func testDeleteTapAndRepeatNeverStartDictationAndStopOnRelease() {
        let key = KeyControl(frame: CGRect(x: 0, y: 0, width: 54, height: 44))
        key.isDeleteKey = true
        var deletes = 0, voices = 0
        key.onTap = { deletes += 1 }; key.onDeleteRepeat = { deletes += 1 }
        key.onHold = { voices += 1 }
        key.press(at: 0, point: CGPoint(x: 20, y: 20))
        XCTAssertTrue(key.isPressed)
        key.advancePress(to: 0.2); key.releasePress()
        XCTAssertFalse(key.isPressed)
        XCTAssertEqual(deletes, 1)
        key.press(at: 1, point: CGPoint(x: 20, y: 20))
        key.advancePress(to: 1.37); XCTAssertEqual(deletes, 1)
        key.advancePress(to: 1.4); key.advancePress(to: 1.5)
        XCTAssertEqual(deletes, 3)
        key.releasePress(); key.advancePress(to: 5)
        XCTAssertEqual(deletes, 3)
        XCTAssertEqual(voices, 0)
    }

    func testDeleteHoldSwipeClearsOnlyOnceAndConsumesRelease() {
        let key = KeyControl(frame: CGRect(x: 0, y: 0, width: 54, height: 44))
        key.isDeleteKey = true
        var clears = 0, deletes = 0
        key.onClearAll = { clears += 1 }; key.onTap = { deletes += 1 }
        key.onDeleteRepeat = { deletes += 1 }
        key.press(at: 0, point: CGPoint(x: 20, y: 20))
        key.movePress(to: CGPoint(x: -45, y: 20), at: 0.2)
        XCTAssertEqual(clears, 0, "A quick swipe must not clear the field")
        key.movePress(to: CGPoint(x: -45, y: 20), at: 0.4)
        key.movePress(to: CGPoint(x: -90, y: 20), at: 0.6)
        key.advancePress(to: 3); key.releasePress()
        XCTAssertEqual(clears, 1); XCTAssertEqual(deletes, 0)
        key.press(at: 4, point: CGPoint(x: 20, y: 20))
        XCTAssertFalse(key.movePress(to: CGPoint(x: -80, y: 80), at: 4.5))
        key.advancePress(to: 8); key.releasePress()
        XCTAssertEqual(clears, 1); XCTAssertEqual(deletes, 0)
    }

    func testDeleteCancelAndNewPressDoNotInheritOldHold() {
        var gesture = DeleteGesture()
        gesture.press(at: 0, point: .zero)
        XCTAssertEqual(gesture.advance(to: 3), .delete)
        XCTAssertNil(gesture.advance(to: 3), "A delayed tick cannot replay missed deletions")
        gesture.cancel()
        XCTAssertNil(gesture.advance(to: 4))
        gesture.press(at: 4, point: .zero)
        XCTAssertNil(gesture.advance(to: 4.1))
        XCTAssertNil(gesture.move(to: CGPoint(x: -100, y: 0), at: 4.2))
        XCTAssertEqual(gesture.release(), .delete)
    }

    func testClearAllIncludesSelectionAndTextOnBothSidesOfCaret() {
        let text = "前面👨‍👩‍👧‍👦 hello\n我知道了\n后面 café"
        for selection in [NSRange(location: 0, length: 0), NSRange(location: 2, length: 0),
                          NSRange(location: 2, length: 11), NSRange(location: text.utf16.count, length: 0)] {
            let proxy = TextViewProxy(text, selection: selection)
            let session = ClearTextSession(proxy: proxy)
            var result = ClearTextSession.Outcome.pending
            for _ in 0..<100 where result == .pending { result = session.advance(in: proxy, batchSize: 3) }
            XCTAssertEqual(result, .finished)
            XCTAssertEqual(proxy.editor.text, "")
        }
    }

    func testClearAllContinuesAcrossBoundedRepeatedAndMultilineContext() {
        let text = String(repeating: "中文\n\n🌍hello ", count: 30)
        let proxy = TextViewProxy(text, selection: NSRange(location: 0, length: 0))
        proxy.contextLimit = 8
        let session = ClearTextSession(proxy: proxy)
        var result = ClearTextSession.Outcome.pending
        for _ in 0..<100 where result == .pending { result = session.advance(in: proxy) }
        XCTAssertEqual(result, .finished)
        XCTAssertFalse(proxy.hasText)
    }

    func testClearAllAbandonsChangedDocumentCursorOrTextBetweenBatches() {
        for change in 0..<3 {
            let proxy = TextViewProxy("original text", selection: NSRange(location: 13, length: 0))
            let session = ClearTextSession(proxy: proxy)
            XCTAssertEqual(session.advance(in: proxy, batchSize: 1), .pending)
            switch change {
            case 0: proxy.documentIdentifier = UUID()
            case 1: proxy.editor.selectedRange = NSRange(location: 0, length: 0)
            default: proxy.insertText("new")
            }
            let remaining = proxy.editor.text
            XCTAssertEqual(session.advance(in: proxy), .destinationChanged)
            XCTAssertEqual(proxy.editor.text, remaining)
        }
    }

    func testClearAllCrossesBlankLinesWithParagraphOnlyContext() {
        for text in ["前面\n\nhello\n后面\n\n", String(repeating: "\n", count: 50)] {
            for location in [0, text.utf16.count / 2, text.utf16.count] {
                let proxy = TextViewProxy(text, selection: NSRange(location: location, length: 0))
                proxy.paragraphContextOnly = true
                let session = ClearTextSession(proxy: proxy)
                var result = ClearTextSession.Outcome.pending
                for _ in 0..<100 where result == .pending { result = session.advance(in: proxy) }
                XCTAssertEqual(result, .finished)
                XCTAssertFalse(proxy.hasText)
            }
        }
    }

    func testClearAllDoesNotBlindlyDeleteWhenContextIsUnavailable() {
        let proxy = TextViewProxy("hidden", selection: NSRange(location: 6, length: 0))
        proxy.hidesContext = true
        XCTAssertEqual(ClearTextSession(proxy: proxy).advance(in: proxy), .unavailable)
        XCTAssertEqual(proxy.backspaces, 0)
    }
}
