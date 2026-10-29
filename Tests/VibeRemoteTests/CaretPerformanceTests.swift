import XCTest
@testable import VibeRemote

final class CaretPerformanceTests: XCTestCase {
    private final class Probe: @unchecked Sendable {
        let lock = NSLock()
        var requests: [Int] = []
        var onMain: [Bool] = []
        func read(_ value: Int) -> Int {
            lock.lock(); requests.append(value); onMain.append(Thread.isMainThread); lock.unlock()
            // Deliberately slower than a display frame, like a slow AX provider.
            Thread.sleep(forTimeInterval: 0.04)
            return value
        }
        func snapshot() -> ([Int], [Bool]) {
            lock.lock(); defer { lock.unlock() }; return (requests, onMain)
        }
    }

    @MainActor
    func testSlowReadsDoNotBlockUIAndCoalesceLatestMotion() async {
        let baseline = Probe()
        let baselineStart = ProcessInfo.processInfo.systemUptime
        for value in 0...20 { _ = baseline.read(value) }
        let serialElapsed = ProcessInfo.processInfo.systemUptime - baselineStart
        let probe = Probe()
        let pipeline = CaretQueryPipeline<Int, Int> { probe.read($0) }
        let completed = expectation(description: "Latest movement read")
        var replies: [Int] = []
        let start = ProcessInfo.processInfo.systemUptime
        pipeline.submit(0) { replies.append($0) }
        for value in 1...20 {
            pipeline.submit(value) {
                replies.append($0)
                if $0 == 20 { completed.fulfill() }
            }
        }
        let enqueueElapsed = ProcessInfo.processInfo.systemUptime - start
        await fulfillment(of: [completed], timeout: 3)
        let (reads, wasMain) = probe.snapshot()
        XCTAssertEqual(reads, [0, 20], "Intermediate gestures must not build an AX backlog")
        XCTAssertEqual(replies, [0, 20])
        XCTAssertTrue(wasMain.allSatisfy { !$0 }, "Provider calls must never run on UI thread")
        // Both paths use the same 21 requests and measured 40ms provider fixture.
        // Before: UI serially waits for every read. After: enqueue does not wait.
        XCTAssertLessThan(enqueueElapsed, 0.04)
        XCTAssertEqual(baseline.snapshot().0.count, 21)
        XCTAssertTrue(baseline.snapshot().1.allSatisfy { $0 })
        print("Caret fixture: 21 motions, 40ms provider; measured sync main-thread=\(serialElapsed * 1000)ms; measured enqueue=\(enqueueElapsed * 1000)ms; background reads=\(reads.count)")
    }

    @MainActor
    func testCancellationDropsInflightAndPendingResultsBeforeReentry() async {
        let probe = Probe()
        let pipeline = CaretQueryPipeline<Int, Int> { probe.read($0) }
        let completed = expectation(description: "New contact completed")
        var replies: [Int] = []
        pipeline.submit(1) { replies.append($0) }
        pipeline.submit(2) { replies.append($0) }
        // Lift/cancel/commit invalidates replies, not just the latest pending aim.
        pipeline.invalidate()
        pipeline.submit(3) { replies.append($0); completed.fulfill() }
        await fulfillment(of: [completed], timeout: 3)
        XCTAssertEqual(probe.snapshot().0, [1, 3])
        XCTAssertEqual(replies, [3], "A cancelled contact cannot move or resurrect its overlay")
    }

    @MainActor
    func testFullEntryRejectsPreparationReplyForPreviousEditor() async {
        struct Snapshot: Sendable { let editor: Int; let isValid: Bool }
        let pipeline = CaretQueryPipeline<Snapshot, Snapshot> {
            Thread.sleep(forTimeInterval: 0.04)
            return $0
        }
        let active = expectation(description: "Recaptured full-mode editor")
        var editor = 1
        var cancelled = false
        pipeline.submit(.init(editor: 1, isValid: false)) { result in
            if !result.isValid { cancelled = true }
            editor = result.editor
        }
        // Threshold entry rotates the query epoch before recapturing the editor.
        pipeline.invalidate()
        editor = 2
        pipeline.submit(.init(editor: 2, isValid: true)) { result in
            if !result.isValid { cancelled = true }
            editor = result.editor
            active.fulfill()
        }
        await fulfillment(of: [active], timeout: 3)
        XCTAssertFalse(cancelled, "An old preparation failure cannot cancel successful full entry")
        XCTAssertEqual(editor, 2, "Old preparation geometry cannot overwrite a recaptured editor")
    }

    @MainActor
    func testCommitInvalidationCannotDeliverLateGeometry() async {
        let probe = Probe()
        let pipeline = CaretQueryPipeline<Int, Int> { probe.read($0) }
        let late = expectation(description: "Stale post-commit geometry")
        late.isInverted = true
        pipeline.submit(1) { _ in late.fulfill() }
        pipeline.invalidate()
        await fulfillment(of: [late], timeout: 0.15)
        XCTAssertEqual(probe.snapshot().0, [1])
    }
    @MainActor
    func testCancellationClearsWorkerCacheAfterInflightRead() async {
        final class Cache: @unchecked Sendable {
            let lock = NSLock()
            var retained = false
            var reading = false
            var clearedDuringRead = false
            func read() -> Int {
                lock.lock(); reading = true; retained = true; lock.unlock()
                Thread.sleep(forTimeInterval: 0.04)
                lock.lock(); reading = false; lock.unlock()
                return 1
            }
            func clear() {
                lock.lock(); defer { lock.unlock() }
                clearedDuringRead = reading; retained = false
            }
            func snapshot() -> (Bool, Bool) {
                lock.lock(); defer { lock.unlock() }; return (retained, clearedDuringRead)
            }
        }
        let cache = Cache()
        let cleared = expectation(description: "Session cache released")
        let pipeline = CaretQueryPipeline<Int, Int>(clear: { cache.clear(); cleared.fulfill() }) { _ in cache.read() }
        pipeline.submit(1) { _ in XCTFail("Cancelled read must not reach UI") }
        pipeline.invalidate()
        await fulfillment(of: [cleared], timeout: 3)
        XCTAssertFalse(cache.snapshot().0, "No editor or marker cache may survive session cancellation")
        XCTAssertFalse(cache.snapshot().1, "Cleanup must use the same serial worker as the read")
    }

}
