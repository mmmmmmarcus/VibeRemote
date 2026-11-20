import Foundation
import XCTest
import RemoteAudioProtocol

final class VoiceReleaseBufferTests: XCTestCase {
    func testIndependentDefaultsAndSliderRange() throws {
        let name = "vvhisper.ReleaseBufferTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        for device in VoiceInputDevice.allCases {
            XCTAssertEqual(VoiceReleaseBuffer.load(device, defaults: defaults).effectiveDuration, 1)
        }
        defaults.set(false, forKey: VoiceInputDevice.siriGlass.enabledKey)
        defaults.set(0.7, forKey: VoiceInputDevice.soundcore.durationKey)
        XCTAssertEqual(VoiceReleaseBuffer.load(.siriGlass, defaults: defaults).effectiveDuration, 0)
        XCTAssertEqual(VoiceReleaseBuffer.load(.soundcore, defaults: defaults).effectiveDuration, 0.7)
        XCTAssertEqual(VoiceReleaseBuffer.load(.siriAluminum, defaults: defaults).effectiveDuration, 1)
        for step in 1...20 {
            let value = Double(step) / 10
            XCTAssertEqual(VoiceReleaseBuffer(duration: value).duration, value)
        }
        for bad in [0, -1, 3, .nan, .infinity] {
            XCTAssertEqual(VoiceReleaseBuffer(duration: bad).duration, 1)
        }
    }

    func testRepressCancelAndStaleTimerCannotEndLaterHold() throws {
        var countdown = VoiceReleaseCountdown()
        let first = try XCTUnwrap(countdown.begin(now: 10, duration: 1))
        XCTAssertNil(countdown.begin(now: 10.2, duration: 1), "Duplicate release must not extend recording")
        XCTAssertFalse(countdown.consume(first, now: 10.9))
        XCTAssertTrue(countdown.cancel(), "Re-press keeps the microphone running")
        let second = try XCTUnwrap(countdown.begin(now: 11, duration: 2))
        XCTAssertFalse(countdown.consume(first, now: 12), "Old timer cannot pause the resumed sentence")
        XCTAssertFalse(countdown.consume(second, now: 12.9))
        XCTAssertTrue(countdown.consume(second, now: 13))
        XCTAssertFalse(countdown.consume(second, now: 13.1))
        let cancelled = try XCTUnwrap(countdown.begin(now: 14, duration: 0.1))
        countdown.cancel()
        XCTAssertFalse(countdown.consume(cancelled, now: 15), "Cancel/disconnect bypasses the buffer")
    }
}
