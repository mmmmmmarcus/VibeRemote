import XCTest
@testable import vvhisper

final class SoundcoreHotkeyGestureTests: XCTestCase {
    func testTapLatchesAndSecondTapStops() {
        var gesture = SoundcoreHotkeyGesture()
        XCTAssertEqual(gesture.press(at: 0), .begin)
        XCTAssertEqual(gesture.release(at: 0.1), .latch)
        XCTAssertTrue(gesture.handsFree)
        XCTAssertEqual(gesture.press(at: 10), .none)
        XCTAssertEqual(gesture.release(at: 10.1), .stop)
        XCTAssertFalse(gesture.handsFree)
    }

    func testHoldAndTapCoexistWithoutPreferenceChanges() {
        var gesture = SoundcoreHotkeyGesture()
        XCTAssertEqual(gesture.press(at: 0), .begin)
        XCTAssertEqual(gesture.release(at: 1), .stop)
        XCTAssertFalse(gesture.handsFree)
        XCTAssertEqual(gesture.press(at: 2), .begin)
        XCTAssertEqual(gesture.release(at: 2.1), .latch)
        XCTAssertEqual(gesture.press(at: 3), .none)
        // Even a long second press stops the latched session.
        XCTAssertEqual(gesture.release(at: 4), .stop)
    }

    func testShortcutsCancelNewCaptureButPreserveExistingHandsFree() {
        var gesture = SoundcoreHotkeyGesture()
        XCTAssertEqual(gesture.press(at: 0), .begin)
        XCTAssertEqual(gesture.interrupt(), .cancel)
        XCTAssertEqual(gesture.release(at: 0.1), .none)
        XCTAssertEqual(gesture.press(at: 1), .begin)
        XCTAssertEqual(gesture.release(at: 1.1), .latch)
        XCTAssertEqual(gesture.press(at: 2), .none)
        XCTAssertEqual(gesture.interrupt(), .none)
        XCTAssertTrue(gesture.handsFree)
        XCTAssertEqual(gesture.release(at: 2.1), .none)
        XCTAssertEqual(gesture.press(at: 3), .none)
        XCTAssertEqual(gesture.release(at: 3.1), .stop)
    }

    func testDisconnectCancelOrFailedStartCannotLeaveLatchedState() {
        var gesture = SoundcoreHotkeyGesture()
        _ = gesture.press(at: 0)
        _ = gesture.release(at: 0.1)
        gesture.reset()
        XCTAssertFalse(gesture.handsFree)
        XCTAssertEqual(gesture.press(at: 1), .begin)
        gesture.reset() // Begin failed; its release must never latch.
        XCTAssertEqual(gesture.release(at: 1.1), .none)
        XCTAssertFalse(gesture.handsFree)
    }

    func testDuplicateEdgesAndBufferRepress() {
        var gesture = SoundcoreHotkeyGesture()
        XCTAssertEqual(gesture.press(at: 0), .begin)
        XCTAssertEqual(gesture.press(at: 0.05), .none)
        XCTAssertEqual(gesture.release(at: 1), .stop)
        XCTAssertEqual(gesture.release(at: 1.01), .none)
        // The owner resumes the existing capture rather than opening a new transfer.
        XCTAssertEqual(gesture.press(at: 1.1), .begin)
        XCTAssertEqual(gesture.release(at: 1.2), .latch)
        XCTAssertTrue(gesture.handsFree)
    }

    func testTapThreshold() {
        var gesture = SoundcoreHotkeyGesture()
        _ = gesture.press(at: 0)
        XCTAssertEqual(gesture.release(at: SoundcoreHotkeyGesture.tapDuration), .latch)
        gesture.reset()
        _ = gesture.press(at: 0)
        XCTAssertEqual(gesture.release(at: SoundcoreHotkeyGesture.tapDuration + 0.001), .stop)
    }
}
