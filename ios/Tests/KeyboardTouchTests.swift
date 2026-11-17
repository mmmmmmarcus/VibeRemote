import XCTest
import UIKit
@testable import vvhisper

@MainActor
final class KeyboardTouchTests: XCTestCase {
    private func descendants(_ view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
    private func key(_ value: String, in keyboard: KeyboardViewController) throws -> KeyControl {
        try XCTUnwrap(descendants(keyboard.view).first { $0.accessibilityIdentifier == "keyboard.key.\(value)" } as? KeyControl)
    }
    private func withKeyboard(_ body: (KeyboardViewController, TextViewProxy) throws -> Void) rethrows {
        let previous = UserDefaults.standard.string(forKey: KeyboardLanguage.preferenceKey)
        KeyboardLanguage.english.save()
        let proxy = TextViewProxy("", selection: NSRange(location: 0, length: 0))
        let keyboard = KeyboardViewController()
        keyboard.testingDocumentProxy = proxy
        keyboard.loadViewIfNeeded()
        defer {
            keyboard.viewWillDisappear(false)
            if let previous { UserDefaults.standard.set(previous, forKey: KeyboardLanguage.preferenceKey) }
            else { UserDefaults.standard.removeObject(forKey: KeyboardLanguage.preferenceKey) }
        }
        try body(keyboard, proxy)
    }

    func testGapsChooseNearestEdgeAndDirectHitsAlwaysWin() {
        let frames = [CGRect(x: 0, y: 0, width: 40, height: 44), CGRect(x: 48, y: 0, width: 40, height: 44)]
        XCTAssertEqual(KeyboardHitGeometry.target(at: CGPoint(x: 43, y: 22), frames: frames), 0)
        XCTAssertEqual(KeyboardHitGeometry.target(at: CGPoint(x: 45, y: 22), frames: frames), 1)
        XCTAssertEqual(KeyboardHitGeometry.target(at: CGPoint(x: 49, y: 22), frames: frames), 1)
        XCTAssertEqual(KeyboardHitGeometry.target(at: CGPoint(x: -6, y: 22), frames: frames), 0)
        XCTAssertNil(KeyboardHitGeometry.target(at: CGPoint(x: -30, y: 22), frames: frames))
        XCTAssertNil(KeyboardHitGeometry.target(at: CGPoint(x: 20, y: 70), frames: frames))
        XCTAssertNil(KeyboardHitGeometry.target(at: CGPoint(x: 120, y: 22), frames: [frames[0], CGRect(x: 200, y: 0, width: 40, height: 44)]))
    }

    func testRealHitTestingFillsKeyGapsWithoutChangingKeyCentersInEveryLayout() throws {
        try withKeyboard { keyboard, _ in
            for (width, landscape): (CGFloat, Bool) in [(375, false), (466, false), (655, false), (529, true), (802, true)] {
                keyboard.testingLandscape = landscape
                keyboard.view.frame = CGRect(x: 0, y: 0, width: width, height: 340)
                keyboard.viewDidLayoutSubviews(); keyboard.view.layoutIfNeeded()
                let controls = descendants(keyboard.view).compactMap { $0 as? UIControl }.filter {
                    $0.accessibilityIdentifier?.hasPrefix("keyboard.key.") == true
                }
                for control in controls {
                    let center = control.convert(CGPoint(x: control.bounds.midX, y: control.bounds.midY), to: keyboard.view)
                    XCTAssertTrue(keyboard.view.hitTest(center, with: nil) === control, "Center: \(control.accessibilityIdentifier ?? "") at \(width)")
                }
                let q = try key("q", in: keyboard), w = try key("w", in: keyboard)
                let qFrame = q.convert(q.bounds, to: keyboard.view), wFrame = w.convert(w.bounds, to: keyboard.view)
                let gap = wFrame.minX - qFrame.maxX
                let nearQ = CGPoint(x: qFrame.maxX + gap * 0.25, y: qFrame.midY)
                let nearW = CGPoint(x: qFrame.maxX + gap * 0.75, y: qFrame.midY)
                XCTAssertTrue(keyboard.view.hitTest(nearQ, with: nil) === q)
                XCTAssertTrue(keyboard.view.hitTest(nearW, with: nil) === w)
                XCTAssertTrue(q.point(inside: q.convert(nearQ, from: keyboard.view), with: nil))
                XCTAssertFalse(w.point(inside: w.convert(nearQ, from: keyboard.view), with: nil))
                let a = try key("a", in: keyboard)
                let aFrame = a.convert(a.bounds, to: keyboard.view)
                let verticalGap = aFrame.minY - qFrame.maxY
                let betweenRows = CGPoint(x: max(qFrame.minX, aFrame.minX) + 5,
                                          y: qFrame.maxY + verticalGap * 0.25)
                XCTAssertTrue(keyboard.view.hitTest(betweenRows, with: nil) === q)
                XCTAssertFalse(keyboard.view.hitTest(CGPoint(x: width / 2, y: 10), with: nil) is KeyControl)
                if width >= 800 {
                    XCTAssertFalse(keyboard.view.hitTest(CGPoint(x: width / 2, y: qFrame.midY), with: nil) is UIControl)
                }
            }
        }
    }

    func testOverlappingThumbsCommitBothKeysOnceInPressOrder() throws {
        try withKeyboard { keyboard, proxy in
            let a = try key("a", in: keyboard), b = try key("b", in: keyboard), c = try key("c", in: keyboard)
            var staleHolds = 0
            a.onHold = { staleHolds += 1 }; b.onHold = { staleHolds += 1 }
            XCTAssertTrue(a.press(at: 0, point: .zero))
            XCTAssertTrue(b.press(at: 0.06, point: .zero))
            XCTAssertEqual(proxy.editor.text, "a")
            XCTAssertTrue(c.press(at: 0.12, point: .zero))
            XCTAssertEqual(proxy.editor.text, "ab")
            c.releasePress(); b.releasePress(); a.releasePress()
            a.advancePress(to: 2); b.advancePress(to: 2)
            a.cancelPress(); b.cancelPress()
            XCTAssertEqual(proxy.editor.text, "abc")
            XCTAssertEqual(staleHolds, 0)
        }
    }

    func testShiftAndAutomaticLowercaseDoNotDestroyOverlappingKeys() throws {
        try withKeyboard { keyboard, proxy in
            let shift = try key("shift", in: keyboard), a = try key("a", in: keyboard), b = try key("b", in: keyboard)
            shift.press(at: 0, point: .zero)
            XCTAssertTrue(a.press(at: 0.05, point: .zero))
            XCTAssertEqual(a.label.text, "A")
            XCTAssertTrue(b.press(at: 0.1, point: .zero))
            XCTAssertEqual(proxy.editor.text, "A")
            XCTAssertTrue(try key("b", in: keyboard) === b)
            XCTAssertEqual(b.label.text, "b")
            b.releasePress(); a.releasePress(); shift.releasePress()
            XCTAssertEqual(proxy.editor.text, "Ab")
        }
    }

    func testDeleteRolloverStopsRepeatingAndLateReleaseDoesNotAffectNewPress() throws {
        try withKeyboard { keyboard, proxy in
            proxy.insertText("test")
            let delete = try key("delete", in: keyboard), a = try key("a", in: keyboard)
            delete.press(at: 0, point: .zero); delete.advancePress(to: 0.4)
            XCTAssertEqual(proxy.editor.text, "tes")
            a.press(at: 0.45, point: .zero)
            delete.releasePress(); delete.advancePress(to: 1)
            a.releasePress()
            XCTAssertEqual(proxy.editor.text, "tesa")
            XCTAssertEqual(proxy.backspaces, 1)
        }
    }

    func testRolloverNeverAddsLetterForAnAlreadyRecognizedHold() throws {
        try withKeyboard { keyboard, proxy in
            let a = try key("a", in: keyboard), b = try key("b", in: keyboard)
            var holds = 0
            a.onHold = { holds += 1 }
            a.press(at: 0, point: .zero); a.advancePress(to: 0.4)
            b.press(at: 0.5, point: .zero)
            b.releasePress(); a.releasePress()
            XCTAssertEqual(proxy.editor.text, "b")
            XCTAssertEqual(holds, 1)
        }
    }

    func testOverlappingFunctionKeyCannotSubmitOrChangeLayouts() throws {
        for value in ["return", "123", "language"] {
            try withKeyboard { keyboard, proxy in
                let function = try key(value, in: keyboard), a = try key("a", in: keyboard)
                function.press(at: 0, point: .zero)
                XCTAssertTrue(a.press(at: 0.05, point: .zero))
                a.releasePress(); function.releasePress()
                XCTAssertEqual(proxy.editor.text, "a")
                XCTAssertNotNil(try key("a", in: keyboard))
                XCTAssertEqual(try key("language", in: keyboard).label.text, "EN")
            }
        }
    }

    func testLayoutChangeRejectsAnOldKeyFromTheRemovedPage() throws {
        try withKeyboard { keyboard, proxy in
            let mode = try key("123", in: keyboard), a = try key("a", in: keyboard)
            mode.accessibilityActivate()
            XCTAssertFalse(a.press(at: 0.05, point: .zero))
            a.releasePress(); mode.releasePress()
            XCTAssertEqual(proxy.editor.text, "")
            XCTAssertNotNil(try key("1", in: keyboard))
        }
    }
}
