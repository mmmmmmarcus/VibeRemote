import XCTest
@testable import VibeRemote

final class AgentRoutingTests: XCTestCase {
    @MainActor
    func testDirectCommandCompletesWithoutReadingKeyOrStartingPlanner() async {
        let done = expectation(description: "completed")
        var keyReads = 0
        var plans: [AgentLocalPlan] = []
        let run = AgentRun(onEvent: { event in
            if case .finished(let text) = event { XCTAssertEqual(text, "Opened Notes."); done.fulfill() }
        }, localExecutor: { plan in
            plans.append(plan)
            return .completed("Opened Notes.")
        }, apiKey: { keyReads += 1; return nil })
        run.start(command: "Open Notes", context: .init(), settings: .init())
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(plans, [.activate(app: "Notes")])
        XCTAssertEqual(keyReads, 0)
    }

    @MainActor
    func testUncertainLocalDispatchNeverFallsThroughToPlanner() async {
        let done = expectation(description: "failed")
        var keyReads = 0
        let run = AgentRun(onEvent: { event in
            if case .failed(let text) = event { XCTAssertEqual(text, "Uncertain delivery"); done.fulfill() }
        }, localExecutor: { _ in .failed("Uncertain delivery") }, apiKey: { keyReads += 1; return nil })
        run.start(command: "Open Notes", context: .init(), settings: .init())
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(keyReads, 0)
    }

    @MainActor
    func testUnsupportedCommandRequiresOpenRouterRatherThanLegacyCLI() async {
        let done = expectation(description: "missing key")
        var localCalls = 0
        let run = AgentRun(onEvent: { event in
            if case .failed(let text) = event { XCTAssertTrue(text.contains("OpenRouter")); done.fulfill() }
        }, localExecutor: { _ in localCalls += 1; return .completed("unexpected") }, apiKey: { nil })
        run.start(command: "Compare these two documents", context: .init(), settings: .init(backend: .codex))
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(localCalls, 0)
    }

    @MainActor
    func testStopIgnoresLateLocalCompletionAndNeverStartsFallback() async {
        let entered = expectation(description: "executor started")
        let returned = expectation(description: "executor returned")
        var events: [AgentEvent] = []
        var keyReads = 0
        let run = AgentRun(onEvent: { events.append($0) }, localExecutor: { _ in
            entered.fulfill()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            returned.fulfill()
            return .unhandled("late fallback")
        }, apiKey: { keyReads += 1; return nil })
        run.start(command: "Open Notes", context: .init(), settings: .init())
        await fulfillment(of: [entered], timeout: 2)
        run.stop()
        await fulfillment(of: [returned], timeout: 2)
        await Task.yield()
        XCTAssertEqual(events.filter { if case .failed = $0 { return true }; if case .finished = $0 { return true }; return false }, [.failed("Stopped.")])
        XCTAssertEqual(keyReads, 0)
    }

    @MainActor
    func testExactConversationCompletesWithoutReadingKeyOrStartingPlanner() async {
        let done = expectation(description: "conversation completed")
        var events: [AgentEvent] = []
        var plans: [AgentLocalPlan] = []
        var titles: [String] = []
        var keyReads = 0
        let run = AgentRun(onEvent: { event in
            events.append(event)
            if case .finished = event { done.fulfill() }
            if case .failed = event { done.fulfill() }
        }, localExecutor: { plan in
            plans.append(plan)
            return .completed("Opened ChatGPT.")
        }, conversationExecutor: { title in
            titles.append(title)
            return .completed("Opened the conversation.")
        }, apiKey: { keyReads += 1; return nil })
        run.start(command: "Open the conversation \"AIOS 小标\" in ChatGPT", context: .init(), settings: .init())
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(plans, [.activate(app: "ChatGPT")])
        XCTAssertEqual(titles, ["AIOS 小标"])
        XCTAssertEqual(events.filter { if case .failed = $0 { return true }; if case .finished = $0 { return true }; return false },
                       [.finished("Opened the conversation.")])
        XCTAssertEqual(keyReads, 0)
    }

    @MainActor
    func testUncertainConversationSelectionNeverFallsThroughToPlanner() async {
        let done = expectation(description: "conversation failed")
        var events: [AgentEvent] = []
        var conversationCalls = 0
        var keyReads = 0
        let run = AgentRun(onEvent: { event in
            events.append(event)
            if case .finished = event { done.fulfill() }
            if case .failed = event { done.fulfill() }
        }, localExecutor: { _ in .completed("Opened ChatGPT.") }, conversationExecutor: { title in
            XCTAssertEqual(title, "AIOS 小标")
            conversationCalls += 1
            return .failed("Selection sent but could not be verified.")
        }, apiKey: { keyReads += 1; return nil })
        run.start(command: "Open the conversation \"AIOS 小标\" in ChatGPT", context: .init(), settings: .init())
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(conversationCalls, 1)
        XCTAssertEqual(events.filter { if case .failed = $0 { return true }; if case .finished = $0 { return true }; return false },
                       [.failed("Selection sent but could not be verified.")])
        XCTAssertEqual(keyReads, 0)
    }

    @MainActor
    func testStopCancelsConversationAndIgnoresLateCompletionOrFallback() async {
        let lateResults: [AgentLocalActions.Outcome] = [.completed("Late completion"), .unhandled("Late fallback")]
        for result in lateResults {
            let entered = expectation(description: "conversation executor started")
            let returned = expectation(description: "conversation executor returned")
            var events: [AgentEvent] = []
            var keyReads = 0
            let run = AgentRun(onEvent: { events.append($0) }, localExecutor: { _ in
                .completed("Opened ChatGPT.")
            }, conversationExecutor: { _ in
                entered.fulfill()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                XCTAssertTrue(Task.isCancelled)
                returned.fulfill()
                return result
            }, apiKey: { keyReads += 1; return nil })
            run.start(command: "Open the conversation \"AIOS 小标\" in ChatGPT", context: .init(), settings: .init())
            await fulfillment(of: [entered], timeout: 2)
            run.stop()
            await fulfillment(of: [returned], timeout: 2)
            await Task.yield()
            XCTAssertEqual(events.filter { if case .failed = $0 { return true }; if case .finished = $0 { return true }; return false },
                           [.failed("Stopped.")])
            XCTAssertEqual(keyReads, 0)
        }
    }
}
