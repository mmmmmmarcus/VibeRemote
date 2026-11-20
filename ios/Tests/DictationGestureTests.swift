import XCTest
import UIKit
@testable import vvhisper

@MainActor
final class DictationGestureTests: XCTestCase {
    private func descendants(_ view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
    private func key(_ value: String, in keyboard: KeyboardViewController) throws -> KeyControl {
        try XCTUnwrap(descendants(keyboard.view).compactMap { $0 as? KeyControl }.first { $0.value == value })
    }
    private func withKeyboard(width: CGFloat = 466, landscape: Bool = false,
                              _ body: (KeyboardViewController, TextViewProxy) throws -> Void) rethrows {
        let previous = UserDefaults.standard.string(forKey: KeyboardLanguage.preferenceKey)
        KeyboardLanguage.english.save()
        let proxy = TextViewProxy("keep ", selection: NSRange(location: 5, length: 0))
        let keyboard = KeyboardViewController()
        proxy.returnKeyType = .send
        keyboard.testingDocumentProxy = proxy; keyboard.testingVoiceAvailable = true
        keyboard.testingLandscape = landscape
        keyboard.loadViewIfNeeded()
        keyboard.view.frame = CGRect(x: 0, y: 0, width: width, height: KeyboardMetrics(width: width, landscape: landscape).contentHeight)
        keyboard.viewDidLayoutSubviews(); keyboard.view.layoutIfNeeded()
        defer {
            keyboard.viewWillDisappear(false)
            if let previous { UserDefaults.standard.set(previous, forKey: KeyboardLanguage.preferenceKey) }
            else { UserDefaults.standard.removeObject(forKey: KeyboardLanguage.preferenceKey) }
        }
        try body(keyboard, proxy)
    }
    private func start(_ keyboard: KeyboardViewController) throws -> (KeyControl, UUID) {
        let letter = try key("a", in: keyboard)
        XCTAssertTrue(letter.press(at: 0, point: CGPoint(x: letter.bounds.midX, y: letter.bounds.midY)))
        letter.advancePress(to: 0.4)
        let command = try XCTUnwrap(keyboard.testingVoiceCommands.last)
        XCTAssertEqual(command.phase, .recording)
        return (letter, command.id)
    }
    private func reply(_ id: UUID, _ text: String, step: Double, final: Bool = false, error: String? = nil) -> VoiceReply {
        VoiceReply(id: id, text: text, isFinal: final, error: error, updatedAt: Date().addingTimeInterval(-0.5 + step * 0.01))
    }
    private func preview(_ id: UUID, keyboard: KeyboardViewController) {
        keyboard.receiveVoiceReply(reply(id, "spoken text", step: 1))
        keyboard.receiveVoiceReply(reply(id, "spoken text continues", step: 2))
    }

    func testTypingPressCancelsPolishBeforeReleaseAndKeepsEdit() throws {
        try withKeyboard { keyboard, proxy in
            let (source, id) = try start(keyboard)
            preview(id, keyboard: keyboard)
            source.releasePress()
            XCTAssertEqual(keyboard.testingVoiceCommands.last?.phase, .finish)
            let letter = try key("b", in: keyboard)
            XCTAssertTrue(letter.press(at: 1, point: CGPoint(x: letter.bounds.midX, y: letter.bounds.midY)))
            XCTAssertEqual(keyboard.testingVoiceCommands.last?.phase, .cancel)
            XCTAssertNil(proxy.editor.markedTextRange)
            let visible = proxy.editor.text
            XCTAssertFalse(keyboard.receiveVoiceReply(reply(id, "Late replacement.", step: 3, final: true)))
            XCTAssertEqual(proxy.editor.text, visible)
            letter.releasePress()
            XCTAssertEqual(proxy.editor.text, visible! + "b")
        }
    }
    private func slide(_ source: KeyControl, into target: KeyControl) {
        let point = source.convert(CGPoint(x: target.bounds.midX, y: target.bounds.midY), from: target)
        XCTAssertTrue(source.movePress(to: point, at: 0.5))
    }

    func testOnlyLetterKeysOwnDictationHoldsAcrossAllLayoutsAndSymbolPages() throws {
        for (width, landscape): (CGFloat, Bool) in [(375, false), (466, false), (655, false), (529, true), (802, true)] {
            try withKeyboard(width: width, landscape: landscape) { keyboard, _ in
                for page in 0..<3 {
                    let controls = descendants(keyboard.view).compactMap { $0 as? KeyControl }
                    for control in controls {
                        let letter = page == 0 && control.value.count == 1 && control.value.first?.isASCII == true && control.value.first?.isLetter == true
                        let symbol = page > 0 && !KeyboardSymbols.alternatives(for: control.value).isEmpty
                        XCTAssertEqual(control.onHold != nil, letter || symbol || ["space", "language"].contains(control.value), control.value)
                        XCTAssertNotNil(control.onGapHold, control.value)
                        XCTAssertNotNil(control.onHoldMove, control.value)
                    }
                    if page < 2 { _ = try key(page == 0 ? "123" : "#+=", in: keyboard).accessibilityActivate() }
                }
                XCTAssertTrue(keyboard.testingVoiceCommands.isEmpty)
            }
        }
    }

    func testHoldingFunctionKeysKeepsTheirNormalSingleTapBehavior() throws {
        for value in ["shift", "return", "123"] {
            try withKeyboard { keyboard, proxy in
                let function = try key(value, in: keyboard)
                function.press(at: 0, point: .zero); function.advancePress(to: 1)
                XCTAssertTrue(keyboard.testingVoiceCommands.isEmpty)
                function.releasePress()
                XCTAssertTrue(keyboard.testingVoiceCommands.isEmpty)
                switch value {
                case "return": XCTAssertEqual(proxy.editor.text, "keep \n")
                case "shift": XCTAssertEqual(try key("a", in: keyboard).label.text, "A")
                default: XCTAssertNotNil(try key("1", in: keyboard))
                }
            }
        }
    }

    func testLanguageHoldConsumesTapWithoutStartingDictation() throws {
        try withKeyboard { keyboard, _ in
            let language = try key("language", in: keyboard)
            let original = language.accessibilityLabel
            XCTAssertNotNil(language.onSystemKeyboard)
            language.press(at: 0, point: .zero); language.advancePress(to: 1); language.releasePress()
            XCTAssertEqual(language.accessibilityLabel, original)
            XCTAssertTrue(keyboard.testingVoiceCommands.isEmpty)
            language.press(at: 2, point: .zero); language.releasePress()
            XCTAssertNotEqual(try key("language", in: keyboard).accessibilityLabel, original)
        }
    }

    func testGapHoldsStartVoiceWithoutFunctionActionsAcrossEveryLayout() throws {
        for (width, landscape): (CGFloat, Bool) in [(375, false), (466, false), (655, false), (529, true), (802, true)] {
            try withKeyboard(width: width, landscape: landscape) { keyboard, proxy in
                let q = try key("q", in: keyboard), w = try key("w", in: keyboard)
                let a = try key("a", in: keyboard), delete = try key("delete", in: keyboard)
                let enter = try key("return", in: keyboard)
                let qFrame = q.convert(q.bounds, to: keyboard.view), wFrame = w.convert(w.bounds, to: keyboard.view)
                let aFrame = a.convert(a.bounds, to: keyboard.view)
                let points = [
                    CGPoint(x: (qFrame.maxX + wFrame.minX) / 2, y: qFrame.midY),
                    CGPoint(x: aFrame.midX, y: (qFrame.maxY + aFrame.minY) / 2),
                    delete.convert(CGPoint(x: -1, y: delete.bounds.midY), to: keyboard.view),
                    enter.convert(CGPoint(x: -1, y: enter.bounds.midY), to: keyboard.view)
                ]
                for point in points {
                    let source = try XCTUnwrap(keyboard.view.hitTest(point, with: nil) as? KeyControl)
                    XCTAssertTrue(source.press(at: 0, point: source.convert(point, from: keyboard.view)))
                    XCTAssertTrue(source.isGapPress)
                    source.advancePress(to: 0.4)
                    XCTAssertEqual(keyboard.testingVoiceCommands.last?.phase, .recording)
                    XCTAssertEqual(proxy.editor.text, "keep ")
                    XCTAssertEqual(proxy.backspaces, 0)
                    source.cancelPress(); source.releasePress()
                }
            }
        }
    }

    func testGapOriginRetainsDeleteAndReturnSlideActions() throws {
        for target in ["delete", "return"] {
            try withKeyboard { keyboard, proxy in
                let enter = try key("return", in: keyboard)
                let point = enter.convert(CGPoint(x: -1, y: enter.bounds.midY), to: keyboard.view)
                let source = try XCTUnwrap(keyboard.view.hitTest(point, with: nil) as? KeyControl)
                source.press(at: 0, point: source.convert(point, from: keyboard.view)); source.advancePress(to: 0.4)
                let id = try XCTUnwrap(keyboard.testingVoiceCommands.last?.id)
                preview(id, keyboard: keyboard)
                slide(source, into: try key(target, in: keyboard))
                source.releasePress()
                keyboard.receiveVoiceReply(reply(id, "Polished.", step: 3, final: true))
                XCTAssertEqual(proxy.editor.text, target == "delete" ? "keep " : "keep Polished.\n")
                XCTAssertEqual(proxy.backspaces, 0)
            }
        }
    }

    func testSymbolGapsCanDictateWhileNumberKeycapsKeepTyping() throws {
        try withKeyboard { keyboard, proxy in
            _ = try key("123", in: keyboard).accessibilityActivate()
            keyboard.view.layoutIfNeeded()
            let one = try key("1", in: keyboard)
            let point = one.convert(CGPoint(x: one.bounds.maxX + 1, y: one.bounds.midY), to: keyboard.view)
            let source = try XCTUnwrap(keyboard.view.hitTest(point, with: nil) as? KeyControl)
            source.press(at: 0, point: source.convert(point, from: keyboard.view)); source.advancePress(to: 0.4)
            XCTAssertEqual(keyboard.testingVoiceCommands.last?.phase, .recording)
            source.cancelPress()
            one.press(at: 1, point: CGPoint(x: one.bounds.midX, y: one.bounds.midY)); one.advancePress(to: 2); one.releasePress()
            XCTAssertEqual(proxy.editor.text, "keep 1")
            XCTAssertEqual(keyboard.testingVoiceCommands.map(\.phase), [.recording, .cancel])
        }
    }

    func testGapDeleteTapIsCancelledWhenTheFieldOrCursorChangesBeforeRelease() throws {
        for change in 0..<2 {
            try withKeyboard { keyboard, proxy in
                let delete = try key("delete", in: keyboard)
                let point = delete.convert(CGPoint(x: -1, y: delete.bounds.midY), to: keyboard.view)
                let source = try XCTUnwrap(keyboard.view.hitTest(point, with: nil) as? KeyControl)
                XCTAssertTrue(source === delete)
                source.press(at: 0, point: source.convert(point, from: keyboard.view))
                if change == 0 { proxy.documentIdentifier = UUID() }
                else { proxy.editor.selectedRange = NSRange(location: 0, length: 0) }
                keyboard.selectionDidChange(nil)
                source.releasePress()
                XCTAssertEqual(proxy.editor.text, "keep ")
                XCTAssertEqual(proxy.backspaces, 0)
                XCTAssertTrue(keyboard.testingVoiceCommands.isEmpty)
            }
        }
    }

    func testDeleteTargetTurnsRedCancelsOnlyDictationAndConsumesRelease() throws {
        try withKeyboard { keyboard, proxy in
            proxy.editor.text = "keep old safe"; proxy.editor.selectedRange = NSRange(location: 5, length: 3)
            let (source, id) = try start(keyboard)
            preview(id, keyboard: keyboard)
            XCTAssertEqual(proxy.editor.text, "keep spoken text safe")
            let delete = try key("delete", in: keyboard)
            slide(source, into: delete)
            XCTAssertEqual(delete.dictationFeedback, .cancel)
            XCTAssertEqual(delete.backgroundColor, .systemRed)
            XCTAssertEqual(delete.icon.tintColor, .white)
            XCTAssertEqual(keyboard.testingVoiceCommands.map(\.phase), [.recording, .cancel])
            XCTAssertEqual(proxy.editor.text, "keep old safe")
            XCTAssertEqual(proxy.backspaces, 0)
            keyboard.receiveVoiceReply(reply(id, "late polish", step: 3, final: true))
            slide(source, into: try key("return", in: keyboard))
            source.advancePress(to: 3); source.releasePress(); source.releasePress()
            XCTAssertNil(delete.dictationFeedback)
            XCTAssertEqual(delete.backgroundColor, KeyboardMetrics.keyFill)
            XCTAssertEqual(proxy.editor.text, "keep old safe")
            XCTAssertEqual(keyboard.testingVoiceCommands.count, 2)
        }
    }

    func testReturnTargetPolishesThenSubmitsOnceAcrossEveryLayout() throws {
        for (width, landscape): (CGFloat, Bool) in [(375, false), (466, false), (655, false), (529, true), (802, true)] {
            try withKeyboard(width: width, landscape: landscape) { keyboard, proxy in
                let (source, id) = try start(keyboard)
                preview(id, keyboard: keyboard)
                // Crossing unrelated keys and the split gap retains the same hold.
                slide(source, into: try key("space", in: keyboard))
                XCTAssertEqual(keyboard.testingVoiceCommands.last?.phase, .recording)
                let enter = try key("return", in: keyboard)
                slide(source, into: enter)
                XCTAssertEqual(enter.dictationFeedback, .send)
                XCTAssertEqual(enter.backgroundColor, .systemBlue)
                XCTAssertEqual(keyboard.testingVoiceCommands.map(\.phase), [.recording, .finish])
                XCTAssertEqual(proxy.editor.text, "keep spoken text")
                source.releasePress()
                XCTAssertNil(enter.dictationFeedback)
                keyboard.receiveVoiceReply(reply(id, "late partial", step: 3))
                XCTAssertEqual(proxy.editor.text, "keep spoken text")
                let final = reply(id, "Polished text.", step: 4, final: true)
                XCTAssertTrue(keyboard.receiveVoiceReply(final))
                XCTAssertEqual(proxy.editor.text, "keep Polished text.\n")
                XCTAssertNil(proxy.editor.markedTextRange)
                XCTAssertFalse(keyboard.receiveVoiceReply(final))
                source.releasePress()
                XCTAssertEqual(proxy.editor.text, "keep Polished text.\n")
            }
        }
    }

    func testReleasingOverAnOrdinaryKeyFinishesWithoutSendingOrTypingThatKey() throws {
        try withKeyboard { keyboard, proxy in
            let (source, id) = try start(keyboard)
            slide(source, into: try key("q", in: keyboard))
            source.releasePress()
            keyboard.receiveVoiceReply(reply(id, "Only dictation.", step: 1, final: true))
            XCTAssertEqual(proxy.editor.text, "keep Only dictation.")
            XCTAssertEqual(keyboard.testingVoiceCommands.map(\.phase), [.recording, .finish])
        }
    }

    func testLanguageHoverTranslatesOnlyOnReleaseAcrossFullLayouts() throws {
        let savedMode = UserDefaults.standard.object(forKey: KeyboardLayoutMode.preferenceKey)
        defer { if let savedMode { UserDefaults.standard.set(savedMode, forKey: KeyboardLayoutMode.preferenceKey) }
                else { UserDefaults.standard.removeObject(forKey: KeyboardLayoutMode.preferenceKey) } }
        for mini in [false] {
            for (width, landscape): (CGFloat, Bool) in [(375, false), (466, false), (655, false), (529, true), (802, true)] {
                KeyboardLayoutMode.full.save()
                try withKeyboard(width: width, landscape: landscape) { keyboard, proxy in
                    if mini {
                        keyboard.setMiniMode(true)
                        keyboard.view.frame.size.height = KeyboardMetrics(width: width, landscape: landscape, mini: true).contentHeight
                        keyboard.viewDidLayoutSubviews(); keyboard.view.layoutIfNeeded()
                    }
                    let source = try key(mini ? "dictate" : "a", in: keyboard)
                    XCTAssertTrue(source.press(at: 0, point: CGPoint(x: source.bounds.midX, y: source.bounds.midY)))
                    source.advancePress(to: 0.5)
                    let id = try XCTUnwrap(keyboard.testingVoiceCommands.last?.id)
                    preview(id, keyboard: keyboard)
                    let language = try key("language", in: keyboard)
                    let originalLanguage = language.accessibilityLabel
                    let taps = keyboard.testingTapFeedbackCount
                    slide(source, into: language); slide(source, into: language)
                    XCTAssertEqual(keyboard.testingTapFeedbackCount, taps + 1)
                    XCTAssertEqual(language.dictationFeedback, .translate)
                    XCTAssertEqual(language.backgroundColor, .systemIndigo)
                    XCTAssertEqual(keyboard.testingVoiceCommands.map(\.phase), [.recording])
                    XCTAssertNil(keyboard.testingVoiceCommands.last?.translate)
                    source.releasePress()
                    XCTAssertEqual(keyboard.testingVoiceCommands.map(\.phase), [.recording, .finish])
                    XCTAssertEqual(keyboard.testingVoiceCommands.last?.translate, true)
                    XCTAssertNil(language.dictationFeedback)
                    XCTAssertEqual(language.accessibilityLabel, originalLanguage)
                    keyboard.receiveVoiceReply(reply(id, "翻译后的文字。", step: 3, final: true))
                    XCTAssertEqual(proxy.editor.text, "keep 翻译后的文字。")
                    XCTAssertNil(proxy.editor.markedTextRange)
                }
            }
        }
    }

    func testLeavingTranslationTargetDisarmsAndCancelOrSendTakePrecedence() throws {
        for destination in ["space", "gap", "delete", "return", "changedField", "cancel"] {
            try withKeyboard { keyboard, proxy in
                let (source, id) = try start(keyboard)
                preview(id, keyboard: keyboard)
                let language = try key("language", in: keyboard)
                slide(source, into: language)
                if destination == "gap" {
                    let point = source.convert(CGPoint(x: language.bounds.midX, y: -2), from: language)
                    XCTAssertTrue(source.movePress(to: point, at: 0.6))
                } else if destination == "changedField" { proxy.documentIdentifier = UUID() }
                else if destination == "cancel" { source.cancelPress() }
                else { slide(source, into: try key(destination, in: keyboard)) }
                source.releasePress()
                XCTAssertNil(language.dictationFeedback)
                XCTAssertNil(keyboard.testingVoiceCommands.last?.translate)
                let cancelled = ["delete", "changedField", "cancel"].contains(destination)
                XCTAssertEqual(keyboard.testingVoiceCommands.last?.phase, cancelled ? .cancel : .finish)
                let before = proxy.editor.text
                keyboard.receiveVoiceReply(reply(id, "Final.", step: 3, final: true))
                XCTAssertEqual(proxy.editor.text, cancelled ? before : "keep Final." + (destination == "return" ? "\n" : ""))
            }
        }
    }

    func testTargetGapsDoNotCancelOrSubmitAndLeavingKeyboardCancels() throws {
        try withKeyboard { keyboard, proxy in
            let (source, id) = try start(keyboard)
            preview(id, keyboard: keyboard)
            let delete = try key("delete", in: keyboard)
            let gap = source.convert(CGPoint(x: delete.bounds.midX, y: -2), from: delete)
            XCTAssertTrue(source.movePress(to: gap, at: 0.5))
            XCTAssertNil(delete.dictationFeedback)
            XCTAssertEqual(keyboard.testingVoiceCommands.last?.phase, .recording)
            XCTAssertFalse(source.movePress(to: source.convert(CGPoint(x: -100, y: -100), from: keyboard.view), at: 0.6))
            source.releasePress()
            XCTAssertEqual(keyboard.testingVoiceCommands.last?.phase, .cancel)
            XCTAssertEqual(proxy.editor.text, "keep ")
        }
    }

    func testQuickSwipeBeforeHoldDoesNotActivateDictationTargets() throws {
        for value in ["delete", "return"] {
            try withKeyboard { keyboard, proxy in
                let source = try key("a", in: keyboard), target = try key(value, in: keyboard)
                source.press(at: 0, point: .zero)
                let point = source.convert(CGPoint(x: target.bounds.midX, y: target.bounds.midY), from: target)
                _ = source.movePress(to: point, at: 0.1)
                source.advancePress(to: 1); source.releasePress()
                XCTAssertNil(target.dictationFeedback)
                XCTAssertTrue(keyboard.testingVoiceCommands.isEmpty)
                XCTAssertEqual(proxy.editor.text, "keep ")
            }
        }
    }

    func testTypingOrFieldChangeDuringPolishingCancelsPendingSend() throws {
        for change in 0..<3 {
            try withKeyboard { keyboard, proxy in
                let (source, id) = try start(keyboard)
                preview(id, keyboard: keyboard)
                slide(source, into: try key("return", in: keyboard)); source.releasePress()
                switch change {
                case 0: _ = try key("b", in: keyboard).accessibilityActivate()
                case 1: proxy.documentIdentifier = UUID()
                default: proxy.editor.selectedRange = NSRange(location: 0, length: 0)
                }
                let untouched = proxy.editor.text
                keyboard.receiveVoiceReply(reply(id, "Must not send.", step: 3, final: true))
                XCTAssertEqual(proxy.editor.text, untouched)
                XCTAssertFalse(proxy.editor.text.contains("\n"))
            }
        }
    }

    func testLayoutChangeAndSystemCancellationClearTargetAndPendingSend() throws {
        for change in 0..<3 {
            try withKeyboard { keyboard, proxy in
                let (source, id) = try start(keyboard)
                preview(id, keyboard: keyboard)
                let enter = try key("return", in: keyboard)
                slide(source, into: enter)
                if change > 0 {
                    if change == 2 { source.releasePress() }
                    keyboard.view.frame.size.width = 655; keyboard.viewDidLayoutSubviews()
                } else { source.cancelPress() }
                XCTAssertNil(enter.dictationFeedback)
                let visible = proxy.editor.text
                keyboard.receiveVoiceReply(reply(id, "Late polish.", step: 3, final: true))
                source.releasePress()
                XCTAssertEqual(proxy.editor.text, visible)
                XCTAssertFalse(proxy.editor.text.contains("\n"))
            }
        }
    }
}
