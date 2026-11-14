import AppKit
import XCTest
@testable import VibeRemote

/// The dictation cursor's fallbacks for editors without per-character geometry (ChatGPT).
final class IndicatorEstimateTests: XCTestCase {
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
