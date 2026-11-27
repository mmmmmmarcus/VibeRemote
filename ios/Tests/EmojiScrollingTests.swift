import XCTest
import UIKit
@testable import vvhisper

@MainActor final class EmojiScrollingTests: XCTestCase {
    private func descendants(_ view: UIView) -> [UIView] { view.subviews.flatMap { [$0] + descendants($0) } }

    func testCategoryScrollCancelsButtonsWithoutSelectingOrInserting() throws {
        let panel = EmojiPanel(frame: CGRect(x: 0, y: 0, width: 375, height: 260))
        panel.layoutIfNeeded()
        let scroll = try XCTUnwrap(descendants(panel).compactMap { $0 as? EmojiCategoryScrollView }.first)
        let buttons = descendants(scroll).compactMap { $0 as? UIButton }
        XCTAssertGreaterThan(scroll.contentSize.width, scroll.bounds.width)
        XCTAssertTrue(scroll.canCancelContentTouches)
        XCTAssertEqual(scroll.decelerationRate, .normal)
        var insertions = 0
        panel.onSelect = { _ in insertions += 1 }
        let initial = buttons.map { $0.accessibilityTraits.contains(.selected) }
        for button in buttons {
            XCTAssertTrue(scroll.touchesShouldCancel(in: button))
            button.cancelTracking(with: nil)
        }
        XCTAssertEqual(buttons.map { $0.accessibilityTraits.contains(.selected) }, initial)
        XCTAssertEqual(insertions, 0)
        let next = try XCTUnwrap(buttons.first { $0.accessibilityIdentifier == "emoji.category.1" })
        next.sendActions(for: .touchUpInside)
        XCTAssertTrue(next.accessibilityTraits.contains(.selected), "An ordinary tap still selects a category")
        XCTAssertEqual(insertions, 0, "Category selection alone never inserts emoji")
    }

    func testCategoryOffsetNeverAutoCentersOnLayoutOrSelection() throws {
        let panel = EmojiPanel(frame: CGRect(x: 0, y: 0, width: 375, height: 260))
        panel.layoutIfNeeded()
        let scroll = try XCTUnwrap(descendants(panel).compactMap { $0 as? EmojiCategoryScrollView }.first)
        let grid = try XCTUnwrap(descendants(panel).compactMap { $0 as? UICollectionView }.first)
        let count = panel.testingGridInvalidations
        scroll.contentOffset.x = 70
        for _ in 0..<100 {
            panel.setNeedsLayout(); panel.layoutIfNeeded()
            XCTAssertEqual(scroll.contentOffset.x, 70, "Layout must not pull a dragged strip back to its selection")
        }
        XCTAssertEqual(panel.testingGridInvalidations, count)
        let last = try XCTUnwrap(descendants(scroll).compactMap { $0 as? UIButton }.last)
        last.sendActions(for: .touchUpInside)
        panel.layoutIfNeeded()
        XCTAssertEqual(scroll.contentOffset.x, 70, "Selecting a category does not auto-center the strip")
        XCTAssertTrue(last.accessibilityTraits.contains(.selected))
        panel.frame.size.width = 402; panel.layoutIfNeeded()
        XCTAssertEqual(panel.testingGridInvalidations, count + 1)
        XCTAssertEqual(grid.frame.width, 402)
        XCTAssertTrue(last.accessibilityTraits.contains(.selected), "Resizing preserves category selection")
    }
}
