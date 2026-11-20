import AppKit
import ApplicationServices
import XCTest
@testable import vvhisper

final class DictationDraftUnderlineTests: XCTestCase {
    func testOnlyThisHoldsDraftBeforeCaretIsMarked() {
        let value = "Existing words. New draft"
        XCTAssertEqual(DictationDraftGeometry.range(value: value, selection: CFRange(location: value.utf16.count, length: 0),
                                                   anchor: 16, draft: "New draft"), NSRange(location: 16, length: 9))
        XCTAssertNil(DictationDraftGeometry.range(value: value, selection: CFRange(location: 8, length: 0), anchor: 16, draft: "New draft"))
        XCTAssertNil(DictationDraftGeometry.range(value: value, selection: CFRange(location: 16, length: 9), anchor: 16, draft: "New draft"))
        XCTAssertNil(DictationDraftGeometry.range(value: value, selection: CFRange(location: 25, length: 0), anchor: 16, draft: "old draft"))
        XCTAssertNil(DictationDraftGeometry.range(value: value, selection: CFRange(location: 50, length: 0), anchor: 16, draft: "New draft"))
        XCTAssertNil(DictationDraftGeometry.range(value: value, selection: CFRange(location: 25, length: 0), anchor: 16, draft: ""))
    }

    func testAReadMayLagBehindTheNextTypedChunk() {
        let value = "Before. live draft continues"
        XCTAssertEqual(DictationDraftGeometry.range(value: value, selection: CFRange(location: value.utf16.count, length: 0),
                                                   anchor: 8, draft: "live draft"), NSRange(location: 8, length: 10))
        XCTAssertNil(DictationDraftGeometry.range(value: "Changed. live draft continues",
            selection: CFRange(location: 29, length: 0), anchor: 8, draft: "live draft"))
    }

    @MainActor
    func testLateGeometryCannotResurrectCancelledUnderline() throws {
        var reply: (@MainActor @Sendable ([CGRect]?) -> Void)?
        let overlay = DictationDraftUnderline(read: { _, completion in reply = completion }, isFrontmost: { _ in true })
        overlay.update(.init(pid: 0, element: AXUIElementCreateApplication(0), anchor: 0, text: "draft"))
        let callback = try XCTUnwrap(reply)
        overlay.hide()
        callback([CGRect(x: 100, y: 200, width: 100, height: 1)])
        XCTAssertNil(overlay.panel, "a cancelled hold must not create or show a window from a stale read")
    }

    @MainActor
    func testFocusChangeDropsAnInFlightUnderline() throws {
        var reply: (@MainActor @Sendable ([CGRect]?) -> Void)?
        var frontmost = true
        let overlay = DictationDraftUnderline(read: { _, completion in reply = completion }, isFrontmost: { _ in frontmost })
        overlay.update(.init(pid: 0, element: AXUIElementCreateApplication(0), anchor: 0, text: "draft"))
        let callback = try XCTUnwrap(reply)
        frontmost = false
        callback([CGRect(x: 100, y: 200, width: 100, height: 1)])
        XCTAssertNil(overlay.panel)
        overlay.hide()
    }

    @MainActor
    func testOverlayDoesNotTakeInputAndReleasesItsWindow() throws {
        let overlay = DictationDraftUnderline(read: { _, completion in
            completion([CGRect(x: 100, y: 200, width: 100, height: 1)])
        }, present: false, isFrontmost: { _ in true })
        overlay.update(.init(pid: 0, element: AXUIElementCreateApplication(0), anchor: 0, text: "draft"))
        let panel = try XCTUnwrap(overlay.panel)
        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertFalse(panel.isVisible)
        XCTAssertEqual(panel.frame.width, 102)
        overlay.hide()
        XCTAssertNil(overlay.panel)
        XCTAssertFalse(panel.isVisible)
    }

    func testUnicodeAndParagraphOffsetDriftRequireExactDraft() {
        let value = "Earlier\n\n你好 👋🏽"
        let end = value.utf16.count
        XCTAssertEqual(DictationDraftGeometry.range(value: value, selection: CFRange(location: end, length: 0),
                                                   anchor: 8, draft: "你好 👋🏽"), NSRange(location: 9, length: end - 9))
        XCTAssertNil(DictationDraftGeometry.range(value: value, selection: CFRange(location: end - 1, length: 0),
                                                 anchor: 8, draft: "你好 👋🏽"))
    }

    func testSingleLineUnderlineExcludesPreexistingText() throws {
        let text = "Existing words. New draft"
        let frame = CGRect(x: 100, y: 200, width: 250, height: 24)
        let rects = try XCTUnwrap(DictationDraftGeometry.estimatedRects(value: text,
            range: NSRange(location: 16, length: 9), leaves: [.init(text: text, frame: frame)]))
        XCTAssertEqual(rects.count, 1)
        XCTAssertGreaterThan(rects[0].minX, frame.minX + 100)
        XCTAssertEqual(rects[0].maxX, frame.maxX, accuracy: 1)
        XCTAssertEqual(rects[0].maxY, frame.maxY, accuracy: 1)
    }

    func testDraftWrapsIntoSeparateUnderlines() throws {
        let first = "So I was thinking that we should probably", second = "change it"
        let text = first + " " + second
        let width = ceil((first as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 16)]).width)
        let frame = CGRect(x: 100, y: 500, width: width, height: 48)
        let rects = try XCTUnwrap(DictationDraftGeometry.estimatedRects(value: text,
            range: NSRange(location: 10, length: text.utf16.count - 10), leaves: [.init(text: text, frame: frame)]))
        XCTAssertEqual(rects.count, 2)
        XCTAssertGreaterThan(rects[0].minX, frame.minX)
        XCTAssertEqual(rects[0].maxY, 524, accuracy: 1)
        XCTAssertEqual(rects[1].minX, frame.minX, accuracy: 1)
        XCTAssertEqual(rects[1].maxY, 548, accuracy: 1)
        XCTAssertLessThan(rects[1].width, frame.width / 2)
    }

    func testDraftAfterEmptyLineAndStaleLeafRejection() throws {
        let value = "Before\n\nNew draft\n"
        let leaves: [CaretInsertionPoint.TextLeaf] = [
            .init(text: "Before", frame: CGRect(x: 100, y: 200, width: 80, height: 24)),
            .init(text: "New draft", frame: CGRect(x: 100, y: 248, width: 90, height: 24))
        ]
        let range = NSRange(location: 8, length: 9)
        let rects = try XCTUnwrap(DictationDraftGeometry.estimatedRects(value: value, range: range, leaves: leaves))
        XCTAssertEqual(rects.count, 1)
        XCTAssertEqual(rects[0].minY, 248, accuracy: 1)
        XCTAssertNil(DictationDraftGeometry.estimatedRects(value: "Changed\n\nNew draft\n", range: range, leaves: leaves))
        XCTAssertNil(DictationDraftGeometry.estimatedRects(value: value, range: range, leaves: Array(leaves.prefix(1))))
    }

    func testUnderlinesClipToEditorWithoutClampingOffscreenRows() {
        let editor = CGRect(x: 100, y: 200, width: 100, height: 48)
        let lines = DictationDraftGeometry.strokes([
            CGRect(x: 90, y: 200, width: 150, height: 24),
            CGRect(x: 100, y: 176, width: 80, height: 24),
            CGRect(x: 100, y: 248, width: 80, height: 24)
        ], editor: editor)
        XCTAssertEqual(lines, [CGRect(x: 100, y: 223, width: 100, height: 1)])
    }
}
