import Foundation
import XCTest
@testable import vvhisper

final class AgentConversationSectionsTests: XCTestCase {
    private let candidate = CGRect(x: 20, y: 100, width: 180, height: 24)

    private func marker(_ label: String, y: CGFloat, x: CGFloat = 20, width: CGFloat = 180,
                        height: CGFloat = 16, scope: Int = 1) -> AgentConversationSections.Marker {
        .init(label: label, frame: CGRect(x: x, y: y, width: width, height: height), scope: scope)
    }

    private func belongs(_ markers: [AgentConversationSections.Marker], section: String = "Recent",
                         frame: CGRect? = nil, explicit: Bool = false) -> Bool {
        AgentConversationSections.belongs(to: section, candidateFrame: frame ?? candidate, scope: 1,
                                          explicitSection: explicit, markers: markers)
    }

    func testExpandedPopupButtonsAreNotSectionMarkers() {
        for expanded in [false, true] {
            XCTAssertFalse(AgentConversationSections.isMarker(role: "AXButton", expanded: expanded,
                                                              hasPopup: true, popupValue: nil))
            for popup in ["true", "menu", "listbox", "tree", "grid", "dialog", " MENU "] {
                XCTAssertFalse(AgentConversationSections.isMarker(role: "AXButton", expanded: expanded,
                                                                  hasPopup: false, popupValue: popup), popup)
            }
        }
        XCTAssertFalse(AgentConversationSections.isMarker(role: "AXButton", expanded: true,
                                                          hasPopup: true, popupValue: "false"))
    }

    func testDisclosureButtonsAllowMissingOrFalsePopupAttributes() {
        for expanded in [false, true] {
            for hasPopup in [nil, false] as [Bool?] {
                for popup in [nil, "", "false", " FALSE "] as [String?] {
                    XCTAssertTrue(AgentConversationSections.isMarker(role: "AXButton", expanded: expanded,
                                                                     hasPopup: hasPopup, popupValue: popup))
                }
            }
        }
        XCTAssertFalse(AgentConversationSections.isMarker(role: "AXButton", expanded: nil,
                                                          hasPopup: false, popupValue: nil))
        XCTAssertFalse(AgentConversationSections.isMarker(role: "AXGroup", expanded: true,
                                                          hasPopup: false, popupValue: nil))
    }

    func testSemanticHeadingsAndDisclosureTrianglesSurvivePopupMetadata() {
        for role in ["AXHeading", "AXDisclosureTriangle"] {
            XCTAssertTrue(AgentConversationSections.isMarker(role: role, expanded: nil,
                                                             hasPopup: nil, popupValue: nil))
            XCTAssertTrue(AgentConversationSections.isMarker(role: role, expanded: true,
                                                             hasPopup: true, popupValue: "menu"))
        }
    }

    func testPopupButtonCannotCreateOrInterruptSectionBoundary() {
        let observations: [(AgentConversationSections.Marker, String, Bool?, Bool?, String?)] = [
            (marker("Recent", y: 10), "AXHeading", nil, nil, nil),
            (marker("More", y: 70), "AXButton", true, true, "menu")
        ]
        let headings = observations.filter {
            AgentConversationSections.isMarker(role: $0.1, expanded: $0.2, hasPopup: $0.3, popupValue: $0.4)
        }.map { $0.0 }
        XCTAssertTrue(belongs(headings))
        let popupOnly = observations.dropFirst().filter {
            AgentConversationSections.isMarker(role: $0.1, expanded: $0.2, hasPopup: $0.3, popupValue: $0.4)
        }.map { $0.0 }
        XCTAssertFalse(belongs(popupOnly, section: "More"))
    }

    func testNearestPrecedingHeadingDeterminesSectionRegardlessOfArrayOrder() {
        let headings = [marker("Pinned", y: 10), marker("Recent", y: 70)]
        XCTAssertTrue(belongs(headings))
        XCTAssertTrue(belongs(Array(headings.reversed())))
        XCTAssertFalse(belongs(headings, section: "Pinned"))
    }

    func testEveryHeadingPreservesSectionBoundaries() {
        let headings = [marker("Recent", y: 10), marker("Projects", y: 70)]
        XCTAssertFalse(belongs(headings))
        XCTAssertTrue(belongs(headings, section: "Projects"))
        XCTAssertFalse(belongs([marker("Recent", y: 10), marker("", y: 70)]))
    }

    func testOtherNavigationScopesCannotSupplyOrOverrideAHeading() {
        XCTAssertFalse(belongs([marker("Recent", y: 70, scope: 2)]))
        XCTAssertTrue(belongs([marker("Recent", y: 10), marker("Projects", y: 70, scope: 2)]))
    }

    func testHorizontalOverlapIsRequiredAndTouchingEdgesDoNotOverlap() {
        XCTAssertFalse(belongs([marker("Recent", y: 70, x: 200)]))
        XCTAssertFalse(belongs([marker("Recent", y: 70, x: -160)]))
        XCTAssertFalse(belongs([marker("Recent", y: 10), marker("Projects", y: 70, x: 240)]))
        XCTAssertTrue(belongs([marker("Recent", y: 70, x: 199)]))
    }

    func testIndentedRowsCannotSkipAnInterveningShortHeading() {
        let headings = [marker("Recent", y: 100, width: 100, height: 20),
                        marker("Projects", y: 200, width: 30, height: 20)]
        let indented = CGRect(x: 60, y: 230, width: 200, height: 25)
        XCTAssertFalse(belongs(headings, frame: indented))
    }

    func testHeadingMustBeEntirelyAboveCandidateWithOnePointTolerance() {
        XCTAssertTrue(belongs([marker("Recent", y: 85, height: 16)]))
        XCTAssertFalse(belongs([marker("Recent", y: 85.01, height: 16)]))
        XCTAssertFalse(belongs([marker("Recent", y: 105)]))
        XCTAssertFalse(belongs([]))
    }

    func testTiedOrOverlappingHeadingsAreAmbiguousEvenWithEqualLabels() {
        XCTAssertFalse(belongs([marker("Recent", y: 70), marker("Projects", y: 70)]))
        XCTAssertFalse(belongs([marker("Recent", y: 70), marker("Recent", y: 70)]))
        XCTAssertFalse(belongs([marker("Recent", y: 60, height: 30), marker("Projects", y: 70)]))
        XCTAssertFalse(belongs([marker("Recent", y: 70), marker("Projects", y: 69.5)]))
    }

    func testHeadingLabelIsExactAfterSharedNormalizationWithoutSynonyms() {
        XCTAssertTrue(belongs([marker("  RECENT\u{00a0} ", y: 70)]))
        XCTAssertFalse(belongs([marker("Recents", y: 70)]))
        XCTAssertFalse(belongs([marker("Recent conversations", y: 70)]))
        XCTAssertFalse(belongs([marker("Recent", y: 70)], section: " \t "))
        XCTAssertFalse(belongs([marker("Recent", y: 70)], section: "Recent\n"))
    }

    func testInvalidCandidateFramesNeverMatchEvenInsideExplicitSection() {
        let invalid: [CGRect] = [.null, .infinite, .zero,
                                CGRect(x: 0, y: 0, width: -1, height: 10),
                                CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10)]
        for frame in invalid {
            XCTAssertFalse(belongs([marker("Recent", y: 10)], frame: frame))
            XCTAssertFalse(belongs([], frame: frame, explicit: true))
        }
    }

    func testUnknownHeadingGeometryFailsClosedOnlyInRelevantScope() {
        let invalid = AgentConversationSections.Marker(label: "Projects", frame: .null, scope: 1)
        XCTAssertFalse(belongs([marker("Recent", y: 70), invalid]))
        let otherScope = AgentConversationSections.Marker(label: "Projects", frame: .null, scope: 2)
        XCTAssertTrue(belongs([marker("Recent", y: 70), otherScope]))
    }

    func testExplicitContainingSectionWinsOverHeadingGeometry() {
        XCTAssertTrue(belongs([], explicit: true))
        XCTAssertTrue(belongs([marker("Projects", y: 70)], explicit: true))
        XCTAssertTrue(belongs([.init(label: "Projects", frame: .null, scope: 1)], explicit: true))
        XCTAssertFalse(belongs([], section: "", explicit: true))
    }
}
