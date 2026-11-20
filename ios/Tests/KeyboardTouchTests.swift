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
        let previousMode = KeyboardLayoutMode.load()
        KeyboardLayoutMode.full.save()
        KeyboardLanguage.english.save()
        let proxy = TextViewProxy("", selection: NSRange(location: 0, length: 0))
        let keyboard = KeyboardViewController()
        keyboard.testingDocumentProxy = proxy
        keyboard.loadViewIfNeeded()
        defer {
            keyboard.viewWillDisappear(false)
            previousMode.save()
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
        XCTAssertEqual(KeyboardHitGeometry.target(at: CGPoint(x: -30, y: 22), frames: frames), 0)
        XCTAssertEqual(KeyboardHitGeometry.target(at: CGPoint(x: 20, y: 70), frames: frames), 0)
        XCTAssertEqual(KeyboardHitGeometry.target(at: CGPoint(x: 120, y: 22), frames: [frames[0], CGRect(x: 200, y: 0, width: 40, height: 44)]), 0)
        XCTAssertNil(KeyboardHitGeometry.target(at: CGPoint(x: CGFloat.nan, y: 22), frames: frames))
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
                    XCTAssertTrue(keyboard.view.hitTest(CGPoint(x: width / 2, y: qFrame.midY), with: nil) is KeyControl)
                }
            }
        }
    }

    func testEntireKeySurfaceHasTapCoverageAcrossFullMiniSymbolAndSplitLayouts() throws {
        try withKeyboard { keyboard, _ in
            for (width, landscape): (CGFloat, Bool) in [(375, false), (466, false), (655, false), (529, true), (802, true)] {
                for mini in [false, true] {
                    keyboard.setMiniMode(mini, animated: false)
                    keyboard.testingLandscape = landscape
                    keyboard.view.frame = CGRect(x: 0, y: 0, width: width, height: 340)
                    keyboard.viewDidLayoutSubviews(); keyboard.view.layoutIfNeeded()
                    for symbols in (mini ? [false] : [false, true]) {
                        if symbols { XCTAssertTrue(try key("123", in: keyboard).accessibilityActivate()) }
                        keyboard.view.layoutIfNeeded()
                        let surface = try XCTUnwrap(descendants(keyboard.view).first { $0 is KeyboardTouchSurface } as? KeyboardTouchSurface)
                        for y in stride(from: CGFloat(1), to: surface.bounds.height, by: 8) {
                            for x in stride(from: CGFloat(1), to: surface.bounds.width, by: 8) {
                                let point = CGPoint(x: x, y: y)
                                XCTAssertNotNil(surface.target(at: point), "Gap at \(x),\(y), width \(width)")
                            }
                        }
                        XCTAssertNil(surface.target(at: CGPoint(x: -1, y: 20)))
                        XCTAssertNil(surface.target(at: CGPoint(x: 20, y: surface.bounds.maxY + 1)))
                        if symbols { XCTAssertTrue(try key("ABC", in: keyboard).accessibilityActivate()) }
                    }
                }
            }
        }
    }

    func testEntireSideInsetsBelongToAAndLAtEveryHeightInTheirRow() throws {
        try withKeyboard { keyboard, proxy in
            for (width, landscape): (CGFloat, Bool) in [(375, false), (466, false), (655, false), (529, true), (802, true)] {
                keyboard.testingLandscape = landscape
                keyboard.view.frame = CGRect(x: 0, y: 0, width: width, height: 340)
                keyboard.viewDidLayoutSubviews(); keyboard.view.layoutIfNeeded()
                for value in ["a", "l"] {
                    let control = try key(value, in: keyboard)
                    let frame = control.convert(control.bounds, to: keyboard.view)
                    let range = value == "a" ? CGFloat(0.5)..<frame.minX : frame.maxX..<width
                    for y in stride(from: frame.minY + 0.5, to: frame.maxY, by: 2) {
                        for x in stride(from: range.lowerBound, to: range.upperBound, by: 2) {
                            let point = CGPoint(x: x, y: y)
                            XCTAssertTrue(keyboard.view.hitTest(point, with: nil) === control,
                                          "Expected \(value) at \(point) for width \(width)")
                        }
                    }
                    let point = CGPoint(x: value == "a" ? 1 : width - 1, y: frame.minY + 1)
                    let local = control.convert(point, from: keyboard.view)
                    let before = proxy.editor.text ?? ""
                    XCTAssertTrue(control.press(at: 0, point: local))
                    XCTAssertTrue(control.movePress(to: local, at: 0.05))
                    control.releasePress()
                    XCTAssertEqual(proxy.editor.text, before + value)
                }
            }
        }
    }

    func testWideGapTapSurvivesReleaseAndHoldStillDictatesWithoutTyping() throws {
        try withKeyboard { keyboard, proxy in
            keyboard.testingLandscape = true
            keyboard.view.frame = CGRect(x: 0, y: 0, width: 802, height: 320)
            keyboard.viewDidLayoutSubviews(); keyboard.view.layoutIfNeeded()
            let q = try key("q", in: keyboard)
            let point = CGPoint(x: 401, y: q.convert(q.bounds, to: keyboard.view).midY)
            let target = try XCTUnwrap(keyboard.view.hitTest(point, with: nil) as? KeyControl)
            let local = target.convert(point, from: keyboard.view)
            XCTAssertFalse(target.bounds.insetBy(dx: -30, dy: -40).contains(local))
            XCTAssertTrue(target.press(at: 0, point: local))
            XCTAssertTrue(target.movePress(to: local, at: 0.1))
            target.releasePress()
            XCTAssertEqual(proxy.editor.text, target.value)
            var holds = 0
            target.onGapHold = { holds += 1 }
            target.press(at: 1, point: local); target.advancePress(to: 1.4); target.releasePress()
            XCTAssertEqual(holds, 1)
            XCTAssertEqual(proxy.editor.text, target.value)
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

    func testTapFeedbackIsImmediateAndReleaseDoesNotRepeatIt() throws {
        try withKeyboard { keyboard, proxy in
            let a = try key("a", in: keyboard), b = try key("b", in: keyboard)
            let initial = keyboard.testingTapFeedbackCount
            XCTAssertTrue(a.press(at: 0, point: .zero))
            XCTAssertEqual(keyboard.testingTapFeedbackCount - initial, 1)
            XCTAssertEqual(proxy.editor.text, "")
            XCTAssertTrue(b.press(at: 0.04, point: .zero))
            XCTAssertEqual(keyboard.testingTapFeedbackCount - initial, 2)
            b.releasePress(); a.releasePress()
            XCTAssertEqual(proxy.editor.text, "ab")
            XCTAssertEqual(keyboard.testingTapFeedbackCount - initial, 2)
            XCTAssertTrue(a.accessibilityActivate())
            XCTAssertEqual(proxy.editor.text, "aba")
            XCTAssertEqual(keyboard.testingTapFeedbackCount - initial, 3)
        }
    }

    func testRejectedPressAndCancelledReleaseDoNotAddFeedback() {
        let key = KeyControl()
        var pulses = 0
        key.onPressFeedback = { pulses += 1 }
        key.onPress = { false }
        XCTAssertFalse(key.press(at: 0, point: .zero))
        XCTAssertEqual(pulses, 0)
        key.onPress = { true }
        XCTAssertTrue(key.press(at: 0, point: .zero))
        key.cancelPress(); key.releasePress()
        XCTAssertEqual(pulses, 1)
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
                XCTAssertEqual(try key("language", in: keyboard).accessibilityLabel, "English")
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
