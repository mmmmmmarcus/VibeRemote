import AppKit
import Carbon.HIToolbox
import XCTest
@testable import VibeRemote

final class ListEditingTests: XCTestCase {
    func testCommandsFollowCurrentStructureWithoutRememberingPreviousPresses() {
        func context(_ structure: ListEditingContext.Structure) -> ListEditingContext {
            .init(structure: structure, selectionLength: 0, spansParagraphs: false, composing: false)
        }
        XCTAssertEqual(ListEditingCommand.plan(.increase, context: context(.paragraph)), .createList)
        XCTAssertNil(ListEditingCommand.plan(.decrease, context: context(.paragraph)))
        XCTAssertEqual(ListEditingCommand.plan(.increase, context: context(.list)), .indent)
        XCTAssertEqual(ListEditingCommand.plan(.decrease, context: context(.list)), .outdent)
        // Manual typing, cursor movement or app switching can change the next observation.
        XCTAssertEqual(ListEditingCommand.plan(.increase, context: context(.paragraph)), .createList)
        for structure in [ListEditingContext.Structure.unknown, .code] {
            XCTAssertNil(ListEditingCommand.plan(.increase, context: context(structure)))
            XCTAssertNil(ListEditingCommand.plan(.decrease, context: context(structure)))
        }
    }

    func testComposingAndMixedParagraphSelectionsAreNotEdited() {
        for direction in [ListEditingDirection.increase, .decrease] {
            for structure in [ListEditingContext.Structure.list, .paragraph] {
                XCTAssertNil(ListEditingCommand.plan(direction, context: .init(structure: structure, selectionLength: 2, spansParagraphs: false, composing: true)))
                XCTAssertNil(ListEditingCommand.plan(direction, context: .init(structure: structure, selectionLength: 12, spansParagraphs: true, composing: false)))
            }
        }
    }

    @MainActor
    func testAXHierarchyUsesAncestorListsAndRejectsUnrelatedPanes() {
        let paragraph = [(role: "AXStaticText", subrole: ""), (role: "AXGroup", subrole: "")]
        let list = paragraph + [(role: "AXList", subrole: "")]
        XCTAssertEqual(ListEditingController.structure(in: paragraph, reachedEditor: true), .paragraph)
        XCTAssertEqual(ListEditingController.structure(in: list, reachedEditor: true), .list)
        XCTAssertEqual(ListEditingController.structure(in: list + [(role: "AXList", subrole: "")], reachedEditor: true), .list)
        XCTAssertEqual(ListEditingController.structure(in: list, reachedEditor: false), .unknown)
        XCTAssertEqual(ListEditingController.structure(in: [], reachedEditor: true), .unknown)
        XCTAssertEqual(ListEditingController.structure(in: list + [(role: "AXGroup", subrole: "AXCodeStyleGroup")], reachedEditor: true), .code)
        XCTAssertEqual(ListEditingController.structure(in: [(role: "AXButton", subrole: "")], reachedEditor: true), .unknown)
    }

    @MainActor
    func testSelectionRangesUseUTF16AndRejectInvalidOrMultilineSelections() {
        let text = "中文👨‍👩‍👧‍👦\n下一行"
        let count = (text as NSString).length
        XCTAssertEqual(ListEditingController.paragraphSpan(text: text, selection: CFRange(location: 2, length: 11)), false)
        XCTAssertEqual(ListEditingController.paragraphSpan(text: text, selection: CFRange(location: 2, length: 12)), true)
        XCTAssertEqual(ListEditingController.paragraphSpan(text: text, selection: CFRange(location: count, length: 0)), false)
        XCTAssertEqual(ListEditingController.paragraphSpan(text: "", selection: CFRange(location: 0, length: 0)), false)
        XCTAssertNil(ListEditingController.paragraphSpan(text: text, selection: CFRange(location: -1, length: 1)))
        XCTAssertNil(ListEditingController.paragraphSpan(text: text, selection: CFRange(location: count, length: 1)))
        XCTAssertNil(ListEditingController.paragraphSpan(text: text, selection: CFRange(location: 1, length: Int.max)))
    }

    func testBothGenerationsUseSameListActionsAndNativeUndoableCommands() {
        for generation in [RemoteGeneration.glassTouchSurface, .aluminumClickpad] {
            for (button, expected) in [("volumeUp", ButtonAction.bulletIndent), ("volumeDown", .bulletOutdent)] {
                let descriptor = remoteButtonDescriptors.first { $0.key == button }!
                XCTAssertEqual(generation.action(for: button, defaultAction: descriptor.defaultAction, siriAction: .spaceKey), expected)
            }
        }
        XCTAssertEqual(ListEditingCommand.createList.key.code, kVK_ANSI_8)
        XCTAssertEqual(ListEditingCommand.createList.key.flags, [.maskShift, .maskCommand])
        XCTAssertEqual(ListEditingCommand.indent.key.code, kVK_Tab)
        XCTAssertEqual(ListEditingCommand.indent.key.flags, [])
        XCTAssertEqual(ListEditingCommand.outdent.key.code, kVK_Tab)
        XCTAssertEqual(ListEditingCommand.outdent.key.flags, .maskShift)
    }
}
