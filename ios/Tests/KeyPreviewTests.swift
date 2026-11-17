import XCTest
import UIKit
@testable import vvhisper

@MainActor
final class KeyPreviewTests: XCTestCase {
    private func descendants(_ view: UIView) -> [UIView] { view.subviews.flatMap { [$0] + descendants($0) } }
    private func key(_ value: String, in keyboard: KeyboardViewController) throws -> KeyControl {
        try XCTUnwrap(descendants(keyboard.view).compactMap { $0 as? KeyControl }.first { $0.value == value })
    }
    private func preview(in keyboard: KeyboardViewController) throws -> KeyPreviewView {
        try XCTUnwrap(descendants(keyboard.view).compactMap { $0 as? KeyPreviewView }.first)
    }
    private func press(_ key: KeyControl) {
        XCTAssertTrue(key.press(at: 0, point: CGPoint(x: key.bounds.midX, y: key.bounds.midY)))
    }
    private func withKeyboard(width: CGFloat = 466, landscape: Bool = false,
                              _ body: (KeyboardViewController, TextViewProxy) throws -> Void) rethrows {
        let previous = UserDefaults.standard.string(forKey: KeyboardLanguage.preferenceKey)
        KeyboardLanguage.english.save()
        let keyboard = KeyboardViewController()
        let proxy = TextViewProxy("", selection: NSRange(location: 0, length: 0))
        keyboard.testingDocumentProxy = proxy; keyboard.testingVoiceAvailable = true; keyboard.testingLandscape = landscape
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

    func testPopupUsesCurrentCaseAndIncludesNumbersAndPunctuation() throws {
        try withKeyboard { keyboard, proxy in
            let popup = try preview(in: keyboard)
            _ = try key("shift", in: keyboard).accessibilityActivate()
            let a = try key("a", in: keyboard); press(a)
            XCTAssertFalse(popup.isHidden); XCTAssertEqual(popup.label.text, "A")
            XCTAssertGreaterThan(popup.label.font.pointSize, a.label.font.pointSize)
            a.releasePress(); XCTAssertTrue(popup.isHidden)
            XCTAssertEqual(proxy.editor.text, "A")
            _ = try key("123", in: keyboard).accessibilityActivate(); keyboard.view.layoutIfNeeded()
            for value in ["1", "?"] {
                let character = try key(value, in: keyboard); press(character)
                XCTAssertFalse(popup.isHidden); XCTAssertEqual(popup.label.text, value)
                character.releasePress(); XCTAssertTrue(popup.isHidden)
            }
            XCTAssertEqual(proxy.editor.text, "A1?")
        }
    }

    func testFunctionKeysHaveNoPopupAndDictationHidesCharacterPopup() throws {
        try withKeyboard { keyboard, _ in
            let popup = try preview(in: keyboard)
            for value in ["shift", "space", "return", "delete", "language", "123"] {
                let function = try key(value, in: keyboard); press(function)
                XCTAssertTrue(popup.isHidden); function.cancelPress()
            }
            let a = try key("a", in: keyboard); press(a)
            XCTAssertFalse(popup.isHidden)
            a.advancePress(to: 0.4)
            XCTAssertTrue(popup.isHidden)
            XCTAssertEqual(keyboard.testingVoiceCommands.last?.phase, .recording)
            a.cancelPress()
        }
    }

    func testRolloverAndLateReleaseCannotHideNewerPreview() throws {
        try withKeyboard { keyboard, proxy in
            let a = try key("a", in: keyboard), b = try key("b", in: keyboard)
            let popup = try preview(in: keyboard)
            press(a); press(b)
            XCTAssertEqual(proxy.editor.text, "a")
            XCTAssertEqual(popup.label.text, "b")
            a.releasePress(); a.cancelPress()
            XCTAssertFalse(popup.isHidden)
            b.releasePress(); XCTAssertTrue(popup.isHidden)
            XCTAssertEqual(proxy.editor.text, "ab")
        }
    }

    func testCancellationRotationAndDismissalRemovePreview() throws {
        for change in 0..<3 {
            try withKeyboard { keyboard, _ in
                let a = try key("a", in: keyboard), popup = try preview(in: keyboard)
                press(a)
                switch change {
                case 0: a.cancelPress()
                case 1: keyboard.view.frame.size.width = 655; keyboard.viewDidLayoutSubviews()
                default: keyboard.viewWillDisappear(false)
                }
                XCTAssertTrue(popup.isHidden)
            }
        }
    }

    func testPopupFitsEveryLayoutAndNeverInterceptsTouches() throws {
        var panels: [(String, UIImage)] = []
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        for (width, landscape): (CGFloat, Bool) in [(375, false), (466, false), (655, false), (529, true), (802, true)] {
            for style in [UIUserInterfaceStyle.light, .dark] {
                try withKeyboard(width: width, landscape: landscape) { keyboard, _ in
                    // UIKit resolves dynamic layer colors when attached to a window.
                    // A detached input controller can still report light appearance.
                    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
                    let window = UIWindow(windowScene: scene)
                    let host = UIViewController()
                    window.rootViewController = host
                    window.overrideUserInterfaceStyle = style
                    window.isHidden = false
                    host.loadViewIfNeeded()
                    host.addChild(keyboard); host.view.addSubview(keyboard.view); keyboard.didMove(toParent: host)
                    keyboard.overrideUserInterfaceStyle = style
                    keyboard.view.frame = CGRect(x: 0, y: 0, width: width, height: KeyboardMetrics(width: width, landscape: landscape).contentHeight)
                    keyboard.viewDidLayoutSubviews(); keyboard.view.layoutIfNeeded()
                    defer {
                        keyboard.willMove(toParent: nil); keyboard.view.removeFromSuperview(); keyboard.removeFromParent()
                        window.isHidden = true
                    }
                    let popup = try preview(in: keyboard)
                    XCTAssertEqual(popup.traitCollection.userInterfaceStyle, style)
                    for value in ["q", "p", "a", "m"] {
                        let character = try key(value, in: keyboard); press(character)
                        XCTAssertGreaterThanOrEqual(popup.frame.minX, 0)
                        XCTAssertGreaterThanOrEqual(popup.frame.minY, 0)
                        XCTAssertLessThanOrEqual(popup.frame.maxX, keyboard.view.bounds.maxX)
                        XCTAssertLessThanOrEqual(popup.frame.maxY, keyboard.view.bounds.maxY)
                        XCTAssertLessThan(popup.convert(popup.headFrame, to: keyboard.view).minY, character.convert(character.bounds, to: keyboard.view).minY)
                        let location = character.convert(CGPoint(x: character.bounds.midX, y: character.bounds.midY), to: keyboard.view)
                        XCTAssertTrue(keyboard.view.hitTest(location, with: nil) === character)
                        character.cancelPress()
                    }
                    press(try key(style == .light ? "q" : "p", in: keyboard))
                    let image = UIGraphicsImageRenderer(size: keyboard.view.bounds.size, format: format).image { context in
                        (style == .light ? UIColor(white: 0.83, alpha: 1) : UIColor(white: 0.12, alpha: 1)).setFill()
                        context.fill(keyboard.view.bounds)
                        keyboard.view.layer.render(in: context.cgContext)
                    }
                    panels.append(("\(Int(width)) pt · \(landscape ? "Landscape" : "Portrait") · \(style == .light ? "Light" : "Dark")", image))
                }
            }
        }
        // A native UIKit contact sheet for visual review, never real user text.
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1640, height: 1700), format: format).image { context in
            UIColor(white: 0.95, alpha: 1).setFill(); context.fill(CGRect(x: 0, y: 0, width: 1640, height: 1700))
            for (index, panel) in panels.enumerated() {
                let origin = CGPoint(x: (index % 2) * 820 + 8, y: (index / 2) * 340 + 6)
                (panel.0 as NSString).draw(at: origin, withAttributes: [.font: UIFont.systemFont(ofSize: 14), .foregroundColor: UIColor.black])
                panel.1.draw(at: CGPoint(x: origin.x, y: origin.y + 24))
            }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vvhisper-key-previews.png")
        try image.pngData()!.write(to: url)
        print("Keyboard preview artifact: \(url.path)")
    }
}
