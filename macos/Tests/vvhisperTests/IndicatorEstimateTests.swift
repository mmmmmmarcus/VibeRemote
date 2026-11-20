import AppKit
import XCTest
@testable import vvhisper

/// The dictation cursor's fallbacks for editors without per-character geometry (ChatGPT).
final class IndicatorEstimateTests: XCTestCase {
    private let editor = CGRect(x: 90, y: 490, width: 500, height: 240)

    private func estimate(_ text: String, _ offset: Int, _ leaves: [CaretInsertionPoint.TextLeaf],
                          lineHeight: CGFloat? = nil) -> CGRect? {
        CaretInsertionPoint.estimatedCaret(text: text, offset: offset, leaves: leaves,
                                          editor: editor, fontSize: 16, lineHeight: lineHeight)
    }

    func testExistingTextSupportsCaretBeforeAndInsideText() throws {
        let text = "Already written text"
        let leaf = CaretInsertionPoint.TextLeaf(text: text, frame: CGRect(x: 100, y: 500, width: 200, height: 24))
        let start = try XCTUnwrap(estimate(text, 0, [leaf]))
        let middle = try XCTUnwrap(estimate(text, 8, [leaf]))
        let end = try XCTUnwrap(estimate(text, text.utf16.count, [leaf]))
        XCTAssertEqual(start.minX, 100)
        XCTAssertGreaterThan(middle.minX, start.minX)
        XCTAssertLessThan(middle.minX, end.minX)
        XCTAssertEqual(middle.minY, 500)
        XCTAssertEqual(end.minX, 300)
    }

    func testBlankLinesFollowActualCaretNotLastNonemptyLine() throws {
        let leaf = CaretInsertionPoint.TextLeaf(text: "hello", frame: CGRect(x: 100, y: 500, width: 40, height: 24))
        let text = "hello\n\n"
        let beforeBreak = try XCTUnwrap(estimate(text, 5, [leaf]))
        let firstBlank = try XCTUnwrap(estimate(text, 6, [leaf]))
        let secondBlank = try XCTUnwrap(estimate(text, 7, [leaf]))
        XCTAssertEqual(beforeBreak.minX, 140)
        XCTAssertEqual(beforeBreak.minY, 500)
        XCTAssertEqual(firstBlank.minX, 100)
        XCTAssertEqual(firstBlank.minY, 524)
        XCTAssertEqual(secondBlank.minX, 100)
        XCTAssertEqual(secondBlank.minY, 548)
        // CRLF is one displayed line break, with two UTF-16 units.
        XCTAssertEqual(try XCTUnwrap(estimate("hello\r\n", 7, [leaf])).minY, 524)
        XCTAssertEqual(CaretInsertionPoint.trailingBreaksBeforeCaret(text, offset: 5), 0)
        XCTAssertEqual(CaretInsertionPoint.trailingBreaksBeforeCaret(text, offset: 7), 2)
    }

    func testCaretFindsItsOwnParagraphIncludingEmptyParagraphBetweenLeaves() throws {
        let leaves = [
            CaretInsertionPoint.TextLeaf(text: "first", frame: CGRect(x: 100, y: 500, width: 40, height: 24)),
            CaretInsertionPoint.TextLeaf(text: "second", frame: CGRect(x: 100, y: 548, width: 60, height: 24))
        ]
        let text = "first\n\nsecond\n"
        XCTAssertEqual(try XCTUnwrap(estimate(text, 3, leaves)).minY, 500)
        XCTAssertEqual(try XCTUnwrap(estimate(text, 6, leaves)).minY, 524)
        let second = try XCTUnwrap(estimate(text, 7, leaves))
        XCTAssertEqual(second.minX, 100)
        XCTAssertEqual(second.minY, 548)
        XCTAssertEqual(try XCTUnwrap(estimate(text, 14, leaves)).minY, 572)
    }

    func testWrappedTextAndFollowingBlankLineWithoutPreviouslyLearnedFont() throws {
        let first = "So I was thinking that we should probably", second = "change it"
        let firstWidth = (first as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 16)]).width
        let text = first + " " + second
        let leaf = CaretInsertionPoint.TextLeaf(text: text, frame: CGRect(x: 100, y: 500, width: ceil(firstWidth), height: 48))
        XCTAssertEqual(try XCTUnwrap(estimate(text, 3, [leaf])).minY, 500)
        let lastRow = try XCTUnwrap(estimate(text, first.utf16.count + 1, [leaf]))
        XCTAssertEqual(lastRow.minY, 524)
        XCTAssertEqual(lastRow.minX, 100, accuracy: 1)
        let blank = try XCTUnwrap(estimate(text + "\n", text.utf16.count + 1, [leaf]))
        XCTAssertEqual(blank.minX, 100)
        XCTAssertEqual(blank.minY, 548)
    }

    func testUnicodeOffsetsAndOnlyBlankLines() throws {
        let text = "Hi 👨‍👩‍👧‍👦 café"
        let leaf = CaretInsertionPoint.TextLeaf(text: text, frame: CGRect(x: 100, y: 500, width: 120, height: 24))
        XCTAssertNil(estimate(text, 4, [leaf]), "inside a grapheme is not a valid caret")
        XCTAssertEqual(try XCTUnwrap(estimate(text, text.utf16.count, [leaf])).minX, 220)
        let start = CaretInsertionPoint.editorStart(editor)
        let blank = try XCTUnwrap(estimate("\n\n", 2, []))
        XCTAssertEqual(blank.minX, start.minX)
        XCTAssertEqual(blank.minY, start.minY + 2 * start.height)
    }

    func testStalePartialAndOffscreenLeavesAreRejected() {
        let leaf = CaretInsertionPoint.TextLeaf(text: "old text", frame: CGRect(x: 100, y: 500, width: 100, height: 24))
        XCTAssertNil(estimate("new text", 3, [leaf]))
        XCTAssertNil(estimate("old text plus more", 3, [leaf]))
        XCTAssertNil(estimate("before old text", 3, [leaf]))
        XCTAssertNil(estimate("old text", 3, []))
        let offscreen = CaretInsertionPoint.TextLeaf(text: "old text", frame: CGRect(x: 100, y: 100, width: 100, height: 24))
        XCTAssertNil(estimate("old text", 3, [offscreen]))
        XCTAssertNil(estimate("old text", 3, [leaf], lineHeight: 0))
    }

    /// ChatGPT's placeholder is the element's title/description, not AXPlaceholderValue.
    func testPlaceholderMatchesAnyOfTheElementsLabels() {
        let isPlaceholder = CaretInsertionPoint.isPlaceholder
        XCTAssertTrue(isPlaceholder("Work with Codex\n", [nil, "Work with Codex", "Work with Codex"]))
        XCTAssertTrue(isPlaceholder("Ask anything", ["Ask anything", nil, nil]))
        XCTAssertFalse(isPlaceholder("Work with Codex today", [nil, "Work with Codex", nil]), "real text that starts the same")
        XCTAssertFalse(isPlaceholder("\n", ["", nil, nil]))
        XCTAssertFalse(isPlaceholder("hello", [nil, nil, nil]))
    }

    func testLastParagraphDropsTrailingBreaks() {
        XCTAssertEqual(CaretInsertionPoint.lastParagraph("first\nsecond line\n"), "second line")
        XCTAssertEqual(CaretInsertionPoint.lastParagraph("only"), "only")
        XCTAssertEqual(CaretInsertionPoint.lastParagraph("\n\n"), "")
    }

    func testFontSizeIsLearnedFromOneLineWidth() throws {
        let text = "The quick brown fox jumps"
        let at18 = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 18)]).width
        XCTAssertEqual(try XCTUnwrap(CaretInsertionPoint.fontSize(paragraph: text, renderedWidth: at18)), 18, accuracy: 0.5)
        XCTAssertNil(CaretInsertionPoint.fontSize(paragraph: "Hi", renderedWidth: 14), "too short to tell")
    }

    /// Laid out at the frame's width, the last line ends where the editor's did: on the frame's
    /// last row, at that line's width from the leading edge.
    func testWrappedEndIsOnTheLastRowAtTheLastLinesEnd() throws {
        let font = NSFont.systemFont(ofSize: 16)
        let first = "So I was thinking that we should probably", second = "change it"
        let firstWidth = (first as NSString).size(withAttributes: [.font: font]).width
        let secondWidth = (second as NSString).size(withAttributes: [.font: font]).width
        // A two-row frame exactly as wide as its first line, 24 pt rows.
        let leaf = CGRect(x: 100, y: 500, width: ceil(firstWidth), height: 48)
        let editor = CGRect(x: 90, y: 490, width: 400, height: 80)
        let caret = try XCTUnwrap(CaretInsertionPoint.wrappedEnd(paragraph: first + " " + second, leaf: leaf, editor: editor,
                                                                 fontSize: 16, lineHeight: 24))
        XCTAssertEqual(caret.minY, 524, accuracy: 0.5, "second row")
        XCTAssertEqual(caret.height, 24, accuracy: 0.5)
        XCTAssertEqual(caret.minX, 100 + secondWidth, accuracy: 2)
        // Without a learned line height, the layout's own line count divides the frame.
        let counted = try XCTUnwrap(CaretInsertionPoint.wrappedEnd(paragraph: first + " " + second, leaf: leaf, editor: editor, fontSize: 16))
        XCTAssertEqual(counted.minY, 524, accuracy: 0.5)
        // A one-row frame is textEnd's job, and a position outside the editor is refused.
        XCTAssertNil(CaretInsertionPoint.wrappedEnd(paragraph: first, leaf: CGRect(x: 100, y: 500, width: 300, height: 24), editor: editor, fontSize: 16))
        XCTAssertNil(CaretInsertionPoint.wrappedEnd(paragraph: first + " " + second, leaf: leaf, editor: CGRect(x: 0, y: 0, width: 50, height: 50), fontSize: 16))
    }
}
