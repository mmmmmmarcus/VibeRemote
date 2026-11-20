import XCTest
import UIKit
@testable import vvhisper

@MainActor final class SymbolAlternativesTests: XCTestCase {
    private func descendants(_ view: UIView) -> [UIView] { view.subviews.flatMap { [$0] + descendants($0) } }
    private func key(_ value: String, _ keyboard: KeyboardViewController) throws -> KeyControl {
        try XCTUnwrap(descendants(keyboard.view).compactMap { $0 as? KeyControl }.first { $0.value == value })
    }
    private func menu(_ keyboard: KeyboardViewController) throws -> SymbolAlternativesView {
        try XCTUnwrap(descendants(keyboard.view).compactMap { $0 as? SymbolAlternativesView }.first)
    }
    private func withKeyboard(width: CGFloat = 466, landscape: Bool = false, language: KeyboardLanguage = .english,
                              _ body: (KeyboardViewController, TextViewProxy) throws -> Void) async rethrows {
        let previous = UserDefaults.standard.string(forKey: KeyboardLanguage.preferenceKey)
        language.save()
        let keyboard = KeyboardViewController(), proxy = TextViewProxy("", selection: NSRange(location: 0, length: 0))
        keyboard.testingDocumentProxy = proxy; keyboard.testingVoiceAvailable = true; keyboard.testingLandscape = landscape
        keyboard.loadViewIfNeeded()
        keyboard.view.frame = CGRect(x: 0, y: 0, width: width, height: KeyboardMetrics(width: width, landscape: landscape).contentHeight)
        keyboard.viewDidLayoutSubviews(); keyboard.view.layoutIfNeeded()
        defer {
            keyboard.viewWillDisappear(false)
            if let previous { UserDefaults.standard.set(previous, forKey: KeyboardLanguage.preferenceKey) }
            else { UserDefaults.standard.removeObject(forKey: KeyboardLanguage.preferenceKey) }
        }
        await withCheckedContinuation { continuation in
            PinyinEngine.shared.perform(.prepare) { _ in continuation.resume() }
        }
        try body(keyboard, proxy)
    }
    private func hold(_ key: KeyControl) {
        XCTAssertTrue(key.press(at: 0, point: CGPoint(x: key.bounds.midX, y: key.bounds.midY)))
        key.advancePress(to: 0.4)
    }

    func testSymbolHoldsSelectExactlyOnceAndNeverDictateAcrossLayouts() async throws {
        for (width, landscape): (CGFloat, Bool) in [(375, false), (466, false), (655, false), (529, true), (802, true)] {
            try await withKeyboard(width: width, landscape: landscape) { keyboard, proxy in
                let popup = try menu(keyboard)
                @MainActor func showSymbols(_ page: Int) throws {
                    if let abc = descendants(keyboard.view).compactMap({ $0 as? KeyControl }).first(where: { $0.value == "ABC" }) {
                        _ = abc.accessibilityActivate()
                    }
                    _ = try key("123", keyboard).accessibilityActivate()
                    if page == 2 { _ = try key("#+=", keyboard).accessibilityActivate() }
                    keyboard.view.layoutIfNeeded()
                }
                for page in 1...2 {
                    try showSymbols(page)
                    let values = descendants(keyboard.view).compactMap { $0 as? KeyControl }.filter { $0.value.count == 1 }.map(\.value)
                    for value in values {
                        try showSymbols(page)
                        let source = try key(value, keyboard)
                        let before = proxy.editor.text ?? ""
                        hold(source)
                        XCTAssertFalse(popup.isHidden, source.value)
                        XCTAssertEqual(popup.selectedSymbol, source.value)
                        XCTAssertTrue(keyboard.view.bounds.contains(popup.frame))
                        XCTAssertFalse(popup.isUserInteractionEnabled)
                        let index = try XCTUnwrap(popup.choices.firstIndex(where: { $0 != source.value }))
                        let choice = popup.choices[index]
                        let point = CGPoint(x: 4 + (CGFloat(index) + 0.5) * (popup.bounds.width - 8) / CGFloat(popup.choices.count), y: popup.bounds.midY)
                        XCTAssertTrue(source.movePress(to: source.convert(point, from: popup), at: 0.5))
                        source.releasePress(); source.releasePress()
                        XCTAssertEqual(proxy.editor.text, before + choice)
                        XCTAssertTrue(popup.isHidden)
                        XCTAssertTrue(keyboard.testingVoiceCommands.isEmpty)
                        let returned = choice.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) }
                        XCTAssertNotNil(try key(returned ? "q" : "ABC", keyboard))
                    }
                }
            }
        }
    }

    func testChineseQuoteCapsOnBothPanelsAndEnglishQuotesRemainLiteral() async throws {
        for language in [KeyboardLanguage.chinese, .english] {
            try await withKeyboard(language: language) { keyboard, _ in
                _ = try key("123", keyboard).accessibilityActivate(); keyboard.view.layoutIfNeeded()
                XCTAssertEqual(try key(language == .chinese ? "「" : "\"", keyboard).label.text, language == .chinese ? "「" : "\"")
                XCTAssertNotNil(try key(language == .chinese ? "」" : "'", keyboard))
                _ = try key("#+=", keyboard).accessibilityActivate(); keyboard.view.layoutIfNeeded()
                XCTAssertNotNil(try key(language == .chinese ? "」" : "'", keyboard))
            }
        }
    }

    func testHoldingWithoutSlidingKeepsOriginalAndSlidingAwayCancels() async throws {
        try await withKeyboard { keyboard, proxy in
            _ = try key("123", keyboard).accessibilityActivate(); keyboard.view.layoutIfNeeded()
            let quote = try key("\"", keyboard), popup = try menu(keyboard)
            hold(quote)
            _ = quote.movePress(to: CGPoint(x: quote.bounds.midX, y: quote.bounds.midY), at: 0.5)
            quote.releasePress()
            XCTAssertEqual(proxy.editor.text, "\"")
            XCTAssertNotNil(try key("q", keyboard))
            _ = try key("123", keyboard).accessibilityActivate(); keyboard.view.layoutIfNeeded()
            let nextQuote = try key("\"", keyboard)
            hold(nextQuote)
            _ = nextQuote.movePress(to: CGPoint(x: -1000, y: -1000), at: 0.5)
            XCTAssertNil(popup.selectedSymbol); nextQuote.releasePress()
            XCTAssertEqual(proxy.editor.text, "\"")
        }
    }

    func testFieldChangesRolloverAndDismissalCancelSymbolSelection() async throws {
        try await withKeyboard { keyboard, proxy in
            _ = try key("123", keyboard).accessibilityActivate(); keyboard.view.layoutIfNeeded()
            let dollar = try key("$", keyboard), two = try key("2", keyboard), popup = try menu(keyboard)
            hold(dollar)
            proxy.documentIdentifier = UUID(); keyboard.selectionDidChange(nil); dollar.releasePress()
            XCTAssertTrue(popup.isHidden); XCTAssertEqual(proxy.editor.text, "")
            hold(dollar)
            XCTAssertTrue(two.press(at: 1, point: CGPoint(x: two.bounds.midX, y: two.bounds.midY)))
            two.releasePress(); dollar.releasePress()
            XCTAssertEqual(proxy.editor.text, "2"); XCTAssertTrue(popup.isHidden)
            hold(dollar); keyboard.viewWillDisappear(false); dollar.releasePress()
            XCTAssertEqual(proxy.editor.text, "2"); XCTAssertTrue(popup.isHidden)
        }
    }

    func testHostKeyboardAppearanceOverridesAppStyleAndKeysTransmitBackdrop() async throws {
        try await withKeyboard { keyboard, proxy in
            proxy.keyboardAppearance = .dark; keyboard.textDidChange(nil)
            XCTAssertEqual(keyboard.overrideUserInterfaceStyle, .dark)
            proxy.keyboardAppearance = .light; keyboard.textDidChange(nil)
            XCTAssertEqual(keyboard.overrideUserInterfaceStyle, .light)
            proxy.keyboardAppearance = .default; keyboard.textDidChange(nil)
            XCTAssertEqual(keyboard.overrideUserInterfaceStyle, .unspecified)
            for style in [UIUserInterfaceStyle.light, .dark] {
                let color = KeyboardMetrics.keyFill.resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
                if !UIAccessibility.isReduceTransparencyEnabled { XCTAssertLessThan(color.cgColor.alpha, 1) }
                let accessible = KeyboardMetrics.keyFill.resolvedColor(with: UITraitCollection { $0.userInterfaceStyle = style; $0.accessibilityContrast = .high })
                XCTAssertEqual(accessible.cgColor.alpha, 1)
            }
        }
    }

    func testNativeSymbolPreviewAcrossLayoutsAndAppearances() async throws {
        var panels: [(String, UIImage)] = []
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        for (width, landscape): (CGFloat, Bool) in [(375, false), (466, false), (655, false), (529, true), (802, true)] {
            for style in [UIUserInterfaceStyle.light, .dark] {
                try await withKeyboard(width: width, landscape: landscape, language: .chinese) { keyboard, _ in
                    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
                    let window = UIWindow(windowScene: scene), host = UIViewController()
                    window.rootViewController = host; window.overrideUserInterfaceStyle = style; window.isHidden = false
                    host.loadViewIfNeeded(); host.addChild(keyboard); host.view.addSubview(keyboard.view); keyboard.didMove(toParent: host)
                    keyboard.overrideUserInterfaceStyle = style
                    keyboard.view.frame = CGRect(x: 0, y: 0, width: width, height: KeyboardMetrics(width: width, landscape: landscape).contentHeight)
                    keyboard.viewDidLayoutSubviews(); keyboard.view.layoutIfNeeded()
                    defer { keyboard.willMove(toParent: nil); keyboard.view.removeFromSuperview(); keyboard.removeFromParent(); window.isHidden = true }
                    _ = try key("123", keyboard).accessibilityActivate(); keyboard.view.layoutIfNeeded()
                    hold(try key("「", keyboard))
                    let image = UIGraphicsImageRenderer(size: keyboard.view.bounds.size, format: format).image { context in
                        let colors = style == .dark ? [UIColor(red: 0.12, green: 0.18, blue: 0.25, alpha: 1).cgColor, UIColor(red: 0.21, green: 0.14, blue: 0.22, alpha: 1).cgColor] : [UIColor(red: 0.70, green: 0.78, blue: 0.85, alpha: 1).cgColor, UIColor(red: 0.85, green: 0.76, blue: 0.81, alpha: 1).cgColor]
                        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
                        context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: keyboard.view.bounds.height), options: [])
                        keyboard.view.layer.render(in: context.cgContext)
                    }
                    panels.append(("\(Int(width)) pt · \(landscape ? "Landscape" : "Portrait") · \(style == .light ? "Light" : "Dark")", image))
                }
            }
        }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1640, height: 1700), format: format).image { context in
            UIColor(white: 0.95, alpha: 1).setFill(); context.fill(CGRect(x: 0, y: 0, width: 1640, height: 1700))
            for (index, panel) in panels.enumerated() {
                let origin = CGPoint(x: (index % 2) * 820 + 8, y: (index / 2) * 340 + 6)
                (panel.0 as NSString).draw(at: origin, withAttributes: [.font: UIFont.systemFont(ofSize: 14), .foregroundColor: UIColor.black])
                panel.1.draw(at: CGPoint(x: origin.x, y: origin.y + 24))
            }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vvhisper-symbol-alternatives.png")
        try image.pngData()!.write(to: url)
        print("Symbol preview artifact: \(url.path)")
    }
}
