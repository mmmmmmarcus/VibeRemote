import XCTest
@testable import vvhisper

@MainActor final class DictationLatencyTests: XCTestCase {
    func testShortTextParity() {
        for text in ["OK", "send it to me", "我知道了", "谢谢你", "don't do that"] { XCTAssertTrue(DictationShortText.skipsPolishing(text)) }
        for text in ["please send it to me", "我们明天再讨论吧", "send this to Marcus 明天"] { XCTAssertFalse(DictationShortText.skipsPolishing(text)) }
    }
    func testBudgetDoesNotWaitForUncooperativeTransport() async {
        var late: CheckedContinuation<String, Never>?
        let request = DictationBudgetTask(seconds: 0.02, fallback: "original") {
            await withCheckedContinuation { late = $0 }
        }
        let value = await request.value()
        XCTAssertEqual(value, "original"); XCTAssertTrue(request.timedOut)
        late?.resume(returning: "late replacement")
        await Task.yield()
        let again = await request.value(); XCTAssertEqual(again, "original")
    }
    func testCancellationResolvesWaiterAndRejectsLateCompletion() async {
        var late: CheckedContinuation<String, Never>?
        let request = DictationBudgetTask(seconds: 10, fallback: "original") {
            await withCheckedContinuation { late = $0 }
        }
        let waiter = Task { await request.value() }
        for _ in 0..<10 { await Task.yield() }
        waiter.cancel()
        let value = await waiter.value; XCTAssertEqual(value, "original")
        late?.resume(returning: "late replacement")
        await Task.yield()
        let again = await request.value(); XCTAssertEqual(again, "original")
    }
    func testFastResponseWinsAndCanBeReused() async {
        let request = DictationBudgetTask(seconds: 1, fallback: "original") { "polished" }
        let first = await request.value(); let second = await request.value()
        XCTAssertEqual(first, "polished"); XCTAssertEqual(second, first); XCTAssertFalse(request.timedOut)
    }
}
