import XCTest
@testable import vvhisper

final class AgentConversationTraversalTests: XCTestCase {
    func testFortyNestedWrappersReachTheConversation() {
        var found: [Int] = []
        let report = AgentConversationTraversal.walk(root: 0, context: false, shouldContinue: { true }) { element, navigation, depth in
            XCTAssertEqual(element, depth)
            if element == 40 {
                XCTAssertTrue(navigation)
                found.append(element)
                return .leaf
            }
            return .children([element + 1], true)
        }
        XCTAssertEqual(found, [40])
        XCTAssertEqual(report.visited, 41)
        XCTAssertEqual(report.maxDepth, 40)
        XCTAssertTrue(report.complete)
    }

    func testDuplicateTitleBeyondOldDepthLimitPreventsUniqueSelection() {
        var candidates: [AgentDecisionCandidate] = []
        let report = AgentConversationTraversal.walk(root: 0, context: (), shouldContinue: { true }) { element, _, _ in
            if element == 0 { return .children([1000, 1], ()) }
            if element == 1000 || element == 40 {
                candidates.append(.init(id: String(element), label: "AIOS 小标"))
                return .leaf
            }
            return .children([element + 1], ())
        }
        XCTAssertTrue(report.complete)
        XCTAssertEqual(candidates.count, 2)
        XCTAssertNil(AgentConversationSelection.exact("AIOS 小标", candidates: candidates))
    }

    func testDepthSixtyFiveIsIncompleteAndDoesNotClaimAnEmptySubtree() {
        let report = AgentConversationTraversal.walk(root: 0, context: (), shouldContinue: { true }) { element, _, _ in
            element == 65 ? .leaf : .children([element + 1], ())
        }
        XCTAssertEqual(report.visited, 65)
        XCTAssertEqual(report.maxDepth, 64)
        XCTAssertEqual(report.depthLimits, 1)
        XCTAssertFalse(report.nodeLimit)
        XCTAssertFalse(report.timeLimit)
        XCTAssertFalse(report.complete)
    }

    func testTwoHundredOneSiblingsFitTheActualNodeBudget() {
        var visited = Set<Int>()
        let report = AgentConversationTraversal.walk(root: 0, context: (), shouldContinue: { true }) { element, _, _ in
            visited.insert(element)
            return element == 0 ? .children(Array(1...201), ()) : .leaf
        }
        XCTAssertEqual(visited, Set(0...201))
        XCTAssertEqual(report.visited, 202)
        XCTAssertTrue(report.complete)
    }

    func testQueuedNodesAreBoundedAcrossAllParents() {
        let report = AgentConversationTraversal.walk(root: 0, context: (), maximumNodes: 6, shouldContinue: { true }) { element, _, _ in
            if element == 0 { return .children([1, 2, 3], ()) }
            return .children([element * 10 + 1, element * 10 + 2], ())
        }
        XCTAssertEqual(report.visited, 6)
        XCTAssertTrue(report.nodeLimit)
        XCTAssertFalse(report.complete)
    }

    func testCyclesAndSharedChildrenAreVisitedOnce() {
        var order: [Int] = []
        let report = AgentConversationTraversal.walk(root: 0, context: (), shouldContinue: { true }) { element, _, _ in
            order.append(element)
            switch element {
            case 0: return .children([1, 1, 2], ())
            case 1: return .children([0, 2], ())
            default: return .children([1], ())
            }
        }
        XCTAssertEqual(order, [0, 1, 2])
        XCTAssertTrue(report.complete)
    }

    func testUnavailableNodeCannotProveUniqueTarget() {
        let report = AgentConversationTraversal.walk(root: 0, context: (), shouldContinue: { true }) { element, _, _ in
            if element == 0 { return .children([1, 2], ()) }
            return element == 1 ? .leaf : .unavailable
        }
        XCTAssertEqual(report.visited, 3)
        XCTAssertEqual(report.readFailures, 1)
        XCTAssertFalse(report.complete)
    }

    func testExpiredBudgetDoesNotVisitRoot() {
        let report = AgentConversationTraversal.walk(root: 0, context: (), shouldContinue: { false }) { _, _, _ in
            XCTFail("An expired scan must not issue another read")
            return .leaf
        }
        XCTAssertEqual(report.visited, 0)
        XCTAssertTrue(report.timeLimit)
        XCTAssertFalse(report.complete)
    }

    func testDeadlineAlsoStopsWideChildExpansion() {
        var budgetChecks = 0
        let report = AgentConversationTraversal.walk(root: 0, context: (), shouldContinue: {
            budgetChecks += 1
            return budgetChecks < 5
        }) { element, _, _ in
            XCTAssertEqual(element, 0)
            return .children(Array(1...500), ())
        }
        XCTAssertEqual(report.visited, 1)
        XCTAssertTrue(report.timeLimit)
        XCTAssertFalse(report.complete)
    }
}
