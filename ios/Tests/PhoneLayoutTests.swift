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

    private static let appearances: [UITraitCollection] = [UIUserInterfaceStyle.light, .dark].flatMap { style in
        [UIAccessibilityContrast.normal, .high].map { contrast in
            UITraitCollection { $0.userInterfaceStyle = style; $0.accessibilityContrast = contrast }
        }
    }

    private func paintAlpha(_ view: UIView, _ traits: UITraitCollection) -> CGFloat {
        var alpha: CGFloat = 0
        view.backgroundColor?.resolvedColor(with: traits).getRed(nil, green: nil, blue: nil, alpha: &alpha)
        let layerAlpha = view.layer.backgroundColor?.alpha ?? 0
        return max(alpha, view.backgroundColor == nil ? layerAlpha : 0)
    }

    private func visibleDescendants(_ view: UIView) -> [UIView] {
        view.subviews.filter { !$0.isHidden && $0.alpha > 0.01 }.flatMap { [$0] + visibleDescendants($0) }
    }

    private func sameColor(_ a: UIColor?, _ b: UIColor, _ traits: UITraitCollection) -> Bool {
        guard let a else { return false }
        return a.resolvedColor(with: traits) == b.resolvedColor(with: traits)
    }

    /// Designer decision 2026-11-27: the strip has no fill, blur or corner radius of
    /// its own; the system keyboard glass shows straight through, continuous with
    /// the keys, on regular iPhones and on the Duo.
    func testCandidateStripLetsSystemGlassThrough() async throws {
        try await withSavedPreferences {
            for width in phoneWidths + [466] {
                await withCheckedContinuation { c in PinyinEngine.shared.perform(.clear) { _ in c.resume() } }
                let (keyboard, proxy) = makeKeyboard(width: width, language: .chinese)
                defer { keyboard.viewWillDisappear(false) }
                let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
                let window = UIWindow(windowScene: scene)
                window.frame = keyboard.view.frame
                window.addSubview(keyboard.view); window.isHidden = false
                defer { window.isHidden = true; keyboard.view.removeFromSuperview() }
                keyboard.viewDidLayoutSubviews(); keyboard.view.layoutIfNeeded()
                let k = try XCTUnwrap(try control("keyboard.key.k", keyboard) as? KeyControl)
                XCTAssertTrue(k.accessibilityActivate())
                try await waitUntil { proxy.editor.text == "k" && self.descendants(keyboard.view).contains { $0.accessibilityIdentifier == "candidate.0" } }
                keyboard.view.setNeedsLayout(); keyboard.view.layoutIfNeeded()
                let panel = try XCTUnwrap(descendants(keyboard.view).first { $0 is CandidatePanel } as? CandidatePanel)
                XCTAssertFalse(panel.isHidden, "\(width)")
                XCTAssertFalse(panel.isOpaque, "\(width)")

                // The panel and every ancestor up to the keyboard root: no paint, radius or blur.
                var chain: [UIView] = []
                var node: UIView? = panel
                while let current = node { chain.append(current); if current === keyboard.view { break }; node = current.superview }
                XCTAssertTrue(chain.last === keyboard.view, "Panel sits under the keyboard root at \(width)")
                for view in chain {
                    for traits in Self.appearances {
                        XCTAssertLessThan(paintAlpha(view, traits), 0.01, "\(type(of: view)) paints a background at \(width)")
                    }
                    XCTAssertEqual(view.layer.cornerRadius, 0, "\(type(of: view)) at \(width)")
                    XCTAssertFalse(view is UIVisualEffectView, "\(type(of: view)) at \(width)")
                    XCTAssertFalse(view.subviews.contains { $0 is UIVisualEffectView && !$0.isHidden }, "Blur in \(type(of: view)) at \(width)")
                }
                // Inside the strip only the default candidate's small rounded highlight paints.
                let buttons = visibleDescendants(panel).compactMap { $0 as? CandidateButton }
                XCTAssertFalse(buttons.isEmpty)
                let buttonParts = Set(buttons.flatMap { [ObjectIdentifier($0)] + descendants($0).map(ObjectIdentifier.init) })
                for view in visibleDescendants(panel) where !buttonParts.contains(ObjectIdentifier(view)) {
                    XCTAssertFalse(view is UIVisualEffectView, "Blur \(type(of: view)) in strip at \(width)")
                    for traits in Self.appearances {
                        XCTAssertLessThan(paintAlpha(view, traits), 0.01, "\(type(of: view)) paints inside the strip at \(width)")
                    }
                }
                // No other visible view behind or over the strip paints a fill (no grey band).
                let stripRect = frame(panel, in: keyboard)
                for view in visibleDescendants(keyboard.view) where !chain.contains(view) && view.window != nil {
                    guard !buttonParts.contains(ObjectIdentifier(view)), !descendants(panel).contains(view) else { continue }
                    guard frame(view, in: keyboard).intersects(stripRect) else { continue }
                    for traits in Self.appearances {
                        XCTAssertLessThan(paintAlpha(view, traits), 0.01, "\(type(of: view)) paints behind the strip at \(width)")
                    }
                    XCTAssertFalse(view is UIVisualEffectView, "\(type(of: view)) blurs behind the strip at \(width)")
                }
                // Text: system primary label colour, regular weight; candidate 0 keeps its highlight.
                let labels = buttons.flatMap { descendants($0).compactMap { $0 as? UILabel } }
                XCTAssertEqual(labels.count, buttons.count)
                for label in labels {
                    for traits in Self.appearances { XCTAssertTrue(sameColor(label.textColor, .label, traits), "Candidate ink is .label") }
                    XCTAssertEqual(label.font, CandidateButton.font)
                }
                let defaults = buttons.filter { $0.accessibilityTraits.contains(.selected) }
                XCTAssertEqual(defaults.count, 1, "One default candidate at \(width): \(buttons.map { $0.accessibilityIdentifier ?? "" })")
                let first = try XCTUnwrap(defaults.first)
                XCTAssertEqual(frame(first, in: keyboard).minX, buttons.map { frame($0, in: keyboard).minX }.min() ?? -1, accuracy: 0.5)
                let highlight = try XCTUnwrap(first.subviews.first { !($0 is UILabel) })
                for traits in Self.appearances {
                    XCTAssertTrue(sameColor(highlight.backgroundColor, .secondarySystemFill, traits), "Default highlight at \(width)")
                }
                XCTAssertEqual(highlight.layer.cornerRadius, 8)
                for button in buttons where button !== first {
                    XCTAssertTrue(button.subviews.allSatisfy { $0 is UILabel || paintAlpha($0, Self.appearances[0]) < 0.01 },
                                  "Only the default candidate is highlighted at \(width): \(button.accessibilityIdentifier ?? "")")
                }
                // Scroll edge effects stay hidden (their blur made words look fuzzy).
                let collection = try XCTUnwrap(descendants(panel).compactMap { $0 as? UICollectionView }.first)
                XCTAssertTrue(collection.topEdgeEffect.isHidden && collection.bottomEdgeEffect.isHidden
                              && collection.leftEdgeEffect.isHidden && collection.rightEdgeEffect.isHidden)
                // The trailing fade is a pure alpha mask on the words, never a coloured overlay.
                if let mask = collection.layer.mask {
                    let gradient = try XCTUnwrap(mask as? CAGradientLayer)
                    XCTAssertEqual(try XCTUnwrap(gradient.colors as? [CGColor]).map(\.alpha), [1, 1, 0])
                }
                for layer in [panel.layer, collection.layer] {
                    XCTAssertFalse((layer.sublayers ?? []).contains { $0 is CAGradientLayer }, "No painted gradient overlay at \(width)")
                }
            }
        }
    }

    func testCollapsedStripFadesTrailingEdgeBeforeChevron() throws {
        XCTAssertEqual(CandidatePanel.trailingFadeWidth, 24)
        let words = (0..<40).map { PinyinCandidates.Candidate(text: "候选词\($0)", identifier: "candidate.\($0)", action: .chooseAbsolute($0)) }
        for width in phoneWidths + [466] {
            let panel = CandidatePanel(frame: CGRect(x: 0, y: 0, width: width, height: 44))
            panel.show(words, hasMore: false)
            panel.layoutIfNeeded()
            let collection = try XCTUnwrap(descendants(panel).compactMap { $0 as? UICollectionView }.first)
            collection.layoutIfNeeded()
            let chevron = try XCTUnwrap(descendants(panel).first { $0.accessibilityIdentifier == "candidate.expand" })
            XCTAssertEqual(collection.frame.maxX, chevron.frame.minX, accuracy: 0.01, "Fade ends at the chevron at \(width)")
            let mask = try XCTUnwrap(collection.layer.mask as? CAGradientLayer, "Overflowing strip fades at \(width)")
            XCTAssertEqual(mask.frame, collection.bounds)
            XCTAssertEqual(mask.startPoint, CGPoint(x: 0, y: 0.5)); XCTAssertEqual(mask.endPoint, CGPoint(x: 1, y: 0.5))
            let stops = try XCTUnwrap(mask.locations).map { CGFloat($0.doubleValue) }
            XCTAssertEqual(stops.count, 3)
            XCTAssertEqual((1 - stops[1]) * mask.bounds.width, 24, accuracy: 0.01, "24pt fade at \(width)")
            let alphas = try XCTUnwrap(mask.colors as? [CGColor]).map(\.alpha)
            XCTAssertEqual(alphas, [1, 1, 0])
            // Pure alpha: a mask contributes only its alpha, and it is not also drawn as a layer.
            XCTAssertFalse((collection.layer.sublayers ?? []).contains { $0 === mask })
            XCTAssertFalse((panel.layer.sublayers ?? []).contains { $0 === mask })
            // The highlighted first candidate stays fully opaque.
            let first = try XCTUnwrap(collection.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))).frame
            XCTAssertLessThanOrEqual(first.maxX, collection.bounds.width - 24, "First candidate clear of the fade at \(width)")
            // The mask follows scrolling; at the end of the list nothing fades.
            collection.contentOffset.x = 120; collection.layoutIfNeeded()
            XCTAssertEqual((collection.layer.mask as? CAGradientLayer)?.frame.minX ?? -1, 120, accuracy: 0.01)
            collection.contentOffset.x = collection.contentSize.width - collection.bounds.width; collection.layoutIfNeeded()
            XCTAssertNil(collection.layer.mask, "No fade at the end at \(width)")
            collection.contentOffset.x = 0; collection.layoutIfNeeded()
            XCTAssertNotNil(collection.layer.mask)
            // The expanded browser wraps inside its width: no fade.
            panel.setExpanded(true); panel.layoutIfNeeded(); collection.layoutIfNeeded()
            XCTAssertNil(collection.layer.mask, "Expanded browser does not fade at \(width)")
            panel.setExpanded(false); panel.layoutIfNeeded(); collection.layoutIfNeeded()
            XCTAssertNotNil(collection.layer.mask)
        }
        // A short list that fits never fades.
        let panel = CandidatePanel(frame: CGRect(x: 0, y: 0, width: 402, height: 44))
        panel.show(Array(words.prefix(2)), hasMore: false); panel.layoutIfNeeded()
        let collection = try XCTUnwrap(descendants(panel).compactMap { $0 as? UICollectionView }.first)
        collection.layoutIfNeeded()
        XCTAssertNil(collection.layer.mask)
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
        // Plain neutral stand-in for the system keyboard glass (light #D1D3D9,
        // dark #2B2B2E): the strip must read as continuous with the key area.
        backdrop.backgroundColor = style == .dark
            ? UIColor(red: 0x2B / 255.0, green: 0x2B / 255.0, blue: 0x2E / 255.0, alpha: 1)
            : UIColor(red: 0xD1 / 255.0, green: 0xD3 / 255.0, blue: 0xD9 / 255.0, alpha: 1)
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
