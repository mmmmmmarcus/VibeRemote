import XCTest
@testable import vvhisper

@MainActor final class KeyboardHapticsTests: XCTestCase {
    func testOffRemainsSilentDuringRapidTaps() {
        let feedback = KeyboardHaptics()
        feedback.configure(KeyboardPreferences(hapticStrength: 0))
        feedback.prepare()
        for _ in 0..<80 { feedback.tap() }
        XCTAssertEqual(feedback.verificationCustomStarts, 0)
        XCTAssertEqual(feedback.verificationFallbacks, 0)
        feedback.stop()
    }

    private final class FakePlayer {
        var starts = 0
        var interruptedStarts = 0
        var completion: (@Sendable (Error?) -> Void)?
        var failStart = false
        var player: KeyboardHapticPlayers.Player {
            .init(start: { [self] completion in
                if failStart { throw NSError(domain: "test", code: 42) }
                if self.completion != nil { interruptedStarts += 1 }
                starts += 1; self.completion = completion
            }, clearCompletion: { [self] in completion = nil })
        }
    }

    func testRapidTapsNeverRestartAnUnfinishedPulse() async throws {
        var hardware: [FakePlayer] = []
        let finished = expectation(description: "Every pulse completed")
        finished.expectedFulfillmentCount = 64
        var burstFinished: XCTestExpectation?
        let pool = KeyboardHapticPlayers(makePlayer: {
            let player = FakePlayer(); hardware.append(player); return player.player
        }, completed: { error in XCTAssertNil(error); finished.fulfill(); burstFinished?.fulfill() })
        try pool.prepare()
        // Two-thumb rollover can dispatch several taps in one run-loop turn.
        for _ in 0..<8 {
            let burst = expectation(description: "Burst completed")
            burst.expectedFulfillmentCount = 8; burstFinished = burst
            for _ in 0..<8 { XCTAssertTrue(try pool.play()) }
            XCTAssertFalse(try pool.play(), "Saturation must use the immediate fallback, never restart a pulse")
            for player in hardware { player.completion?(nil) }
            // Drain callbacks before the next burst, with no playback queued by the pool.
            await fulfillment(of: [burst], timeout: 1)
        }
        await fulfillment(of: [finished], timeout: 1)
        XCTAssertEqual(hardware.count, 8)
        XCTAssertEqual(hardware.map(\.starts).reduce(0, +), 64)
        XCTAssertEqual(hardware.map(\.interruptedStarts).reduce(0, +), 0)
    }

    func testLateDuplicateCompletionCannotFreeANewerPulse() async throws {
        let hardware = FakePlayer()
        let finished = expectation(description: "First pulse completed")
        let pool = KeyboardHapticPlayers(capacity: 1, makePlayer: { hardware.player }, completed: { _ in finished.fulfill() })
        try pool.prepare(); XCTAssertTrue(try pool.play())
        let oldCompletion = try XCTUnwrap(hardware.completion)
        oldCompletion(nil)
        await fulfillment(of: [finished], timeout: 1)
        XCTAssertTrue(try pool.play())
        oldCompletion(nil)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(try pool.play())
        pool.cancel()
    }

    func testPreferenceChangeRetiresPlayersWithoutInterruptingTheirPulse() async throws {
        let hardware = FakePlayer()
        let finished = expectation(description: "Original pulse completed")
        var pool: KeyboardHapticPlayers? = KeyboardHapticPlayers(capacity: 1,
            makePlayer: { hardware.player }, completed: { _ in finished.fulfill() })
        try pool?.prepare(); XCTAssertEqual(try pool?.play(), true)
        pool?.retire()
        XCTAssertEqual(try pool?.play(), false)
        XCTAssertEqual(pool?.isPlaying, true)
        hardware.completion?(nil)
        await fulfillment(of: [finished], timeout: 1)
        XCTAssertNil(hardware.completion)
        XCTAssertEqual(pool?.isPlaying, false)
        weak var retainedPool = pool; pool = nil
        XCTAssertNil(retainedPool)
    }

    func testDismissalClearsCallbacksAndDoesNotReplayPendingTaps() async throws {
        let hardware = FakePlayer()
        var completions = 0
        var pool: KeyboardHapticPlayers? = KeyboardHapticPlayers(capacity: 1,
            makePlayer: { hardware.player }, completed: { _ in completions += 1 })
        weak var retainedPool = pool
        try pool?.prepare(); XCTAssertEqual(try pool?.play(), true)
        var lateCompletion = hardware.completion
        pool?.cancel()
        XCTAssertNil(hardware.completion)
        XCTAssertEqual(try pool?.play(), false)
        lateCompletion?(nil)
        lateCompletion = nil; pool = nil
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(completions, 0); XCTAssertEqual(hardware.starts, 1)
        XCTAssertNil(retainedPool)
    }

    func testStartFailurePropagatesImmediatelyForFallback() throws {
        let hardware = FakePlayer(); hardware.failStart = true
        let pool = KeyboardHapticPlayers(capacity: 1, makePlayer: { hardware.player })
        try pool.prepare()
        XCTAssertThrowsError(try pool.play())
        XCTAssertNil(hardware.completion)
        hardware.failStart = false
        XCTAssertTrue(try pool.play())
        pool.cancel()
    }

    func testAsynchronousFailureIsReportedWithoutReplayingTheTap() async throws {
        let hardware = FakePlayer()
        let finished = expectation(description: "Playback error reported")
        let pool = KeyboardHapticPlayers(capacity: 1, makePlayer: { hardware.player }, completed: {
            XCTAssertEqual($0, 43); finished.fulfill()
        })
        try pool.prepare(); XCTAssertTrue(try pool.play())
        hardware.completion?(NSError(domain: "test", code: 43))
        await fulfillment(of: [finished], timeout: 1)
        XCTAssertEqual(hardware.starts, 1)
        XCTAssertNil(hardware.completion)
    }
}
