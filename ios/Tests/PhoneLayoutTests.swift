import XCTest
import UIKit
@testable import vvhisper

/// Regular iPhone portrait keeps one bottom row (123, Language, Emoji, Space,
/// Return) with no extra accessory row; Duo arrangements stay as measured.
@MainActor
final class PhoneLayoutTests: XCTestCase {
    private let phoneWidths: [CGFloat] = [375, 402, 440]

    private func descendants(_ view: UIView) -> [UIView] { view.subviews.flatMap { [$0] + descendants($0) } }

    private func makeKeyboard(width: CGFloat, landscape: Bool = false, returnKeyType: UIReturnKeyType = .search,
                              language: KeyboardLanguage = .english) -> (KeyboardViewController, TextViewProxy) {
        language.save(); KeyboardLayoutMode.full.save()
        let keyboard = KeyboardViewController()
        let proxy = TextViewProxy("", selection: NSRange(location: 0, length: 0))
        proxy.returnKeyType = returnKeyType
        keyboard.testingDocumentProxy = proxy
        keyboard.testingLandscape = landscape
        keyboard.testingTablet = false
        keyboard.loadViewIfNeeded()
        let height = KeyboardMetrics(width: width, landscape: landscape).contentHeight
        keyboard.view.frame = CGRect(x: 0, y: 0, width: width, height: height)
        keyboard.viewDidLayoutSubviews(); keyboard.view.layoutIfNeeded()
        return (keyboard, proxy)
    }

    private func withSavedPreferences(_ body: () async throws -> Void) async rethrows {
        let mode = UserDefaults.standard.object(forKey: KeyboardLayoutMode.preferenceKey)
        let language = UserDefaults.standard.object(forKey: KeyboardLanguage.preferenceKey)
        defer {
            UserDefaults.standard.set(mode, forKey: KeyboardLayoutMode.preferenceKey)
            UserDefaults.standard.set(language, forKey: KeyboardLanguage.preferenceKey)
        }
        try await body()
    }

    private func frame(_ view: UIView, in keyboard: KeyboardViewController) -> CGRect {
        view.convert(view.bounds, to: keyboard.view)
    }

    private func control(_ identifier: String, _ keyboard: KeyboardViewController) throws -> UIView {
        try XCTUnwrap(descendants(keyboard.view).first { $0.accessibilityIdentifier == identifier && !$0.isHidden }, identifier)
    }

    /// Key rows as distinct top edges of every visible key/switcher.
    private func keyRows(_ keyboard: KeyboardViewController) -> [[UIView]] {
        let controls = descendants(keyboard.view).filter { ($0 is KeyControl || $0 is KeyboardSwitcherButton) && !$0.isHidden && $0.alpha > 0 }
        var rows: [CGFloat: [UIView]] = [:]
        for view in controls { rows[(frame(view, in: keyboard).minY * 2).rounded() / 2, default: []].append(view) }
        return rows.keys.sorted().map { y in rows[y]!.sorted { frame($0, in: keyboard).minX < frame($1, in: keyboard).minX } }
    }

    func testPhoneMetricsDropAccessoryRowAndUseLetterKeyRatios() {
        for width in phoneWidths {
            let metrics = KeyboardMetrics(width: width)
            XCTAssertEqual(metrics.arrangement, .phone)
            XCTAssertTrue(metrics.inlineAccessories)
            XCTAssertEqual(metrics.contentHeight, metrics.candidateHeight + 4 * metrics.keyHeight + 3 * metrics.rowGap, accuracy: 0.01,
                           "No +50 accessory row at \(width)")
            let letter = (width - 2 * metrics.inset - 9 * metrics.keyGap) / 10
            XCTAssertEqual(metrics.letterWidth, letter, accuracy: 0.01)
            XCTAssertEqual(metrics.modeWidth / letter, 1.25, accuracy: 0.01)
            XCTAssertEqual(metrics.languageWidth / letter, 1.25, accuracy: 0.01)
            XCTAssertEqual(metrics.switcherWidth / letter, 1, accuracy: 0.01)
            XCTAssertEqual(metrics.returnWidth / letter, 2.5, accuracy: 0.01)
        }
        XCTAssertEqual(KeyboardMetrics(width: 402).contentHeight, 252, accuracy: 0.01)
    }

    func testPhoneBottomRowOrderWidthsAndGapsMatchLetterRows() async throws {
        try await withSavedPreferences {
            for width in phoneWidths {
                let (keyboard, _) = makeKeyboard(width: width)
                defer { keyboard.viewWillDisappear(false) }
                let rows = keyRows(keyboard)
                XCTAssertEqual(rows.count, 4, "Exactly four key rows at \(width)")
                let panel = try XCTUnwrap(descendants(keyboard.view).first { $0 is CandidatePanel })
                XCTAssertLessThanOrEqual(panel.frame.maxY, frame(rows[0][0], in: keyboard).minY, "Candidate strip sits above the keys")
                guard rows.count == 4 else { continue }
                let ids = rows[3].map { $0.accessibilityIdentifier ?? "" }
                XCTAssertEqual(ids, ["keyboard.key.123", "keyboard.key.language", "keyboard.key.globe", "keyboard.key.space", "keyboard.key.return"],
                               "Bottom row order at \(width)")
                let q = frame(try control("keyboard.key.q", keyboard), in: keyboard)
                let w = frame(try control("keyboard.key.w", keyboard), in: keyboard)
                let letter = q.width, letterGap = w.minX - q.maxX
                let frames = rows[3].map { frame($0, in: keyboard) }
                for (index, ratio) in [(0, 1.25), (1, 1.25), (2, 1.0), (4, 2.5)] {
                    XCTAssertEqual(frames[index].width / letter, CGFloat(ratio), accuracy: 0.05, "\(ids[index]) at \(width)")
                }
                XCTAssertGreaterThan(frames[3].width, 3 * letter, "Space takes the rest at \(width)")
                for (left, right) in zip(frames, frames.dropFirst()) {
                    XCTAssertEqual(right.minX - left.maxX, letterGap, accuracy: 0.5, "Same gap as letter rows at \(width)")
                }
                for item in frames {
                    XCTAssertEqual(item.height, q.height, accuracy: 0.5)
                    XCTAssertEqual(item.minY, frames[0].minY, accuracy: 0.5)
                }
                XCTAssertEqual(frames[0].minX, q.minX, accuracy: 0.5)
                XCTAssertEqual(frames[4].maxX, frame(try control("keyboard.key.p", keyboard), in: keyboard).maxX, accuracy: 0.5)
                XCTAssertLessThanOrEqual(frames[4].maxY, keyboard.view.bounds.height + 0.5)
                // Emoji shares the function-key fill and corner radius of 123 and Language.
                let emoji = try XCTUnwrap(rows[3][2] as? UIButton), mode = try XCTUnwrap(rows[3][0] as? KeyControl)
                let language = try XCTUnwrap(rows[3][1] as? KeyControl)
                for style in [UIUserInterfaceStyle.light, .dark] {
                    let traits = UITraitCollection(userInterfaceStyle: style)
                    XCTAssertEqual(emoji.backgroundColor?.resolvedColor(with: traits), mode.backgroundColor?.resolvedColor(with: traits))
                    XCTAssertEqual(emoji.backgroundColor?.resolvedColor(with: traits), language.backgroundColor?.resolvedColor(with: traits))
                    XCTAssertEqual(emoji.backgroundColor?.resolvedColor(with: traits), KeyboardMetrics.keyFill.resolvedColor(with: traits))
                }
                XCTAssertEqual(emoji.layer.cornerRadius, mode.layer.cornerRadius)
                XCTAssertEqual(emoji.layer.cornerRadius, KeyboardMetrics(width: width).cornerRadius)
                XCTAssertEqual(language.layer.cornerRadius, mode.layer.cornerRadius)
            }
        }
    }

    func testLongReturnTitlesShrinkInsideOneRow() async throws {
        try await withSavedPreferences {
            for width in phoneWidths {
                for type: UIReturnKeyType in [.search, .send, .continue, .emergencyCall, .route, .join, .default] {
                    let (keyboard, _) = makeKeyboard(width: width, returnKeyType: type)
                    defer { keyboard.viewWillDisappear(false) }
                    let enter = try XCTUnwrap(try control("keyboard.key.return", keyboard) as? KeyControl)
                    for override in [nil, "发送", "换行", "前往搜索"] as [String?] {
                        if let override { enter.label.text = override }
                        enter.setNeedsLayout(); keyboard.view.layoutIfNeeded()
                        XCTAssertEqual(keyRows(keyboard).count, 4, "Return \(type.rawValue) \(override ?? "") at \(width)")
                        XCTAssertEqual(frame(enter, in: keyboard).minY, frame(try control("keyboard.key.space", keyboard), in: keyboard).minY, accuracy: 0.5)
                        guard let title = enter.label.text, !title.isEmpty else { continue }
                        XCTAssertEqual(enter.label.numberOfLines, 1)
                        XCTAssertTrue(enter.label.adjustsFontSizeToFitWidth)
                        XCTAssertLessThanOrEqual(enter.label.frame.width, enter.bounds.width - 3.5, "\(title) stays inside Return at \(width)")
                        XCTAssertGreaterThanOrEqual(enter.label.frame.minX, 0)
                        let smallest = enter.label.font.withSize(enter.label.font.pointSize * enter.label.minimumScaleFactor)
                        let needed = (title as NSString).size(withAttributes: [.font: smallest]).width
                        XCTAssertLessThanOrEqual(needed, enter.label.frame.width + 0.5, "\(title) fits at minimum scale at \(width)")
                    }
                }
            }
        }
    }

    func testDuoArrangementsAreUnchanged() async throws {
        // Values measured on iPhone Duo before the 2026-11-26 phone change.
        let expected: [(CGFloat, Bool, KeyboardMetrics.Arrangement, CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (466, false, .outerPortrait, 39.667, 39.667, 96, 47 + 4 * 44.667 + 3 * 11.667 + 6.667),
            (470, false, .outerPortrait, 39.667, 39.667, 96, 47 + 4 * 44.667 + 3 * 11.667 + 6.667),
            (640, false, .innerPortrait, 50.667, 50.667, 120, 47 + 4 * 49.667 + 3 * 14 + 3.333),
            (655, false, .innerPortrait, 50.667, 50.667, 120, 47 + 4 * 49.667 + 3 * 14 + 3.333),
            (529, true, .outerLandscape, 45.333, 45.333, 104, 43 + 4 * 33.333 + 3 * 9 + 4),
            (802, true, .innerLandscape, 46.667, 46.667, 112, 43.333 + 4 * 42.333 + 3 * 13 + 3.667),
        ]
        for (width, landscape, arrangement, mode, switcher, enter, height) in expected {
            let metrics = KeyboardMetrics(width: width, landscape: landscape)
            XCTAssertEqual(metrics.arrangement, arrangement, "\(width)")
            XCTAssertEqual(metrics.modeWidth, mode, accuracy: 0.001)
            XCTAssertEqual(metrics.switcherWidth, switcher, accuracy: 0.001)
            XCTAssertEqual(metrics.languageWidth, switcher, accuracy: 0.001)
            XCTAssertEqual(metrics.returnWidth, enter, accuracy: 0.001)
            XCTAssertEqual(metrics.contentHeight, height, accuracy: 0.01)
            XCTAssertEqual(metrics.inlineAccessories, arrangement != .innerLandscape)
            XCTAssertEqual(metrics.split, arrangement == .innerLandscape)
        }
        try await withSavedPreferences {
            for (width, landscape) in [(CGFloat(466), false), (470, false), (640, false), (529, true)] {
                let (keyboard, _) = makeKeyboard(width: width, landscape: landscape)
                defer { keyboard.viewWillDisappear(false) }
                let rows = keyRows(keyboard)
                XCTAssertEqual(rows.count, 4, "Duo \(width)")
                XCTAssertEqual(rows.last?.map { $0.accessibilityIdentifier ?? "" },
                               ["keyboard.key.123", "keyboard.key.language", "keyboard.key.globe", "keyboard.key.space", "keyboard.key.return"])
                let metrics = KeyboardMetrics(width: width, landscape: landscape)
                let widths = rows.last!.map { frame($0, in: keyboard).width }
                XCTAssertEqual(widths[0], metrics.modeWidth, accuracy: 0.5)
                XCTAssertEqual(widths[1], metrics.switcherWidth, accuracy: 0.5)
                XCTAssertEqual(widths[2], metrics.switcherWidth, accuracy: 0.5)
                XCTAssertEqual(widths[4], metrics.returnWidth, accuracy: 0.5)
            }
        }
    }

    // MARK: Candidate strip

    private func luminance(_ color: UIColor) -> CGFloat {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        func channel(_ c: CGFloat) -> CGFloat { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }
    private func over(_ top: UIColor, _ bottom: UIColor) -> UIColor {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        top.getRed(&r1, green: &g1, blue: &b1, alpha: &a1); bottom.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return UIColor(red: r1 * a1 + r2 * (1 - a1), green: g1 * a1 + g2 * (1 - a1), blue: b1 * a1 + b2 * (1 - a1), alpha: 1)
    }
    private func contrast(_ a: UIColor, _ b: UIColor) -> CGFloat {
        let l1 = luminance(a), l2 = luminance(b)
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    func testCandidateStripIsOpaqueWithReadableText() throws {
        let panel = CandidatePanel(frame: CGRect(x: 0, y: 0, width: 402, height: 44))
        for style in [UIUserInterfaceStyle.light, .dark] {
            for contrastSetting in [UIAccessibilityContrast.normal, .high] {
                let traits = UITraitCollection { $0.userInterfaceStyle = style; $0.accessibilityContrast = contrastSetting }
                let fill = try XCTUnwrap(panel.backgroundColor).resolvedColor(with: traits)
                var alpha: CGFloat = 0; fill.getRed(nil, green: nil, blue: nil, alpha: &alpha)
                XCTAssertEqual(alpha, 1, "Candidate strip is opaque in \(style.rawValue)")
                let ink = UIColor.label.resolvedColor(with: traits)
                XCTAssertGreaterThanOrEqual(contrast(ink, fill), 4.5)
                // The highlighted first candidate sits on secondarySystemFill.
                let highlighted = over(UIColor.secondarySystemFill.resolvedColor(with: traits), fill)
                XCTAssertGreaterThanOrEqual(contrast(ink, highlighted), 4.5)
            }
        }
        let collection = try XCTUnwrap(descendants(panel).compactMap { $0 as? UICollectionView }.first)
        XCTAssertTrue(collection.topEdgeEffect.isHidden && collection.bottomEdgeEffect.isHidden
                      && collection.leftEdgeEffect.isHidden && collection.rightEdgeEffect.isHidden)
    }

    // MARK: Evidence renders (offscreen, inside the test runner)

    private static let evidenceDirectory: URL = {
        // ios/Tests/PhoneLayoutTests.swift -> repository root
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".airbuild/artifacts/phone-layout", isDirectory: true)
    }()

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }

    private func render(name: String, width: CGFloat, style: UIUserInterfaceStyle, returnKeyType: UIReturnKeyType = .search,
                        returnTitle: String? = nil) async throws {
        await withCheckedContinuation { c in PinyinEngine.shared.perform(.clear) { _ in c.resume() } }
        let (keyboard, proxy) = makeKeyboard(width: width, returnKeyType: returnKeyType, language: .chinese)
        defer { keyboard.viewWillDisappear(false) }
        let height = keyboard.view.bounds.height
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: height)
        window.overrideUserInterfaceStyle = style
        let backdrop = UIView(frame: window.bounds)
        backdrop.backgroundColor = style == .dark ? UIColor(white: 0.16, alpha: 1) : UIColor(red: 0.82, green: 0.83, blue: 0.86, alpha: 1)
        // Busy "host content" behind the keyboard: it must not show through the candidate strip.
        for line in 0..<Int(height / 18) {
            let text = UILabel(frame: CGRect(x: 0, y: CGFloat(line) * 18, width: width, height: 18))
            text.text = String(repeating: "背景 Behind 文字 ", count: 8)
            text.font = .systemFont(ofSize: 15, weight: .bold)
            text.textColor = [UIColor.systemOrange, .systemTeal, .systemPink][line % 3]
            backdrop.addSubview(text)
        }
        window.addSubview(backdrop)
        window.addSubview(keyboard.view)
        window.isHidden = false
        keyboard.view.frame = window.bounds
        keyboard.viewDidLayoutSubviews(); keyboard.view.layoutIfNeeded()
        let k = try XCTUnwrap(try control("keyboard.key.k", keyboard) as? KeyControl)
        XCTAssertTrue(k.accessibilityActivate())
        try await waitUntil { proxy.editor.text == "k" && self.descendants(keyboard.view).contains { $0.accessibilityIdentifier == "candidate.0" } }
        if let returnTitle, let enter = try control("keyboard.key.return", keyboard) as? KeyControl { enter.label.text = returnTitle }
        keyboard.view.setNeedsLayout(); keyboard.view.layoutIfNeeded()
        XCTAssertEqual(keyRows(keyboard).count, 4, name)
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let png = try XCTUnwrap(image.pngData())
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = "phone-layout-\(name).png"; attachment.lifetime = .keepAlways
        add(attachment)
        do {
            try FileManager.default.createDirectory(at: Self.evidenceDirectory, withIntermediateDirectories: true)
            try png.write(to: Self.evidenceDirectory.appendingPathComponent("phone-layout-\(name).png"))
        } catch { print("phone-layout evidence not written to source tree: \(error)") }
        window.isHidden = true
        keyboard.view.removeFromSuperview()
    }

    func testRenderPhoneAndDuoEvidence() async throws {
        try await withSavedPreferences {
            for width in phoneWidths {
                let w = Int(width)
                try await render(name: "\(w)-light-search", width: width, style: .light)
                try await render(name: "\(w)-dark-search", width: width, style: .dark)
                try await render(name: "\(w)-dark-zh-huanhang", width: width, style: .dark, returnKeyType: .done, returnTitle: "换行")
                try await render(name: "\(w)-light-emergency-call", width: width, style: .light, returnKeyType: .emergencyCall)
            }
            try await render(name: "duo-466-outer-portrait-dark-search", width: 466, style: .dark)
            try await render(name: "duo-466-outer-portrait-light-search", width: 466, style: .light)
        }
    }
}
