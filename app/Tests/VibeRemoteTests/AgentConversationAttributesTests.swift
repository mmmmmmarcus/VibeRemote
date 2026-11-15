import ApplicationServices
import XCTest
@testable import VibeRemote

final class AgentConversationAttributesTests: XCTestCase {
    private func errorValue(_ error: AXError) -> AXValue {
        var error = error
        return AXValueCreate(.axError, &error)!
    }

    func testCompleteMetadataAllowsOptionalMissingValues() {
        let values: [Any] = ["AXGroup", "", NSNull(), errorValue(.noValue), errorValue(.attributeUnsupported), ["child"]]
        XCTAssertNil(AgentConversationAttributes.failure(in: values, expectedCount: values.count, requiredIndices: [0]))
    }

    func testPartialBatchAndInvalidRequiredIndexAreFailures() {
        XCTAssertEqual(AgentConversationAttributes.failure(in: ["AXGroup"], expectedCount: 2, requiredIndices: [0]), .cannotComplete)
        XCTAssertEqual(AgentConversationAttributes.failure(in: ["AXGroup", "extra"], expectedCount: 1, requiredIndices: [0]), .cannotComplete)
        XCTAssertEqual(AgentConversationAttributes.failure(in: ["AXGroup"], expectedCount: 1, requiredIndices: [1]), .cannotComplete)
    }

    func testRequiredRoleCannotBeNullOrBlank() {
        for value in [NSNull(), "", " \n "] as [Any] {
            XCTAssertEqual(AgentConversationAttributes.failure(in: [value], expectedCount: 1, requiredIndices: [0]), .noValue)
        }
    }

    func testRequiredErrorsPreserveTheirActualStatus() {
        for error in [AXError.noValue, .attributeUnsupported, .cannotComplete, .invalidUIElement, .failure] {
            XCTAssertEqual(AgentConversationAttributes.failure(in: [errorValue(error)], expectedCount: 1, requiredIndices: [0]), error)
        }
    }

    func testOperationalErrorsCannotMasqueradeAsOptionalAbsence() {
        // In particular, an unreadable AXChildren value must not become an empty array.
        for error in [AXError.cannotComplete, .invalidUIElement, .failure, .notImplemented] {
            let values: [Any] = ["AXGroup", errorValue(error)]
            XCTAssertEqual(AgentConversationAttributes.failure(in: values, expectedCount: 2, requiredIndices: [0]), error)
        }
    }

    func testSuccessfulBatchStillRejectsAnEmbeddedChildReadFailure() {
        let values: [Any] = ["AXGroup", errorValue(.noValue), "", "", errorValue(.attributeUnsupported), "group", errorValue(.cannotComplete)]
        XCTAssertEqual(AgentConversationAttributes.failure(in: values, expectedCount: 7, requiredIndices: [0]), .cannotComplete)
    }

    func testOrdinaryAXValuesAreNotErrors() {
        var point = CGPoint(x: 4, y: 5)
        let geometry = AXValueCreate(.cgPoint, &point)!
        let values: [Any] = ["AXGroup", geometry, NSNumber(value: 1), NSArray(array: ["child"])]
        XCTAssertNil(AgentConversationAttributes.failure(in: values, expectedCount: 4, requiredIndices: [0]))
    }

    func testSuccessCodeInsideErrorValueIsMalformed() {
        XCTAssertEqual(AgentConversationAttributes.failure(in: ["AXGroup", errorValue(.success)], expectedCount: 2, requiredIndices: [0]), .cannotComplete)
    }
}
