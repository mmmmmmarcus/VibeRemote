import XCTest
import UIKit
@testable import vvhisper

@MainActor final class DeleteExpansionTests: XCTestCase {
    private func descendants(_ view: UIView) -> [UIView] { view.subviews.flatMap { [$0] + descendants($0) } }
    private func key(_ value: String, _ keyboard: KeyboardViewController) throws -> KeyControl {
        try XCTUnwrap(descendants(keyboard.view).compactMap { $0 as? KeyControl }.first { $0.value == value })
    }
    private func expansion(_ keyboard: KeyboardViewController) -> DeleteKeyExpansion? {
        keyboard.view.subviews.compactMap { $0 as? DeleteKeyExpansion }.first
    }
    private func withKeyboard(width: CGFloat = 466, landscape: Bool = false, mini: Bool = false,
                              tablet: Bool = false, language: KeyboardLanguage = .english,
                              style: UIUserInterfaceStyle = .light,
                              _ body: (KeyboardViewController, TextViewProxy) async throws -> Void) async throws {
        let oldLanguage = KeyboardLanguage.load(), oldMode = KeyboardLayoutMode.load()
        language.save(); (mini ? KeyboardLayoutMode.mini : .full).save()
        await withCheckedContinuation { c in PinyinEngine.shared.perform(.clear) { _ in c.resume() } }
        let keyboard = KeyboardViewController(), proxy = TextViewProxy("Keep this draft.", selection: .init(location: 16, length: 0))
        keyboard.testingDocumentProxy = proxy; keyboard.testingVoiceAvailable = true
        keyboard.testingLandscape = landscape; keyboard.testingTablet = tablet
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene), host = UIViewController()
        window.rootViewController = host; window.overrideUserInterfaceStyle = style; window.isHidden = false
        host.loadViewIfNeeded(); host.addChild(keyboard); host.view.addSubview(keyboard.view); keyboard.didMove(toParent: host)
        keyboard.overrideUserInterfaceStyle = style
        keyboard.view.frame = CGRect(x: 0, y: 0, width: width, height: KeyboardMetrics(width: width, landscape: landscape, mini: mini, tablet: tablet).contentHeight)
        keyboard.viewDidLayoutSubviews(); keyboard.view.layoutIfNeeded()
        defer {
            keyboard.viewWillDisappear(false); keyboard.willMove(toParent: nil); keyboard.view.removeFromSuperview(); keyboard.removeFromParent()
            window.isHidden = true; oldLanguage.save(); oldMode.save()
        }
        try await body(keyboard, proxy)
    }
    private func hold(_ keyboard: KeyboardViewController) throws -> KeyControl {
        let delete = try key("delete", keyboard)
        XCTAssertTrue(delete.press(at: 0, point: CGPoint(x: delete.bounds.midX, y: delete.bounds.midY)))
        XCTAssertNil(expansion(keyboard), "A tap must not show the extension")
        delete.advancePress(to: 0.4)
        return delete
    }

    func testSweepReachesBroomAcrossDuoOrientationsMiniSymbolsAndTablet() async throws {
        XCTAssertEqual(UIImage(systemName: "trash")?.isSymbolImage, true)
        for (width, landscape, tablet): (CGFloat, Bool, Bool) in [(375,false,false),(466,false,false),(655,false,false),(529,true,false),(802,true,false),(834,false,true),(1194,true,true)] {
            for mini in [false, true] {
                try await withKeyboard(width: width, landscape: landscape, mini: mini, tablet: tablet) { keyboard, proxy in
                    let delete = try key("delete", keyboard), original = delete.convert(delete.bounds, to: keyboard.view)
                    let source = try hold(keyboard), visual = try XCTUnwrap(expansion(keyboard))
                    let icon = try XCTUnwrap(descendants(visual).first { $0.accessibilityIdentifier == "keyboard.delete-broom" } as? UIImageView)
                    XCTAssertEqual(icon.image?.isSymbolImage, true)
                    XCTAssertEqual(icon.image?.pngData(), UIImage(systemName: "trash")?.pngData(), "Use the Apple trash symbol, not custom artwork")
                    XCTAssertEqual(icon.preferredSymbolConfiguration, UIImage.SymbolConfiguration(pointSize: 20, weight: .regular).applying(.preferringMonochrome()))
                    XCTAssertFalse(visual.isUserInteractionEnabled, "The overlay must never become tap-to-clear")
                    XCTAssertEqual(delete.convert(delete.bounds, to: keyboard.view), original)
                    XCTAssertEqual(visual.frame.maxX, original.maxX, accuracy: 0.01)
                    XCTAssertTrue(keyboard.view.bounds.insetBy(dx: -0.5, dy: -0.5).contains(visual.frame))
                    if !mini && !tablet {
                        let m = try key("m", keyboard)
                        XCTAssertEqual(visual.frame.minX, m.convert(m.bounds, to: keyboard.view).minX, accuracy: 0.01)
                        let surface = try XCTUnwrap(m.touchSurface)
                        XCTAssertTrue(surface.target(at: m.convert(CGPoint(x: m.bounds.midX,y: m.bounds.midY), to: surface)) === m, "Hidden paint must not alter a second finger's target")
                    }
                    if mini { XCTAssertLessThan(visual.frame.width, 170, "Only borrow the edge of Dictate") }
                    let beforeSweep = proxy.editor.text
                    let target = try XCTUnwrap(source.deleteClearTargetX)
                    source.movePress(to: CGPoint(x: target + 2, y: source.bounds.midY), at: 0.45)
                    XCTAssertEqual(proxy.editor.text, beforeSweep)
                    source.movePress(to: CGPoint(x: target - 1, y: source.bounds.midY), at: 0.5)
                    for _ in 0..<50 where proxy.hasText { try await Task.sleep(for: .milliseconds(10)) }
                    XCTAssertEqual(proxy.editor.text, ""); XCTAssertTrue(visual.cleared)
                    source.movePress(to: CGPoint(x: target - 20, y: source.bounds.midY), at: 0.7)
                    source.releasePress(); source.advancePress(to: 5)
                    XCTAssertEqual(proxy.editor.text, ""); XCTAssertTrue(keyboard.testingVoiceCommands.isEmpty)
                    XCTAssertEqual(source.icon.alpha, 1)
                    for _ in 0..<50 where expansion(keyboard) != nil { try await Task.sleep(for: .milliseconds(10)) }
                    XCTAssertNil(expansion(keyboard))
                }
            }
        }
        for language in [KeyboardLanguage.chinese, .english] {
            try await withKeyboard(width: 802, landscape: true, language: language) { keyboard, _ in
                _ = try key("123", keyboard).accessibilityActivate(); keyboard.view.layoutIfNeeded()
                let delete = try hold(keyboard)
                XCTAssertNotNil(expansion(keyboard)); delete.cancelPress()
                XCTAssertNil(expansion(keyboard)); XCTAssertEqual(delete.icon.alpha, 1)
            }
        }
    }

    func testCancellationAndLayoutChangesRestoreBorrowedKeyWithoutClear() async throws {
        for interruption in 0..<4 {
            try await withKeyboard { keyboard, proxy in
                let source = try hold(keyboard), m = try key("m", keyboard)
                XCTAssertEqual(m.label.alpha, 0)
                let text = proxy.editor.text
                switch interruption {
                case 0: source.movePress(to: CGPoint(x: -100, y: 100), at: 0.5)
                case 1: proxy.documentIdentifier = UUID(); keyboard.textDidChange(nil)
                case 2:
                    keyboard.view.frame.size.width = 655; keyboard.viewDidLayoutSubviews()
                default: keyboard.viewWillDisappear(false)
                }
                source.releasePress(); source.advancePress(to: 5)
                XCTAssertEqual(proxy.editor.text, text)
                XCTAssertNil(expansion(keyboard)); XCTAssertEqual(m.label.alpha, 1); XCTAssertNotNil(m.backgroundColor)
            }
        }
    }
    func testGapHoldAndDictationCancelDoNotExpandDelete() async throws {
        try await withKeyboard { keyboard, _ in
            let delete = try key("delete", keyboard)
            XCTAssertTrue(delete.press(at: 0, point: CGPoint(x: -1, y: delete.bounds.midY)))
            delete.advancePress(to: 0.4)
            XCTAssertNil(expansion(keyboard)); XCTAssertEqual(keyboard.testingVoiceCommands.last?.phase, .recording)
            delete.cancelPress()
            let letter = try key("a", keyboard)
            XCTAssertTrue(letter.press(at: 2, point: CGPoint(x: letter.bounds.midX, y: letter.bounds.midY)))
            letter.advancePress(to: 2.4)
            letter.movePress(to: delete.convert(CGPoint(x: delete.bounds.midX,y: delete.bounds.midY), to: letter), at: 2.5)
            XCTAssertNil(expansion(keyboard)); XCTAssertEqual(keyboard.testingVoiceCommands.last?.phase, .cancel)
            letter.releasePress()
        }
    }
    func testNativeExpandedDeleteContactSheet() async throws {
        var panels: [(String, UIImage)] = []
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        for (width, landscape, mini): (CGFloat,Bool,Bool) in [(466,false,false),(655,false,false),(529,true,false),(802,true,false),(466,false,true),(802,true,true)] {
            for style in [UIUserInterfaceStyle.light, .dark] {
                try await withKeyboard(width: width, landscape: landscape, mini: mini, style: style) { keyboard, _ in
                    let source = try hold(keyboard)
                    try await Task.sleep(for: .milliseconds(220))
                    keyboard.view.layoutIfNeeded()
                    let image = UIGraphicsImageRenderer(size: keyboard.view.bounds.size, format: format).image { context in
                        (style == .light ? UIColor(white: 0.83, alpha: 1) : UIColor(white: 0.16, alpha: 1)).setFill()
                        context.fill(keyboard.view.bounds); keyboard.view.layer.render(in: context.cgContext)
                    }
                    panels.append(("\(Int(width)) pt · \(landscape ? "Landscape" : "Portrait") · \(mini ? "Mini" : "Full") · \(style == .light ? "Light" : "Dark")",image))
                    let name = "delete-trash-\(Int(width))-\(mini ? "mini" : "full")-\(style == .light ? "light" : "dark")"
                    let png = try XCTUnwrap(image.pngData())
                    let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                    attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
                    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                    let directory = root.appendingPathComponent(".airbuild/artifacts/phone-layout")
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try png.write(to: directory.appendingPathComponent("\(name).png"))
                    source.cancelPress()
                }
            }
        }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1640, height: 2100), format: format).image { context in
            UIColor(white: 0.95, alpha: 1).setFill(); context.fill(CGRect(x: 0,y: 0,width: 1640,height: 2100))
            for (index, panel) in panels.enumerated() {
                let origin = CGPoint(x: index % 2 * 820 + 8, y: index / 2 * 350 + 8)
                (panel.0 as NSString).draw(at: origin, withAttributes: [.font:UIFont.systemFont(ofSize:14),.foregroundColor:UIColor.black])
                panel.1.draw(at: CGPoint(x: origin.x, y: origin.y + 24))
            }
        }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("vvhisper-delete-expansion.png")
        try image.pngData()!.write(to: path); print("Delete expansion artifact: \(path.path)")
    }
}
