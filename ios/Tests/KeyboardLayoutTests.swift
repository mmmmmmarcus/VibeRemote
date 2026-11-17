import XCTest
import UIKit

@MainActor
final class KeyboardLayoutTests: XCTestCase {
    func testCandidatesUseTextWidthInsteadOfUniformButtonWidths() {
        let buttons = ["我", "知道", "我知道", "keyboard"].enumerated().map {
            CandidateButton(title: $0.element, identifier: "candidate.\($0.offset)", isDefault: $0.offset == 0)
        }
        let row = UIStackView(arrangedSubviews: buttons)
        row.axis = .horizontal; row.spacing = 6
        let size = row.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        row.frame = CGRect(origin: .zero, size: CGSize(width: size.width, height: 38))
        row.layoutIfNeeded()
        XCTAssertLessThan(buttons[0].bounds.width, 44)
        XCTAssertGreaterThan(buttons[1].bounds.width, buttons[0].bounds.width + 12)
        XCTAssertGreaterThan(buttons[2].bounds.width, buttons[1].bounds.width + 12)
        XCTAssertGreaterThan(buttons[3].bounds.width, buttons[2].bounds.width)
        for button in buttons {
            XCTAssertEqual(button.bounds.width, button.intrinsicContentSize.width, accuracy: 0.5)
        }
        XCTAssertTrue(buttons[0].accessibilityTraits.contains(.selected))
        XCTAssertFalse(buttons[1].accessibilityTraits.contains(.selected))
    }

    func testDuoLandscapeUsesAvailableExtensionWidth() {
        XCTAssertEqual(KeyboardMetrics(width: 529, landscape: true).arrangement, .outerLandscape)
        XCTAssertEqual(KeyboardMetrics(width: 802, landscape: true).arrangement, .innerLandscape)
        XCTAssertEqual(KeyboardMetrics(width: 655, landscape: false).arrangement, .innerPortrait)
    }

    func testKeyboardCanLoadAndRebuildWithoutConstraintException() {
        let controller = KeyboardViewController()
        controller.loadViewIfNeeded()
        for (width, landscape): (CGFloat, Bool) in [(375, false), (466, false), (655, false), (529, true), (802, true), (466, false)] {
            controller.testingLandscape = landscape
            controller.view.frame = CGRect(x: 0, y: 0, width: width, height: 320)
            controller.viewDidLayoutSubviews()
            controller.view.layoutIfNeeded()
            func descendants(_ view: UIView) -> [UIView] {
                view.subviews.flatMap { [$0] + descendants($0) }
            }
            let language = descendants(controller.view).first { $0.accessibilityIdentifier == "keyboard.key.language" }!
            let emoji = descendants(controller.view).first { $0.accessibilityIdentifier == "keyboard.key.globe" }!
            let row = language.superview as! UIStackView
            let languageIndex = row.arrangedSubviews.firstIndex(of: language)!
            XCTAssertTrue(row.arrangedSubviews[languageIndex + 1] === emoji)
            let languageFrame = language.convert(language.bounds, to: controller.view)
            let emojiFrame = emoji.convert(emoji.bounds, to: controller.view)
            XCTAssertLessThan(languageFrame.maxX, emojiFrame.minX)
            XCTAssertEqual(languageFrame.minY, emojiFrame.minY, accuracy: 0.5)
            XCTAssertGreaterThan(languageFrame.width, 35)
            let keys = descendants(controller.view).compactMap { $0 as? KeyControl }
            let enter = keys.first { $0.accessibilityIdentifier == "keyboard.key.return" }!
            XCTAssertEqual(enter.bounds.width, KeyboardMetrics(width: width, landscape: landscape).returnWidth, accuracy: 0.5)
            let delete = keys.first { $0.accessibilityIdentifier == "keyboard.key.delete" }!
            XCTAssertTrue(delete.isDeleteKey)
            XCTAssertNil(delete.onHold)
            XCTAssertNotNil(delete.onDeleteRepeat)
            XCTAssertNotNil(delete.onClearAll)
            controller.setRecordingAppearance(true, voiceVisible: true)
            XCTAssertTrue(keys.allSatisfy { $0.label.isHidden })
            XCTAssertTrue(descendants(controller.view).first { $0.accessibilityIdentifier == "keyboard.voice-status" }!.isHidden)
            controller.setRecordingAppearance(false, voiceVisible: true)
            XCTAssertTrue(keys.allSatisfy { !$0.label.isHidden })
            XCTAssertFalse(descendants(controller.view).first { $0.accessibilityIdentifier == "keyboard.voice-status" }!.isHidden)
            XCTAssertEqual(keys.filter { $0.accessibilityIdentifier == "keyboard.key.return" }.count, 1)
            XCTAssertFalse(keys.contains { $0.accessibilityIdentifier == "keyboard.key.microphone" })
            XCTAssertTrue(keys.contains { $0.accessibilityIdentifier == "keyboard.key.a" })
            if width >= 800 {
                for key in keys {
                    XCTAssertEqual(key.bounds.height, 42.333, accuracy: 0.5, "Split key height: \(key.accessibilityIdentifier ?? "")")
                }
                XCTAssertEqual(keys.filter { $0.accessibilityIdentifier == "keyboard.key.space" }.count, 2)
                XCTAssertEqual(keys.filter { $0.accessibilityIdentifier == "keyboard.key.g" }.count, 2)
                XCTAssertEqual(keys.filter { $0.accessibilityIdentifier == "keyboard.key.v" }.count, 2)
            }
        }
    }

    func testEnterIsWiderWithoutGrowingModeKeyAcrossDuoLayouts() {
        for (width, landscape, minimum, mode): (CGFloat, Bool, CGFloat, CGFloat) in [
            (375, false, 110, 86.075), (466, false, 90, 39.667),
            (655, false, 115, 50.667), (529, true, 100, 45.333), (802, true, 110, 46.667)
        ] {
            let metrics = KeyboardMetrics(width: width, landscape: landscape)
            XCTAssertGreaterThan(metrics.returnWidth, minimum)
            XCTAssertEqual(metrics.modeWidth, mode, accuracy: 0.01)
        }
    }

    func testLayoutChangeStopsHeldDelete() {
        let controller = KeyboardViewController()
        controller.testingDocumentProxy = TextViewProxy("sample", selection: NSRange(location: 6, length: 0))
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 466, height: 320)
        controller.viewDidLayoutSubviews()
        func keys(in view: UIView) -> [KeyControl] {
            view.subviews.flatMap { ($0 as? KeyControl).map { [$0] } ?? keys(in: $0) }
        }
        let delete = keys(in: controller.view).first { $0.isDeleteKey }!
        var repeats = 0
        delete.onDeleteRepeat = { repeats += 1 }
        delete.press(at: 0, point: .zero)
        delete.advancePress(to: 0.4)
        XCTAssertEqual(repeats, 1)
        controller.view.frame.size.width = 850
        controller.viewDidLayoutSubviews()
        XCTAssertFalse(delete.isPressed)
        delete.advancePress(to: 1)
        XCTAssertEqual(repeats, 1)
    }
}
