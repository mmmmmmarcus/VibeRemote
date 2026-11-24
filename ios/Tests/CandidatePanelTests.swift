import XCTest
import UIKit
@testable import vvhisper

@MainActor
final class CandidatePanelTests: XCTestCase {
    func testExpansionTargetCoversTrailing56PointsAndAnimationCanBeInterrupted() throws {
        let panel = CandidatePanel(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        panel.show([.init(text: "走查", identifier: "candidate.0", action: .choose(0))], hasMore: false)
        panel.layoutIfNeeded()
        let button = try XCTUnwrap(descendants(panel).first { $0.accessibilityIdentifier == "candidate.expand" } as? UIButton)
        XCTAssertEqual(button.frame.size, CGSize(width: 56, height: 44))
        XCTAssertEqual(button.accessibilityLabel, "Show all candidates")
        for point in [CGPoint(x: 265, y: 2), CGPoint(x: 318, y: 42)] {
            XCTAssertTrue(panel.hitTest(point, with: nil) === button)
        }
        button.sendActions(for: .touchUpInside)
        XCTAssertTrue(panel.isExpanded)
        XCTAssertEqual(button.accessibilityLabel, "Collapse candidates")
        button.sendActions(for: .touchUpInside)
        XCTAssertFalse(panel.isExpanded)
        panel.isHidden = true
        let collection = try XCTUnwrap(descendants(panel).first { $0 is UICollectionView } as? UICollectionView)
        XCTAssertEqual(collection.alpha, 1)
        XCTAssertEqual(collection.transform, .identity)
        panel.setPending(true)
        XCTAssertFalse(button.isEnabled)
    }

    private func descendants(_ view: UIView) -> [UIView] { view.subviews.flatMap { [$0] + descendants($0) } }
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }

    func testVariableWidthRowsWrapWithoutOverlapAndStripScrollsHorizontally() throws {
        let layout = CandidateLayout()
        let collection = UICollectionView(frame: CGRect(x: 0, y: 0, width: 190, height: 180), collectionViewLayout: layout)
        layout.widths = [34, 52, 88, 34, 400, 52]
        layout.prepare()
        XCTAssertGreaterThan(layout.collectionViewContentSize.width, collection.bounds.width)
        XCTAssertEqual(layout.collectionViewContentSize.height, 42)
        layout.expanded = true; layout.prepare()
        XCTAssertEqual(layout.collectionViewContentSize.width, collection.bounds.width)
        let frames = try (0..<6).map { index in
            try XCTUnwrap(layout.layoutAttributesForItem(at: IndexPath(item: index, section: 0))).frame
        }
        XCTAssertEqual(frames[0].minX, 2)
        XCTAssertEqual(frames[0].width, 34)
        XCTAssertEqual(frames[1].width, 52)
        XCTAssertEqual(frames[4].width, 186)
        for (index, frame) in frames.enumerated() {
            XCTAssertLessThanOrEqual(frame.maxX, 188)
            for other in frames.dropFirst(index + 1) { XCTAssertFalse(frame.intersects(other)) }
        }
        XCTAssertGreaterThan(frames.last!.minY, 0)
    }

    func testCollapsedCandidatesDoNotCoverTheTopEdgeOfLandscapeKeys() async throws {
        let oldLanguage = KeyboardLanguage.load(), oldMode = KeyboardLayoutMode.load()
        KeyboardLanguage.chinese.save(); KeyboardLayoutMode.full.save()
        defer { oldLanguage.save(); oldMode.save() }
        for width in [CGFloat(740), CGFloat(900)] {
            await withCheckedContinuation { continuation in
                PinyinEngine.shared.perform(.clear) { _ in continuation.resume() }
            }
            let keyboard = KeyboardViewController()
            keyboard.testingDocumentProxy = TextViewProxy("", selection: NSRange(location: 0, length: 0))
            keyboard.testingLandscape = true
            keyboard.loadViewIfNeeded()
            keyboard.view.frame = CGRect(x: 0, y: 0, width: width, height: 290)
            keyboard.viewDidLayoutSubviews(); keyboard.view.layoutIfNeeded()
            let q = try XCTUnwrap(descendants(keyboard.view).first { $0.accessibilityIdentifier == "keyboard.key.q" } as? KeyControl)
            XCTAssertTrue(q.accessibilityActivate())
            let panel = try XCTUnwrap(descendants(keyboard.view).first { $0 is CandidatePanel } as? CandidatePanel)
            try await waitUntil { !panel.isHidden }
            keyboard.view.layoutIfNeeded()
            let top = q.convert(CGPoint(x: q.bounds.midX, y: 0.5), to: keyboard.view)
            XCTAssertTrue(keyboard.view.hitTest(top, with: nil) === q, "Candidate strip must not cover a letter at width \(width)")
            keyboard.viewWillDisappear(false)
        }
    }

    func testExpandedPanelSelectsActualCandidateAndKeepsBottomKeysAvailable() async throws {
        let oldLanguage = KeyboardLanguage.load(), oldMode = KeyboardLayoutMode.load()
        KeyboardLanguage.chinese.save(); KeyboardLayoutMode.full.save()
        let keyboard = KeyboardViewController()
        let proxy = TextViewProxy("", selection: NSRange(location: 0, length: 0))
        keyboard.testingDocumentProxy = proxy
        keyboard.loadViewIfNeeded(); keyboard.applyKeyboardPreferences(KeyboardPreferences())
        keyboard.view.frame = CGRect(x: 0, y: 0, width: 466, height: 280)
        keyboard.viewDidLayoutSubviews(); keyboard.view.layoutIfNeeded()
        defer { keyboard.viewWillDisappear(false); oldLanguage.save(); oldMode.save() }
        func key(_ value: String) throws -> KeyControl {
            try XCTUnwrap(descendants(keyboard.view).first { $0.accessibilityIdentifier == "keyboard.key.\(value)" } as? KeyControl)
        }
        for letter in "shi" { XCTAssertTrue(try key(String(letter)).accessibilityActivate()) }
        let panel = try XCTUnwrap(descendants(keyboard.view).first { $0 is CandidatePanel } as? CandidatePanel)
        try await waitUntil { proxy.editor.text == "shi" && self.descendants(panel).contains { $0.accessibilityIdentifier == "candidate.0" } }
        let shortcuts = try XCTUnwrap(descendants(keyboard.view).first { $0.accessibilityIdentifier == "keyboard.input-helpers" })
        XCTAssertTrue(shortcuts.isHidden)
        keyboard.view.layoutIfNeeded()
        XCTAssertEqual(panel.frame.minX, 0)
        XCTAssertNil(descendants(keyboard.view).first { $0 is GesturePill })
        let first = try XCTUnwrap(descendants(panel).first { $0.accessibilityIdentifier == "candidate.0" })
        XCTAssertTrue(first.accessibilityTraits.contains(.selected))
        func capture(_ name: String) throws {
            let image = UIGraphicsImageRenderer(bounds: keyboard.view.bounds).image { context in
                UIColor.systemGray5.setFill(); context.fill(keyboard.view.bounds)
                keyboard.view.layer.render(in: context.cgContext)
            }
            let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            try image.pngData()?.write(to: directory.appendingPathComponent(name + ".png"))
        }
        try capture("candidates-collapsed")
        let spelling = proxy.editor.text
        panel.setExpanded(true)
        keyboard.viewDidLayoutSubviews(); keyboard.view.layoutIfNeeded(); panel.layoutIfNeeded()
        let collection = try XCTUnwrap(descendants(panel).first { $0 is UICollectionView } as? UICollectionView)
        // Emoji suggestions can make the first page exceed nine items before
        // the asynchronous absolute-index batch needed below has arrived.
        try await waitUntil { collection.numberOfItems(inSection: 0) > 18 }
        try capture("candidates-expanded")
        XCTAssertEqual(proxy.editor.text, spelling)
        XCTAssertNotNil(proxy.editor.markedTextRange)
        let a = try key("a")
        let aPoint = a.convert(CGPoint(x: a.bounds.midX, y: a.bounds.midY), to: keyboard.view)
        XCTAssertFalse(keyboard.view.hitTest(aPoint, with: nil) is KeyControl)
        XCTAssertNil(descendants(keyboard.view).first { $0 is GesturePill })
        let space = try key("space")
        let spacePoint = space.convert(CGPoint(x: space.bounds.midX, y: space.bounds.midY), to: keyboard.view)
        XCTAssertTrue(keyboard.view.hitTest(spacePoint, with: nil) === space)
        collection.scrollToItem(at: IndexPath(item: 18, section: 0), at: .centeredVertically, animated: false)
        collection.layoutIfNeeded()
        let selected = try XCTUnwrap(descendants(panel).first { $0.accessibilityIdentifier == "candidate.absolute.18" } as? CandidateButton)
        let expected = selected.accessibilityLabel
        XCTAssertTrue(selected.accessibilityActivate())
        try await waitUntil { proxy.editor.markedTextRange == nil }
        XCTAssertEqual(proxy.editor.text, expected)
        XCTAssertFalse(panel.isExpanded)
        XCTAssertTrue(panel.isHidden)
        XCTAssertTrue(shortcuts.isHidden, "Letter pages keep shortcuts hidden after committing")
        keyboard.view.layoutIfNeeded()
        XCTAssertTrue(keyboard.view.hitTest(aPoint, with: nil) === a)
    }

    func testAppendingDoesNotResetScrollAndClearCollapsesPanel() throws {
        let panel = CandidatePanel(frame: CGRect(x: 0, y: 0, width: 320, height: 42))
        let candidates = (0..<50).map { PinyinCandidates.Candidate(text: "候选\($0)", identifier: "candidate.\($0)", action: .chooseAbsolute($0)) }
        panel.show(Array(candidates.prefix(20)), hasMore: false)
        panel.layoutIfNeeded()
        let collection = try XCTUnwrap(descendants(panel).first { $0 is UICollectionView } as? UICollectionView)
        collection.layoutIfNeeded(); collection.contentOffset.x = 150
        panel.show(candidates, hasMore: false, appending: true)
        XCTAssertEqual(collection.contentOffset.x, 150, accuracy: 0.1)
        panel.setExpanded(true)
        XCTAssertTrue(panel.isExpanded)
        panel.show([], hasMore: false)
        XCTAssertFalse(panel.isExpanded)
        XCTAssertEqual(collection.numberOfItems(inSection: 0), 0)
    }
}
