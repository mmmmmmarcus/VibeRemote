import XCTest
import UIKit
@testable import vvhisper

final class QuietKeysModelTests: XCTestCase {
    func testRMSIsBoundedAndDiscardsInvalidOrSilentBuffers() {
        XCTAssertEqual(VoiceLevel.measure([]), 0)
        XCTAssertEqual(VoiceLevel.measure(Array(repeating: 0, count: 640)), 0)
        XCTAssertEqual(VoiceLevel.measure([.nan]), 0)
        XCTAssertEqual(VoiceLevel.measure([.infinity]), 0)
        XCTAssertEqual(VoiceLevel.measure([1, -1, 2]), 1)
        XCTAssertEqual(VoiceLevel.measure([0.01, -0.01]), 0.375, accuracy: 0.0001)
        XCTAssertGreaterThan(VoiceLevel.measure([0.1]), VoiceLevel.measure([0.01]))
    }
    func testSessionFreshnessAndOrdering() {
        let id = UUID(), now = Date()
        var meter = QuietKeys(); meter.start(id: id, at: now)
        meter.advance(VoiceLevel(id: UUID(), value: 1, updatedAt: now), at: now.addingTimeInterval(0.1), reducedMotion: false)
        XCTAssertEqual(meter.level, 0)
        meter.advance(VoiceLevel(id: id, value: 1, updatedAt: now.addingTimeInterval(1)), at: now.addingTimeInterval(0.2), reducedMotion: false)
        XCTAssertEqual(meter.level, 0)
        meter.advance(VoiceLevel(id: id, value: 1, updatedAt: now), at: now.addingTimeInterval(0.4), reducedMotion: false)
        XCTAssertEqual(meter.level, 0)
        meter.advance(VoiceLevel(id: id, value: 0.01, updatedAt: now.addingTimeInterval(0.5)), at: now.addingTimeInterval(0.5), reducedMotion: false)
        meter.advance(VoiceLevel(id: id, value: 1, updatedAt: now.addingTimeInterval(0.45)), at: now.addingTimeInterval(0.55), reducedMotion: false)
        XCTAssertEqual(meter.level, 0, "Older same-session values cannot replace a newer quiet reading")
        meter.reset()
        meter.advance(VoiceLevel(id: id, value: 1, updatedAt: now.addingTimeInterval(0.6)), at: now.addingTimeInterval(0.6), reducedMotion: false)
        XCTAssertNil(meter.sessionID); XCTAssertEqual(meter.level, 0)
    }
    func testAttackReleaseAndMissingSampleDecay() {
        let id = UUID(), now = Date()
        var meter = QuietKeys(); meter.start(id: id, at: now)
        meter.advance(VoiceLevel(id: id, value: 1, updatedAt: now), at: now.addingTimeInterval(0.035), reducedMotion: false)
        XCTAssertEqual(meter.level, 1 - exp(-1), accuracy: 0.0001)
        let before = meter.level
        meter.advance(VoiceLevel(id: id, value: 0, updatedAt: now.addingTimeInterval(0.175)), at: now.addingTimeInterval(0.175), reducedMotion: false)
        XCTAssertEqual(meter.level, before * exp(-1), accuracy: 0.0001)
        meter.advance(nil, at: now.addingTimeInterval(3), reducedMotion: false)
        XCTAssertEqual(meter.level, 0)
    }
    func testSoftSpeechReachesBeyondCenterWhileNoiseStaysStill() {
        let id = UUID(), now = Date()
        var meter = QuietKeys(); meter.start(id: id, at: now)
        meter.advance(VoiceLevel(id: id, value: 0.05, updatedAt: now), at: now.addingTimeInterval(0.1), reducedMotion: false)
        XCTAssertEqual(meter.level, 0)
        let time = now.addingTimeInterval(0.2)
        meter.advance(VoiceLevel(id: id, value: VoiceLevel.measure([0.01, -0.01]), updatedAt: time), at: time, reducedMotion: false)
        XCTAssertGreaterThan(meter.level, 0.43, "Soft speech must remain visible")
        XCTAssertLessThan(meter.level, 0.5, "Ordinary speech should not light most of the keyboard")
        XCTAssertGreaterThan(QuietKeys.strength(level: meter.level, position: 0.3), 0.8)
    }

    func testCenterFieldIsSymmetricAndLoudSpeechWidensIt() {
        for x in stride(from: 0.0, through: 1, by: 0.1) {
            XCTAssertEqual(QuietKeys.strength(level: 0.5, position: x), QuietKeys.strength(level: 0.5, position: 1-x), accuracy: 0.0001)
            XCTAssertEqual(QuietKeys.strength(level: 0, position: x), 0)
        }
        XCTAssertGreaterThan(QuietKeys.strength(level: 0.2, position: 0.5), 0)
        XCTAssertEqual(QuietKeys.strength(level: 0.2, position: 0.1), 0)
        XCTAssertGreaterThan(QuietKeys.strength(level: 0.9, position: 0.1), 0.9)
    }
    func testReducedMotionUsesOnlyOneStationaryExtent() {
        let id = UUID(), now = Date()
        var meter = QuietKeys(); meter.start(id: id, at: now)
        for (offset, level) in [(0.1, 0.2), (0.2, 1.0)] {
            let time = now.addingTimeInterval(offset)
            meter.advance(VoiceLevel(id: id, value: level, updatedAt: time), at: time, reducedMotion: true)
            XCTAssertEqual(meter.level, 0.24)
        }
        meter.advance(nil, at: now.addingTimeInterval(1), reducedMotion: true)
        XCTAssertEqual(meter.level, 0)
    }
    func testRelayCannotLeakIdleAudioOrPreviousHoldLevels() throws {
        let relay = AudioRelay()
        XCTAssertNil(relay.capture); XCTAssertNil(relay.level)
        relay.set([SeedStreamingSession { _ in }])
        let first = try XCTUnwrap(relay.capture)
        relay.append([0.1, -0.1], generation: first)
        XCTAssertGreaterThan(try XCTUnwrap(relay.level).value, 0)
        relay.set([]); XCTAssertNil(relay.level); XCTAssertNil(relay.capture)
        relay.set([SeedStreamingSession { _ in }])
        relay.append([0.1], generation: first)
        XCTAssertNil(relay.level)
        relay.set([])
    }
}

@MainActor final class QuietKeysIntegrationTests: XCTestCase {
    private func descendants(_ view: UIView) -> [UIView] { view.subviews.flatMap { [$0] + descendants($0) } }
    private func key(_ value: String, _ keyboard: KeyboardViewController) throws -> KeyControl {
        try XCTUnwrap(descendants(keyboard.view).compactMap { $0 as? KeyControl }.first { $0.value == value })
    }
    private func withKeyboard(width: CGFloat = 466, landscape: Bool = false, mini: Bool = false,
                              _ body: (KeyboardViewController, TextViewProxy) throws -> Void) async rethrows {
        let language = UserDefaults.standard.string(forKey: KeyboardLanguage.preferenceKey)
        let mode = UserDefaults.standard.string(forKey: KeyboardLayoutMode.preferenceKey)
        KeyboardLanguage.english.save(); (mini ? KeyboardLayoutMode.mini : .full).save()
        defer {
            UserDefaults.standard.set(language, forKey: KeyboardLanguage.preferenceKey)
            UserDefaults.standard.set(mode, forKey: KeyboardLayoutMode.preferenceKey)
        }
        let keyboard = KeyboardViewController(), proxy = TextViewProxy("keep ", selection: NSRange(location: 5, length: 0))
        keyboard.testingDocumentProxy = proxy; keyboard.testingVoiceAvailable = true; keyboard.testingLandscape = landscape
        keyboard.loadViewIfNeeded()
        await withCheckedContinuation { c in PinyinEngine.shared.perform(.clear) { _ in c.resume() } }
        keyboard.view.frame = CGRect(x: 0, y: 0, width: width, height: KeyboardMetrics(width: width, landscape: landscape, mini: mini).contentHeight)
        keyboard.viewDidLayoutSubviews(); keyboard.view.layoutIfNeeded()
        defer { keyboard.viewWillDisappear(false) }
        try body(keyboard, proxy)
    }
    private func start(_ keyboard: KeyboardViewController) throws -> (KeyControl, UUID) {
        let source = try key(keyboard.isMiniMode ? "dictate" : "a", keyboard)
        XCTAssertTrue(source.press(at: 0, point: CGPoint(x: source.bounds.midX, y: source.bounds.midY)))
        source.advancePress(to: 0.4)
        return (source, try XCTUnwrap(keyboard.testingVoiceCommands.last?.id))
    }
    private func preview(_ id: UUID, _ keyboard: KeyboardViewController) {
        keyboard.receiveVoiceReply(VoiceReply(id: id, text: "这个按钮的还原度不错再走查一下间距和对齐", isFinal: false, updatedAt: Date().addingTimeInterval(-0.2)))
        keyboard.receiveVoiceReply(VoiceReply(id: id, text: "这个按钮的还原度不错再走查一下间距和对齐还有标题", isFinal: false, updatedAt: Date().addingTimeInterval(-0.1)))
    }

    private func level(_ value: Double, id: UUID, keyboard: KeyboardViewController, offset: TimeInterval = 0.2) {
        let now = Date().addingTimeInterval(offset)
        keyboard.receiveVoiceLevel(VoiceLevel(id: id, value: value, updatedAt: now), at: now)
    }
    func testEveryLayoutKeepsKeyBoundsAndFunctionalIconsWhileLevelsChange() async throws {
        for mini in [false, true] {
            for (width, landscape): (CGFloat, Bool) in [(375, false), (466, false), (655, false), (529, true), (802, true)] {
                try await withKeyboard(width: width, landscape: landscape, mini: mini) { keyboard, _ in
                    let keys = descendants(keyboard.view).compactMap { $0 as? KeyControl }
                    let frames = keys.map(\.frame)
                    let (source, id) = try start(keyboard)
                    XCTAssertTrue(keys.allSatisfy { $0.label.alpha == 0 })
                    level(0.8, id: id, keyboard: keyboard)
                    XCTAssertTrue(keys.contains { $0.quietFeedback.brightness > 0 })
                    XCTAssertEqual(frames, keys.map(\.frame))
                    for control in keys {
                        XCTAssertTrue(control.quietFeedback.superview === control)
                        XCTAssertEqual(control.quietFeedback.frame.minX, 0, accuracy: 0.001)
                        XCTAssertEqual(control.quietFeedback.frame.minY, 0, accuracy: 0.001)
                        XCTAssertEqual(control.quietFeedback.frame.width, control.bounds.width, accuracy: 0.001)
                        XCTAssertEqual(control.quietFeedback.frame.height, control.bounds.height, accuracy: 0.001)
                        XCTAssertTrue(control.quietFeedback.clipsToBounds)
                        XCTAssertFalse(control.quietFeedback.isUserInteractionEnabled)
                    }
                    for name in [mini ? "expand" : "shift", "delete", "return"] {
                        XCTAssertFalse(try key(name, keyboard).icon.isHidden)
                    }
                    source.releasePress()
                    XCTAssertTrue(keys.allSatisfy { $0.label.alpha == 1 && $0.quietFeedback.brightness == 0 })
                    XCTAssertNil(keyboard.quietKeys.sessionID)
                }
            }
        }
    }
    func testStripStaysQuietAndFinalTextNeverWaitsForVisuals() async throws {
        for mini in [false, true] {
            try await withKeyboard(mini: mini) { keyboard, proxy in
                let (source, id) = try start(keyboard)
                level(0.9, id: id, keyboard: keyboard); preview(id, keyboard)
                let status = descendants(keyboard.view).first { $0.accessibilityIdentifier == "keyboard.voice-status" }
                let panel = try XCTUnwrap(descendants(keyboard.view).compactMap { $0 as? CandidatePanel }.first)
                XCTAssertEqual(status?.isHidden, true); XCTAssertTrue(panel.isHidden)
                source.releasePress()
                level(1, id: id, keyboard: keyboard)
                XCTAssertEqual(keyboard.quietKeys.level, 0)
                XCTAssertEqual(status?.isHidden, true); XCTAssertTrue(panel.isHidden)
                keyboard.receiveVoiceReply(VoiceReply(id: id, text: "Final text.", isFinal: true))
                XCTAssertEqual(proxy.editor.text, "keep Final text.")
                keyboard.receiveVoiceReply(VoiceReply(id: UUID(), text: "wrong", isFinal: true))
                XCTAssertEqual(proxy.editor.text, "keep Final text.")
            }
        }
    }
    func testDismissalAndNewHoldRejectLateLevels() async throws {
        try await withKeyboard { keyboard, _ in
            let (source, old) = try start(keyboard)
            level(1, id: old, keyboard: keyboard)
            keyboard.viewWillDisappear(false)
            XCTAssertEqual(keyboard.quietKeys.level, 0)
            level(1, id: old, keyboard: keyboard); XCTAssertEqual(keyboard.quietKeys.level, 0)
            source.cancelPress()
            let (_, current) = try start(keyboard)
            level(1, id: old, keyboard: keyboard)
            XCTAssertEqual(keyboard.quietKeys.level, 0); XCTAssertEqual(keyboard.quietKeys.sessionID, current)
        }
    }
    func testCancelFeedbackWinsOverQuietFillAndRotationClearsIt() async throws {
        try await withKeyboard { keyboard, _ in
            let (_, id) = try start(keyboard)
            level(1, id: id, keyboard: keyboard)
            let delete = try key("delete", keyboard)
            delete.dictationFeedback = .cancel
            XCTAssertEqual(delete.backgroundColor, .systemRed)
            XCTAssertEqual(delete.quietFeedback.brightness, 0)
            keyboard.view.frame.size.width = 655
            keyboard.viewDidLayoutSubviews()
            XCTAssertNil(keyboard.quietKeys.sessionID)
        }
    }
    func testNativeQuietKeysContactSheet() async throws {
        var panels: [(String, UIImage)] = []
        let format = UIGraphicsImageRendererFormat(); format.scale = 2
        for mini in [false, true] {
            for style in [UIUserInterfaceStyle.light, .dark] {
                try await withKeyboard(mini: mini) { keyboard, proxy in
                    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
                    let window = UIWindow(windowScene: scene), host = UIViewController()
                    window.rootViewController = host; window.overrideUserInterfaceStyle = style; window.isHidden = false
                    host.loadViewIfNeeded(); host.addChild(keyboard); host.view.addSubview(keyboard.view); keyboard.didMove(toParent: host)
                    proxy.keyboardAppearance = style == .dark ? .dark : .light; keyboard.textDidChange(nil)
                    keyboard.view.frame = CGRect(x: 0, y: 0, width: 466, height: KeyboardMetrics(width: 466, mini: mini).contentHeight)
                    keyboard.viewDidLayoutSubviews(); keyboard.view.layoutIfNeeded()
                    defer {
                        keyboard.willMove(toParent: nil); keyboard.view.removeFromSuperview(); keyboard.removeFromParent(); window.isHidden = true
                    }
                    let (source, id) = try start(keyboard)
                    for (offset, value) in [(0.2, 0.0), (0.7, 0.4), (1.2, 0.9), (1.7, -1.0)] {
                        if value < 0 { source.releasePress() }
                        else { level(value, id: id, keyboard: keyboard, offset: offset) }
                        let image = UIGraphicsImageRenderer(size: keyboard.view.bounds.size, format: format).image { context in
                            (style == .dark ? UIColor(white: 0.13, alpha: 1) : UIColor(white: 0.82, alpha: 1)).setFill()
                            context.fill(keyboard.view.bounds); keyboard.view.layer.render(in: context.cgContext)
                        }
                        panels.append(("\(mini ? "Mini" : "Full") · \(style == .dark ? "Dark" : "Light") · \(value < 0 ? "Released" : value == 0 ? "Silence" : value < 0.5 ? "Soft" : "Strong")", image))
                    }
                }
            }
        }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1928, height: 960), format: format).image { context in
            UIColor(white: 0.94, alpha: 1).setFill(); context.fill(CGRect(x: 0, y: 0, width: 1928, height: 960))
            var y: CGFloat = 8
            for row in 0..<4 {
                for col in 0..<4 {
                    let panel = panels[row*4+col], x = CGFloat(col)*482+8
                    (panel.0 as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: [.font: UIFont.systemFont(ofSize: 12), .foregroundColor: UIColor.black])
                    panel.1.draw(at: CGPoint(x: x, y: y+22))
                }
                y += panels[row*4].1.size.height + 38
            }
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("vvhisper-quiet-keys-layouts.png")
        try image.pngData()!.write(to: file); print("Quiet keys preview artifact: \(file.path)")
    }
}
