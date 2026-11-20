import XCTest
import UIKit
@testable import vvhisper

@MainActor final class MiniKeyboardTests: XCTestCase {
    private func descendants(_ view: UIView) -> [UIView] { view.subviews.flatMap { [$0] + descendants($0) } }
    private func key(_ value: String, _ keyboard: KeyboardViewController) throws -> KeyControl {
        try XCTUnwrap(descendants(keyboard.view).compactMap { $0 as? KeyControl }.first { $0.value == value })
    }
    private func layout(_ keyboard: KeyboardViewController, width: CGFloat, landscape: Bool) {
        keyboard.view.frame = CGRect(x: 0, y: 0, width: width, height: KeyboardMetrics(width: width, landscape: landscape, mini: keyboard.isMiniMode).contentHeight)
        keyboard.viewDidLayoutSubviews(); keyboard.view.layoutIfNeeded()
    }
    private func withKeyboard(width: CGFloat = 466, landscape: Bool = false, language: KeyboardLanguage = .english,
                              _ body: (KeyboardViewController, TextViewProxy) async throws -> Void) async throws {
        let previous = UserDefaults.standard.string(forKey: KeyboardLanguage.preferenceKey)
        let previousMode = UserDefaults.standard.object(forKey: KeyboardLayoutMode.preferenceKey)
        KeyboardLayoutMode.full.save()
        language.save()
        await withCheckedContinuation { continuation in PinyinEngine.shared.perform(.clear) { _ in continuation.resume() } }
        let keyboard = KeyboardViewController(), proxy = TextViewProxy("", selection: NSRange(location: 0, length: 0))
        keyboard.testingDocumentProxy = proxy; keyboard.testingVoiceAvailable = true; keyboard.testingLandscape = landscape
        keyboard.loadViewIfNeeded(); layout(keyboard, width: width, landscape: landscape)
        await withCheckedContinuation { continuation in PinyinEngine.shared.perform(.prepare) { _ in continuation.resume() } }
        defer {
            keyboard.viewWillDisappear(false)
            if let previousMode { UserDefaults.standard.set(previousMode, forKey: KeyboardLayoutMode.preferenceKey) }
            else { UserDefaults.standard.removeObject(forKey: KeyboardLayoutMode.preferenceKey) }
            if let previous { UserDefaults.standard.set(previous, forKey: KeyboardLanguage.preferenceKey) }
            else { UserDefaults.standard.removeObject(forKey: KeyboardLanguage.preferenceKey) }
        }
        try await body(keyboard, proxy)
    }
    private func press(_ key: KeyControl, at time: TimeInterval = 0) {
        XCTAssertTrue(key.press(at: time, point: CGPoint(x: key.bounds.midX, y: key.bounds.midY)))
    }
    private func center(_ key: KeyControl, in keyboard: KeyboardViewController) -> CGPoint {
        key.convert(CGPoint(x: key.bounds.midX, y: key.bounds.midY), to: keyboard.view)
    }
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<300 { if condition() { return }; try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }

    func testMiniLayoutKeepsFunctionsAndOneDictationButtonAcrossEverySize() async throws {
        for (width, landscape): (CGFloat, Bool) in [(375, false), (466, false), (655, false), (529, true), (802, true)] {
            try await withKeyboard(width: width, landscape: landscape) { keyboard, _ in
                let fullHeight = keyboard.view.bounds.height
                keyboard.setMiniMode(true); layout(keyboard, width: width, landscape: landscape)
                let controls = descendants(keyboard.view).compactMap { $0 as? KeyControl }
                XCTAssertTrue(keyboard.isMiniMode)
                XCTAssertLessThan(keyboard.view.bounds.height, fullHeight - 100)
                XCTAssertEqual(controls.filter { $0.value == "dictate" }.count, 1)
                XCTAssertFalse(controls.contains { $0.value.count == 1 && $0.value.first!.isLetter })
                let shiftFrame = try key("expand", keyboard).convert(try key("expand", keyboard).bounds, to: keyboard.view)
                let deleteFrame = try key("return", keyboard).convert(try key("return", keyboard).bounds, to: keyboard.view)
                XCTAssertGreaterThanOrEqual(shiftFrame.minY, 8)
                XCTAssertEqual(shiftFrame.minY, shiftFrame.minX, accuracy: 0.01)
                XCTAssertEqual(shiftFrame.minY, width - deleteFrame.maxX, accuracy: 0.01)
                for value in ["expand", "dictate", "delete", "return"] {
                    let control = try key(value, keyboard)
                    XCTAssertGreaterThan(control.bounds.width, 15)
                    XCTAssertTrue(keyboard.view.bounds.insetBy(dx: -1, dy: -1).contains(control.convert(control.bounds, to: keyboard.view)), value)
                }
                XCTAssertTrue(try XCTUnwrap(descendants(keyboard.view).first { $0.accessibilityIdentifier == "keyboard.input-helpers" }).isHidden)
                keyboard.setMiniMode(false); layout(keyboard, width: width, landscape: landscape)
                XCTAssertNotNil(try key("a", keyboard)); XCTAssertEqual(keyboard.view.bounds.height, fullHeight)
            }
        }
    }

    func testPinchCancelsPendingLettersAndDeleteWithoutTextChanges() async throws {
        try await withKeyboard { keyboard, proxy in
            proxy.insertText("keep")
            let a = try key("a", keyboard), delete = try key("delete", keyboard)
            press(a)
            keyboard.beginModeChord(at: [center(a, in: keyboard), center(delete, in: keyboard)])
            a.advancePress(to: 1); delete.advancePress(to: 1)
            keyboard.finishModeChord(direction: .inward, replayTaps: false)
            a.releasePress(); delete.releasePress()
            XCTAssertTrue(keyboard.isMiniMode); XCTAssertEqual(proxy.editor.text, "keep")
            XCTAssertTrue(keyboard.testingVoiceCommands.isEmpty)
            keyboard.finishModeChord(direction: .outward, replayTaps: false) // No second completion.
            XCTAssertTrue(keyboard.isMiniMode)
        }
    }

    func testStationaryTwoThumbChordReplaysInOrderAndCannotSubmit() async throws {
        try await withKeyboard { keyboard, proxy in
            let a = try key("a", keyboard), b = try key("b", keyboard)
            press(a)
            keyboard.beginModeChord(at: [center(a, in: keyboard), center(b, in: keyboard)])
            keyboard.finishModeChord(direction: nil, replayTaps: true)
            a.releasePress(); b.releasePress()
            XCTAssertEqual(proxy.editor.text, "ab")
            let enter = try key("return", keyboard)
            press(enter)
            keyboard.beginModeChord(at: [center(enter, in: keyboard), center(a, in: keyboard)])
            keyboard.finishModeChord(direction: nil, replayTaps: true)
            XCTAssertEqual(proxy.editor.text, "aba")
        }
    }

    func testOverlappingThumbsReceiveFeedbackOnEachDownWithoutReleaseDuplicates() async throws {
        try await withKeyboard { keyboard, proxy in
            let a = try key("a", keyboard), b = try key("b", keyboard)
            let initial = keyboard.testingTapFeedbackCount
            press(a)
            XCTAssertEqual(keyboard.testingTapFeedbackCount - initial, 1, "First thumb must feel its own down")
            keyboard.beginModeChord(at: [center(a, in: keyboard), center(b, in: keyboard)])
            XCTAssertEqual(keyboard.testingTapFeedbackCount - initial, 2, "Pinch interception must not silence the second thumb")
            keyboard.finishModeChord(direction: nil, replayTaps: true)
            a.releasePress(); b.releasePress()
            XCTAssertEqual(proxy.editor.text, "ab")
            XCTAssertEqual(keyboard.testingTapFeedbackCount - initial, 2, "Replay must not queue or double pulses")
        }
    }

    func testSimultaneousThumbsOnSameKeyReceiveTwoPulsesAndTwoCharacters() async throws {
        try await withKeyboard { keyboard, proxy in
            let a = try key("a", keyboard)
            let initial = keyboard.testingTapFeedbackCount
            // Both touches may reach the recognizer before UIControl starts tracking.
            keyboard.beginModeChord(at: [center(a, in: keyboard), center(a, in: keyboard)])
            XCTAssertEqual(keyboard.testingTapFeedbackCount - initial, 2)
            keyboard.finishModeChord(direction: nil, replayTaps: true)
            XCTAssertEqual(proxy.editor.text, "aa")
            XCTAssertEqual(keyboard.testingTapFeedbackCount - initial, 2)
        }
    }

    func testMiniDictationWaitsForSecondFingerThenSupportsCancelAndFinish() async throws {
        try await withKeyboard { keyboard, _ in
            keyboard.setMiniMode(true); layout(keyboard, width: 466, landscape: false)
            let dictate = try key("dictate", keyboard), delete = try key("delete", keyboard)
            press(dictate, at: 100.25)
            dictate.advancePress(to: 100.45)
            XCTAssertTrue(keyboard.testingVoiceCommands.isEmpty)
            dictate.advancePress(to: 100.51)
            XCTAssertEqual(keyboard.testingVoiceCommands.last?.phase, .recording)
            let point = dictate.convert(CGPoint(x: delete.bounds.midX, y: delete.bounds.midY), from: delete)
            XCTAssertTrue(dictate.movePress(to: point, at: 100.6)); dictate.releasePress()
            XCTAssertEqual(keyboard.testingVoiceCommands.last?.phase, .cancel)
            press(dictate, at: 101.25); dictate.advancePress(to: 101.51); dictate.releasePress()
            XCTAssertEqual(keyboard.testingVoiceCommands.last?.phase, .finish)
        }
    }

    func testTwoFingersOnMiniDictateSwitchWithoutStartingVoiceOrReplayingATap() async throws {
        try await withKeyboard { keyboard, proxy in
            keyboard.setMiniMode(true); layout(keyboard, width: 466, landscape: false)
            let dictate = try key("dictate", keyboard)
            press(dictate, at: 20); dictate.advancePress(to: 20.1); dictate.releasePress()
            XCTAssertTrue(keyboard.testingVoiceCommands.isEmpty) // Short touch is not latched voice.
            press(dictate, at: 21); dictate.advancePress(to: 21.15)
            let first = center(dictate, in: keyboard)
            keyboard.beginModeChord(at: [first, CGPoint(x: first.x + 40, y: first.y)])
            dictate.advancePress(to: 21.6)
            keyboard.finishModeChord(direction: .outward, replayTaps: false)
            dictate.releasePress()
            XCTAssertFalse(keyboard.isMiniMode)
            XCTAssertTrue(keyboard.testingVoiceCommands.isEmpty)
            XCTAssertEqual(proxy.editor.text, "")
        }
    }

    func testMiniCommitsFirstChineseCandidateBeforeHidingItAndExpandRestoresFullMode() async throws {
        try await withKeyboard(language: .chinese) { keyboard, proxy in
            for value in "haode" { _ = try key(String(value), keyboard).accessibilityActivate() }
            keyboard.setMiniMode(true)
            await waitUntil { keyboard.isMiniMode }
            XCTAssertEqual(KeyboardLayoutMode.load(), .mini)
            XCTAssertEqual(proxy.editor.text, "好的")
            _ = try key("expand", keyboard).accessibilityActivate()
            XCTAssertFalse(keyboard.isMiniMode)
            XCTAssertEqual(KeyboardLayoutMode.load(), .full)
            XCTAssertNotNil(try key("a", keyboard))
        }
    }

    func testMiniModeSurvivesDismissalAndNewControllerThenRemembersFullMode() async throws {
        try await withKeyboard { keyboard, proxy in
            keyboard.setMiniMode(true)
            keyboard.viewWillDisappear(false); keyboard.viewWillAppear(false)
            XCTAssertTrue(keyboard.isMiniMode); XCTAssertFalse(keyboard.isModeAnimating)
            keyboard.viewWillDisappear(false)

            let reopened = KeyboardViewController()
            reopened.testingDocumentProxy = proxy; reopened.testingLandscape = false
            reopened.loadViewIfNeeded()
            // Restore before the first layout so no full-keyboard flash is needed.
            XCTAssertTrue(reopened.isMiniMode)
            layout(reopened, width: 466, landscape: false)
            XCTAssertNotNil(try key("dictate", reopened))
            XCTAssertFalse(descendants(reopened.view).contains { $0.accessibilityIdentifier == "keyboard.key.a" })
            XCTAssertEqual(reopened.view.bounds.height, KeyboardMetrics(width: 466, mini: true).contentHeight)
            reopened.setMiniMode(false); reopened.viewWillDisappear(false)

            let full = KeyboardViewController()
            full.testingDocumentProxy = proxy; full.testingLandscape = false
            full.loadViewIfNeeded(); layout(full, width: 466, landscape: false)
            XCTAssertFalse(full.isMiniMode); XCTAssertNotNil(try key("a", full))
            full.viewWillDisappear(false)
            // Also refresh a retained controller if another extension instance changed it.
            keyboard.viewWillAppear(false)
            XCTAssertFalse(keyboard.isMiniMode); XCTAssertFalse(keyboard.isModeAnimating)
        }
    }

    func testDismissalDoesNotSaveAnUnfinishedModeRequest() async throws {
        try await withKeyboard(language: .chinese) { keyboard, _ in
            for value in "haode" { _ = try key(String(value), keyboard).accessibilityActivate() }
            keyboard.setMiniMode(true)
            keyboard.viewWillDisappear(false)
            await withCheckedContinuation { c in PinyinEngine.shared.perform(.clear) { _ in c.resume() } }
            XCTAssertFalse(keyboard.isMiniMode)
            XCTAssertEqual(KeyboardLayoutMode.load(), .full)
        }
    }

    func testModeTransitionTracksPinchReversesAndCleansUpOnDismissal() async throws {
        try await withKeyboard { keyboard, proxy in
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene), host = UIViewController()
            window.rootViewController = host; window.isHidden = false
            host.loadViewIfNeeded(); host.addChild(keyboard); host.view.addSubview(keyboard.view); keyboard.didMove(toParent: host)
            defer { keyboard.willMove(toParent: nil); keyboard.view.removeFromSuperview(); keyboard.removeFromParent(); window.isHidden = true }
            layout(keyboard, width: 466, landscape: false); keyboard.testingReduceMotion = false
            try await Task.sleep(for: .milliseconds(80)) // Let the real window render before snapshotting it.
            let a = try key("a", keyboard), b = try key("b", keyboard)
            let original = center(a, in: keyboard)
            keyboard.beginModeChord(at: [original, center(b, in: keyboard)])
            keyboard.updateModeChord(-10)
            let previewed = center(a, in: keyboard)
            XCTAssertGreaterThan(previewed.x, original.x) // Left keys move inward with the fingers.
            keyboard.viewDidLayoutSubviews() // Layout must preserve the pinch preview.
            XCTAssertEqual(center(a, in: keyboard).x, previewed.x, accuracy: 0.01)
            XCTAssertEqual(center(a, in: keyboard).y, previewed.y, accuracy: 0.01)
            keyboard.finishModeChord(direction: .inward, replayTaps: false)
            XCTAssertTrue(keyboard.isModeAnimating); XCTAssertTrue(keyboard.isMiniMode)
            layout(keyboard, width: 466, landscape: false)
            let dictate = try key("dictate", keyboard), space = try key("expand", keyboard)
            keyboard.beginModeChord(at: [center(dictate, in: keyboard), center(space, in: keyboard)])
            keyboard.updateModeChord(18)
            keyboard.finishModeChord(direction: .outward, replayTaps: false)
            XCTAssertFalse(keyboard.isMiniMode); XCTAssertTrue(keyboard.isModeAnimating)
            await waitUntil { !keyboard.isModeAnimating }
            XCTAssertFalse(descendants(keyboard.view).contains { $0.accessibilityIdentifier == "keyboard.mode-transition" })
            XCTAssertEqual(proxy.editor.text, ""); XCTAssertTrue(keyboard.testingVoiceCommands.isEmpty)
            keyboard.setMiniMode(true); XCTAssertTrue(keyboard.isModeAnimating)
            keyboard.viewWillDisappear(false); XCTAssertFalse(keyboard.isModeAnimating)
            XCTAssertFalse(descendants(keyboard.view).contains { $0.accessibilityIdentifier == "keyboard.mode-transition" })
        }
    }

    func testReducedMotionUsesFadeWithoutFollowingOrSliding() async throws {
        try await withKeyboard { keyboard, _ in
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene), host = UIViewController()
            window.rootViewController = host; window.isHidden = false
            host.loadViewIfNeeded(); host.addChild(keyboard); host.view.addSubview(keyboard.view); keyboard.didMove(toParent: host)
            defer { keyboard.willMove(toParent: nil); keyboard.view.removeFromSuperview(); keyboard.removeFromParent(); window.isHidden = true }
            layout(keyboard, width: 466, landscape: false); keyboard.testingReduceMotion = true
            try await Task.sleep(for: .milliseconds(80))
            let a = try key("a", keyboard), b = try key("b", keyboard), original = center(a, in: keyboard)
            keyboard.beginModeChord(at: [original, center(b, in: keyboard)])
            keyboard.updateModeChord(-20)
            XCTAssertEqual(center(a, in: keyboard), original)
            keyboard.finishModeChord(direction: .inward, replayTaps: false)
            let snapshot = try XCTUnwrap(descendants(keyboard.view).first { $0.accessibilityIdentifier == "keyboard.mode-transition" })
            XCTAssertEqual(snapshot.transform, .identity); XCTAssertFalse(snapshot.isUserInteractionEnabled)
            XCTAssertEqual(snapshot.superview?.clipsToBounds, true)
            XCTAssertEqual(snapshot.superview?.isUserInteractionEnabled, false)
            await waitUntil { !keyboard.isModeAnimating }
        }
    }

    func testNativeMiniLayoutContactSheet() async throws {
        var panels: [(String, UIImage)] = []
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        for (width, landscape): (CGFloat, Bool) in [(375, false), (466, false), (655, false), (529, true), (802, true)] {
            for style in [UIUserInterfaceStyle.light, .dark] {
                try await withKeyboard(width: width, landscape: landscape) { keyboard, _ in
                    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
                    let window = UIWindow(windowScene: scene), host = UIViewController()
                    window.rootViewController = host; window.overrideUserInterfaceStyle = style; window.isHidden = false
                    host.loadViewIfNeeded(); host.addChild(keyboard); host.view.addSubview(keyboard.view); keyboard.didMove(toParent: host)
                    keyboard.overrideUserInterfaceStyle = style
                    try await Task.sleep(for: .milliseconds(40))
                    keyboard.setMiniMode(true); layout(keyboard, width: width, landscape: landscape)
                    await waitUntil { !keyboard.isModeAnimating }
                    defer { keyboard.willMove(toParent: nil); keyboard.view.removeFromSuperview(); keyboard.removeFromParent(); window.isHidden = true }
                    let image = UIGraphicsImageRenderer(size: keyboard.view.bounds.size, format: format).image { context in
                        (style == .light ? UIColor(white: 0.82, alpha: 1) : UIColor(white: 0.12, alpha: 1)).setFill()
                        context.fill(keyboard.view.bounds); keyboard.view.layer.render(in: context.cgContext)
                    }
                    panels.append(("\(Int(width)) pt · \(landscape ? "Landscape" : "Portrait") · \(style == .light ? "Light" : "Dark")", image))
                }
            }
        }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1640, height: 1020), format: format).image { context in
            UIColor(white: 0.95, alpha: 1).setFill(); context.fill(CGRect(x: 0, y: 0, width: 1640, height: 1020))
            for (index, panel) in panels.enumerated() {
                let origin = CGPoint(x: (index % 2) * 820 + 8, y: (index / 2) * 200 + 6)
                (panel.0 as NSString).draw(at: origin, withAttributes: [.font: UIFont.systemFont(ofSize: 14), .foregroundColor: UIColor.black])
                panel.1.draw(at: CGPoint(x: origin.x, y: origin.y + 24))
            }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vvhisper-mini-layouts.png")
        try image.pngData()!.write(to: url); print("Mini preview artifact: \(url.path)")
    }
}

final class KeyboardModePinchTests: XCTestCase {
    func testPinchesWorkHorizontallyVerticallyAndDiagonally() {
        for end in [CGPoint(x: 100, y: 0), CGPoint(x: 0, y: 100), CGPoint(x: 100, y: 100)] {
            let origins: [CGPoint] = [.zero, end]
            let inward = [CGPoint(x: end.x * 0.1, y: end.y * 0.1), CGPoint(x: end.x * 0.9, y: end.y * 0.9)]
            let outward = [CGPoint(x: -end.x * 0.1, y: -end.y * 0.1), CGPoint(x: end.x * 1.1, y: end.y * 1.1)]
            XCTAssertEqual(KeyboardModePinch.direction(from: origins, to: inward), .inward)
            XCTAssertEqual(KeyboardModePinch.direction(from: origins, to: outward), .outward)
        }
    }

    func testSwipingTogetherRotationAndSmallJitterDoNotSwitch() {
        let origins = [CGPoint.zero, CGPoint(x: 100, y: 0)]
        for offset in [CGPoint(x: 0, y: 40), CGPoint(x: 0, y: -40), CGPoint(x: 30, y: 20)] {
            let moved = origins.map { CGPoint(x: $0.x + offset.x, y: $0.y + offset.y) }
            XCTAssertNil(KeyboardModePinch.direction(from: origins, to: moved))
        }
        XCTAssertNil(KeyboardModePinch.direction(from: origins, to: [CGPoint(x: 50, y: -50), CGPoint(x: 50, y: 50)]))
        XCTAssertNil(KeyboardModePinch.direction(from: origins, to: [CGPoint(x: 2, y: 0), CGPoint(x: 98, y: 0)]))
    }

    func testAnchoredFingerAndWideSpansRemainEasyToPinch() {
        XCTAssertEqual(KeyboardModePinch.direction(from: [.zero, CGPoint(x: 100, y: 0)],
                                                 to: [.zero, CGPoint(x: 86, y: 0)]), .inward)
        XCTAssertEqual(KeyboardModePinch.direction(from: [.zero, CGPoint(x: 600, y: 0)],
                                                 to: [CGPoint(x: 14, y: 0), CGPoint(x: 586, y: 0)]), .inward)
        XCTAssertEqual(KeyboardModePinch.direction(from: [.zero, CGPoint(x: 60, y: 0)],
                                                 to: [CGPoint(x: -7, y: 0), CGPoint(x: 67, y: 0)]), .outward)
    }

    func testCloseFingersCanSpreadOnTheShortMiniKeyboardWithoutAcceptingJitter() {
        let origins = [CGPoint.zero, CGPoint(x: 8, y: 0)]
        XCTAssertEqual(KeyboardModePinch.direction(from: origins, to: [.zero, CGPoint(x: 24, y: 0)]), .outward)
        XCTAssertNil(KeyboardModePinch.direction(from: origins, to: [.zero, CGPoint(x: 13, y: 0)]))
    }

    func testMissingCoincidentAndInvalidTouchesCannotSwitch() {
        let origins = [CGPoint.zero, CGPoint(x: 100, y: 0)]
        XCTAssertNil(KeyboardModePinch.direction(from: origins, to: [.zero]))
        XCTAssertNil(KeyboardModePinch.direction(from: [.zero, .zero], to: origins))
        XCTAssertNil(KeyboardModePinch.direction(from: origins, to: [.zero, CGPoint(x: CGFloat.nan, y: 0)]))
        XCTAssertNil(KeyboardModePinch.direction(from: [.zero, CGPoint(x: CGFloat.infinity, y: 0)], to: origins))
    }

    func testRecognitionLatchesDuringMovementWithoutRepeatingOrReversingOnRelease() {
        var pinch = KeyboardModePinch()
        let origins = [CGPoint.zero, CGPoint(x: 100, y: 0)]
        XCTAssertNil(pinch.advance(from: origins, to: [CGPoint(x: 4, y: 0), CGPoint(x: 96, y: 0)]))
        XCTAssertEqual(pinch.advance(from: origins, to: [CGPoint(x: 8, y: 0), CGPoint(x: 92, y: 0)]), .inward)
        XCTAssertNil(pinch.advance(from: origins, to: origins))
        XCTAssertNil(pinch.advance(from: origins, to: [CGPoint(x: -20, y: 0), CGPoint(x: 120, y: 0)]))
        XCTAssertEqual(pinch.recognizedDirection, .inward)
    }

    func testStaggeredFingersKeepBriefHeadStartButRebaseAnEarlierHold() {
        let initial = [CGPoint(x: 10, y: 10), CGPoint(x: 110, y: 10)]
        let current = [CGPoint(x: 26, y: 10), CGPoint(x: 110, y: 10)]
        let short = KeyboardModePinch.pairOrigins(initial: initial, current: current, stagger: 0.2)
        XCTAssertEqual(KeyboardModePinch.direction(from: short, to: current), .inward)
        let held = KeyboardModePinch.pairOrigins(initial: initial, current: current, stagger: 0.5)
        XCTAssertNil(KeyboardModePinch.direction(from: held, to: current))
    }

    func testModePreferenceDefaultsAndInvalidValuesStayFull() throws {
        let suite = "vvhisper.mode-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(KeyboardLayoutMode.load(from: defaults), .full)
        defaults.set("unsupported", forKey: KeyboardLayoutMode.preferenceKey)
        XCTAssertEqual(KeyboardLayoutMode.load(from: defaults), .full)
        KeyboardLayoutMode.mini.save(to: defaults)
        XCTAssertEqual(KeyboardLayoutMode.load(from: defaults), .mini)
        KeyboardLayoutMode.full.save(to: defaults)
        XCTAssertEqual(KeyboardLayoutMode.load(from: defaults), .full)
    }
}
