import XCTest
import UIKit
@testable import vvhisper

/// Symbol-page clipboard pills (designer spec 2026-11-27, clip-pills.md).
@MainActor final class ClipPillsTests: XCTestCase {
    private func descendants(_ view: UIView) -> [UIView] { view.subviews.flatMap { [$0] + descendants($0) } }

    // MARK: Model

    func testTitleCollapsesWhitespaceAndTruncatesByCharacter() {
        XCTAssertEqual(ClipPill.title("  hello \n\n\t world  "), "hello world")
        XCTAssertEqual(ClipPill.title("12345678901234567890"), "12345678901234567890", "20 Characters fit")
        XCTAssertEqual(ClipPill.title("123456789012345678901"), "1234567890123456789…")
        let chinese = "明天下午三点在国贸三期见记得带上合同和发票谢谢"
        XCTAssertGreaterThan(chinese.count, 20)
        XCTAssertEqual(ClipPill.title(chinese), String(chinese.prefix(19)) + "…")
        XCTAssertEqual(ClipPill.title(chinese).count, 20)
        let family = String(repeating: "👨‍👩‍👧‍👦", count: 21)
        XCTAssertEqual(ClipPill.title(family), String(repeating: "👨‍👩‍👧‍👦", count: 19) + "…", "Grapheme clusters count once")
        XCTAssertEqual(ClipPill.title("a\r\nb"), "a b")
        XCTAssertFalse(ClipPill.title("line one\nline two that is quite long").contains("\n"))
    }

    func testTypeClassificationOrder() {
        let expected: [(String, ClipPill.Kind)] = [
            ("https://github.com/mmmmmmarcus/vvhisper", .link), ("github.com/mmmmmmarcus/vvhisper", .link),
            ("www.apple.com", .link), ("  http://example.com/a?b=1  ", .link), ("https://example.com/mail@x.com", .link),
            ("marcus@vvhisper.app", .email), ("mailto:hi@example.co", .email),
            ("+86 138 0013 8000", .phone), ("13800138000", .phone), ("(415) 555-0123", .phone), ("tel:+14155550123", .phone),
            ("482913", .number), ("6222 0210 0112 3456", .number), ("2026-11-27", .number),
            ("Your verification code is 482913", .number), ("验证码：482913，5分钟内有效。", .number),
            ("明天下午三点在国贸三期见", .text), ("hello world", .text), ("3.14", .text), ("A1B2C3", .text),
            ("see https://example.com now", .text), ("", .text),
        ]
        for (text, kind) in expected { XCTAssertEqual(ClipPill.classify(text), kind, text) }
        XCTAssertEqual(ClipPill.Kind.allCases.map(\.symbol), ["link", "envelope", "phone", "number", "text.alignleft"])
        for kind in ClipPill.Kind.allCases { XCTAssertNotNil(UIImage(systemName: kind.symbol), kind.symbol) }
    }

    func testAccessibilityLabelsUseTypeWordAndFirstSeventyCharacters() {
        let long = "https://example.com/" + String(repeating: "a", count: 100)
        XCTAssertEqual(ClipPill(clip: long).accessibilityLabel, "Paste link: " + String(long.prefix(70)))
        XCTAssertEqual(ClipPill(clip: "a@b.co").accessibilityLabel, "Paste email: a@b.co")
        XCTAssertEqual(ClipPill(clip: "hi\nthere").accessibilityLabel, "Paste text: hi there")
        XCTAssertEqual(ClipPill(code: "482913").accessibilityLabel, "Paste number: 482913")
        XCTAssertEqual(ClipPill(code: nil).accessibilityLabel, "Paste code")
        XCTAssertEqual(ClipPill(code: nil).title, "Code")
        let clip = ClipPill(clip: " full\n original ")
        XCTAssertEqual(clip.text, " full\n original ", "Tap pastes the full original")
    }

    func testOrderingCodeFirstThenNewestClipsWithoutDuplicatingCodeSource() {
        let history = ["Your code: 482913", "newest", "b", "c", "d"]
        var pills = ClipPill.pills(history: history, code: "482913", codeAvailable: true, codeSource: "Your code: 482913")
        XCTAssertEqual(pills.map(\.title), ["482913", "newest", "b", "c", "d"])
        XCTAssertTrue(pills[0].isCode); XCTAssertFalse(pills[1...].contains { $0.isCode })
        pills = ClipPill.pills(history: history, code: nil, codeAvailable: false, codeSource: nil)
        XCTAssertEqual(pills.map(\.text), history)
        pills = ClipPill.pills(history: ["1", "2", "3", "4", "5", "6"], code: nil, codeAvailable: false, codeSource: nil)
        XCTAssertEqual(pills.map(\.text), ["1", "2", "3", "4", "5"], "At most five clips")
        XCTAssertTrue(ClipPill.pills(history: [], code: nil, codeAvailable: false, codeSource: nil).isEmpty)
    }

    func testConcealedCopiesAreNeverRecordedOrShown() {
        XCTAssertTrue(ConcealedPasteboard.isConcealed(["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]))
        XCTAssertTrue(ConcealedPasteboard.isConcealed(["org.nspasteboard.TransientType"]))
        XCTAssertFalse(ConcealedPasteboard.isConcealed(["public.utf8-plain-text"]))
        let board = TestCodeClipboard()
        let monitor = CopiedCodeMonitor(clipboard: board, defaults: nil, bootTime: { 100 })
        let history = ClipboardHistory(fileURL: nil)
        monitor.onObservedText = { history.record($0) }
        monitor.refresh()
        board.copy("hunter2-password", concealed: true); monitor.refresh()
        XCTAssertTrue(history.items.isEmpty)
        board.copy("visible"); monitor.refresh()
        XCTAssertEqual(history.items, ["visible"])
        // A concealed one-time code is still offered, without its digits.
        board.copy("Your code: 482913", concealed: true); monitor.refresh()
        XCTAssertEqual(history.items, ["visible"])
        XCTAssertTrue(monitor.isAvailable); XCTAssertNil(monitor.observedCode); XCTAssertNil(monitor.observedSource)
        let pills = ClipPill.pills(history: history.items, code: monitor.observedCode, codeAvailable: monitor.isAvailable, codeSource: monitor.observedSource)
        XCTAssertEqual(pills.map(\.title), ["Code", "visible"])
        XCTAssertFalse(pills.map(\.accessibilityLabel).joined().contains("482913"))
        board.copy("Your code: 271828"); monitor.refresh()
        XCTAssertEqual(monitor.observedCode, "271828"); XCTAssertEqual(monitor.observedSource, "Your code: 271828")
        monitor.consume(); XCTAssertNil(monitor.observedCode); XCTAssertNil(monitor.observedSource)
    }

    // MARK: Controller

    private func makeKeyboard(width: CGFloat = 402, language: KeyboardLanguage = .chinese) async -> (KeyboardViewController, TextViewProxy) {
        language.save(); KeyboardLayoutMode.full.save()
        await withCheckedContinuation { c in PinyinEngine.shared.perform(.clear) { _ in c.resume() } }
        let keyboard = KeyboardViewController()
        let proxy = TextViewProxy("", selection: NSRange(location: 0, length: 0))
        proxy.returnKeyType = .default
        keyboard.testingDocumentProxy = proxy
        keyboard.testingLandscape = false; keyboard.testingTablet = false
        keyboard.copiedCodes = CopiedCodeMonitor(clipboard: TestCodeClipboard(), defaults: nil, bootTime: { 100 })
        keyboard.loadViewIfNeeded()
        keyboard.view.frame = CGRect(x: 0, y: 0, width: width, height: KeyboardMetrics(width: width).contentHeight)
        keyboard.viewDidLayoutSubviews(); keyboard.view.layoutIfNeeded()
        await withCheckedContinuation { c in PinyinEngine.shared.perform(.prepare) { _ in c.resume() } }
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

    private func pillStrip(_ keyboard: KeyboardViewController) throws -> ClipPillStrip {
        try XCTUnwrap(descendants(keyboard.view).compactMap { $0 as? ClipPillStrip }.first)
    }

    private func openSymbols(_ keyboard: KeyboardViewController) async throws {
        let symbols = try XCTUnwrap(descendants(keyboard.view).compactMap { $0 as? KeyControl }.first { $0.value == "123" })
        XCTAssertTrue(symbols.accessibilityActivate())
        // Chinese taps wait for the Pinyin engine; let the deferred tap land.
        let strip = try pillStrip(keyboard), deadline = Date().addingTimeInterval(5)
        while strip.isHidden, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        keyboard.view.layoutIfNeeded()
    }

    /// Oldest first, so the strip reads url, text, email, phone, number.
    static let fixtureClips = ["6222 0210 0112 3456", "+86 138 0013 8000", "marcus@vvhisper.app",
                               "明天下午三点在国贸三期见，记得带上合同", "github.com/mmmmmmarcus/vvhisper"]

    private func addFixtures(_ keyboard: KeyboardViewController, code: Bool) {
        for clip in Self.fixtureClips { keyboard.clipboardHistory.record(clip) }
        if code {
            let board = TestCodeClipboard()
            let monitor = CopiedCodeMonitor(clipboard: board, defaults: nil, bootTime: { 100 })
            monitor.refresh(); board.copy("您的验证码是 482913，5 分钟内有效"); monitor.refresh()
            keyboard.copiedCodes = monitor
        }
        keyboard.refreshCopiedCodeIndicator(); keyboard.view.layoutIfNeeded()
    }

    func testRepeatedHeaderRefreshSkipsModelsAndGeometryButKeepsExpiryAndPermission() async throws {
        try await withSavedPreferences {
            let (keyboard, _) = await makeKeyboard()
            defer { keyboard.viewWillDisappear(false) }
            try await openSymbols(keyboard)
            let strip = try pillStrip(keyboard)
            for n in 0..<5 { keyboard.clipboardHistory.record(String(repeating: "a", count: 19_990) + String(n)) }
            var date = Date(timeIntervalSince1970: 1000)
            let board = TestCodeClipboard()
            keyboard.copiedCodes = CopiedCodeMonitor(clipboard: board, defaults: nil, now: { date }, bootTime: { 100 })
            keyboard.copiedCodes.refresh(); board.copy("Your code: 482913"); keyboard.copiedCodes.refresh()
            keyboard.testingUpdateHeader(); keyboard.view.layoutIfNeeded(); strip.layoutIfNeeded()
            let builds = keyboard.testingClipModelBuilds, layouts = keyboard.testingHeaderLayoutRequests
            let buttons = strip.clipButtons
            strip.scroll.contentOffset.x = 40
            for _ in 0..<100 { keyboard.testingUpdateHeader() }
            XCTAssertEqual(keyboard.testingClipModelBuilds, builds)
            XCTAssertEqual(keyboard.testingHeaderLayoutRequests, layouts)
            XCTAssertEqual(strip.clipButtons.map(ObjectIdentifier.init), buttons.map(ObjectIdentifier.init))
            XCTAssertEqual(strip.scroll.contentOffset.x, 40)
            date.addTimeInterval(121); keyboard.testingUpdateHeader()
            XCTAssertFalse(strip.clips.contains(where: \.isCode), "Expiry still invalidates the cache")
            XCTAssertEqual(keyboard.testingClipModelBuilds, builds + 1)
            keyboard.testingFullAccess = false; keyboard.testingUpdateHeader()
            XCTAssertTrue(strip.clips.isEmpty)
            keyboard.testingFullAccess = true; keyboard.testingUpdateHeader()
            XCTAssertEqual(strip.clips.count, 5)
            keyboard.clipboardHistory.clear(); keyboard.testingUpdateHeader()
            XCTAssertTrue(strip.clips.isEmpty, "Clearing history cannot leave cached pills")
        }
    }

    func testNativeScrollCancellationPolicyDoesNotActivatePills() {
        let strip = ClipPillStrip(frame: CGRect(x: 0, y: 0, width: 375, height: 44))
        strip.show([ClipPill(clip: "Synthetic clip")])
        var activations = 0
        strip.onSelect = { _ in activations += 1 }
        XCTAssertEqual(strip.scroll.decelerationRate, .normal)
        XCTAssertTrue(strip.scroll.canCancelContentTouches)
        for pill in strip.pills {
            XCTAssertTrue(strip.scroll.touchesShouldCancel(in: pill))
            pill.cancelTracking(with: nil)
        }
        XCTAssertEqual(activations, 0, "Cancellation, unlike touchUpInside, never inserts")
        strip.clipButtons[0].sendActions(for: .touchUpInside)
        XCTAssertEqual(activations, 1)
        // This checks native policy, not a synthesized drag or real-device inertia.
    }

    func testStripOrderGeometryAndColorsAtEveryWidth() async throws {
        try await withSavedPreferences {
            for width: CGFloat in [375, 402, 440, 466] {
                let (keyboard, _) = await makeKeyboard(width: width)
                defer { keyboard.viewWillDisappear(false) }
                let strip = try pillStrip(keyboard)
                XCTAssertTrue(strip.isHidden, "Letters keep the strip hidden")
                try await openSymbols(keyboard)
                XCTAssertFalse(strip.isHidden)
                addFixtures(keyboard, code: true)
                strip.layoutIfNeeded(); strip.pills.forEach { $0.layoutIfNeeded() }
                XCTAssertEqual(strip.bounds.height, 44, accuracy: 0.01, "\(width)")
                XCTAssertEqual(strip.frame.minX, 0); XCTAssertEqual(strip.bounds.width, width)
                let ids = strip.pills.map { $0.accessibilityIdentifier ?? "" }
                XCTAssertEqual(ids, ["keyboard.open-1password", "keyboard.open-messages", "keyboard.snippet", "keyboard.paste-code",
                                     "keyboard.clip.0", "keyboard.clip.1", "keyboard.clip.2", "keyboard.clip.3", "keyboard.clip.4",
                                     "keyboard.clipboard-history"])
                XCTAssertEqual(strip.clipButtons.compactMap { $0.clip?.kind }, [.number, .link, .text, .email, .phone, .number])
                XCTAssertEqual(strip.clipButtons.first?.titleView.text, "482913")
                XCTAssertEqual(strip.pills.first?.frame.minX ?? 0, 8, accuracy: 0.01)
                for (left, right) in zip(strip.pills, strip.pills.dropFirst()) {
                    XCTAssertEqual(right.frame.minX - left.frame.maxX, 6, accuracy: 0.01, "6pt spacing at \(width)")
                }
                for pill in strip.pills {
                    XCTAssertEqual(pill.frame.height, 44, accuracy: 0.01, "Full-height tap target")
                    XCTAssertEqual(pill.capsule.frame.height, 32); XCTAssertEqual(pill.capsule.frame.midY, 22, accuracy: 0.01)
                    XCTAssertEqual(pill.capsule.layer.cornerRadius, 16)
                    XCTAssertEqual(pill.capsule.layer.shadowOpacity, 0); XCTAssertEqual(pill.capsule.layer.borderWidth, 0)
                }
                for pill in [strip.onePassword, strip.messages, strip.history] { XCTAssertEqual(pill.frame.width, 44) }
                XCTAssertFalse(strip.subviews.contains { $0.bounds.width <= 1 && $0.bounds.height > 10 }, "No divider")
                // Clip pill internals: L11 / icon / 5 / label / R14.
                for pill in strip.clipButtons {
                    XCTAssertEqual(pill.iconView.frame.minX, 11, accuracy: 0.01)
                    XCTAssertEqual(pill.titleView.frame.minX - pill.iconView.frame.maxX, 5, accuracy: 0.01)
                    XCTAssertEqual(pill.bounds.width - pill.titleView.frame.maxX, 14, accuracy: 0.01)
                    XCTAssertEqual(pill.titleView.font, UIFont.systemFont(ofSize: 15, weight: .regular))
                    XCTAssertEqual(pill.titleView.numberOfLines, 1)
                    for traits in [UITraitCollection(userInterfaceStyle: .light), UITraitCollection(userInterfaceStyle: .dark)] {
                        XCTAssertEqual(pill.iconView.tintColor.resolvedColor(with: traits), UIColor.secondaryLabel.resolvedColor(with: traits))
                        XCTAssertEqual(pill.titleView.textColor.resolvedColor(with: traits), UIColor.label.resolvedColor(with: traits))
                    }
                }
                // Fills: light black 7% / 15%, dark white 14% / 26%; shortcuts brand colours.
                let light = UITraitCollection(userInterfaceStyle: .light), dark = UITraitCollection(userInterfaceStyle: .dark)
                let clip = try XCTUnwrap(strip.clipButtons.last)
                func rgba(_ color: UIColor?, _ traits: UITraitCollection) -> [CGFloat] {
                    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                    color?.resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
                    return [r, g, b, a].map { ($0 * 100).rounded() / 100 }
                }
                XCTAssertEqual(rgba(clip.capsule.backgroundColor, light), [0, 0, 0, 0.07])
                XCTAssertEqual(rgba(clip.capsule.backgroundColor, dark), [1, 1, 1, 0.14])
                clip.isHighlighted = true
                XCTAssertEqual(rgba(clip.capsule.backgroundColor, light), [0, 0, 0, 0.15])
                XCTAssertEqual(rgba(clip.capsule.backgroundColor, dark), [1, 1, 1, 0.26])
                clip.isHighlighted = false
                XCTAssertEqual(rgba(strip.onePassword.capsule.backgroundColor, dark), rgba(UIColor(red: 0x05 / 255.0, green: 0x72 / 255.0, blue: 0xEC / 255.0, alpha: 1), dark))
                XCTAssertEqual(rgba(strip.messages.capsule.backgroundColor, light), rgba(UIColor(red: 0x34 / 255.0, green: 0xC7 / 255.0, blue: 0x59 / 255.0, alpha: 1), light))
                XCTAssertEqual(rgba(strip.onePassword.iconView.tintColor, dark), [1, 1, 1, 1])
                XCTAssertEqual(rgba(strip.messages.iconView.tintColor, light), [1, 1, 1, 1])
                XCTAssertTrue(strip.onePassword.pressOverlay.isHidden)
                strip.onePassword.isHighlighted = true
                XCTAssertFalse(strip.onePassword.pressOverlay.isHidden)
                XCTAssertEqual(rgba(strip.onePassword.pressOverlay.backgroundColor, light), [0, 0, 0, 0.15])
                strip.onePassword.isHighlighted = false
                XCTAssertEqual(rgba(strip.history.iconView.tintColor, dark), rgba(.secondaryLabel, dark))
                // The strip itself paints nothing visible.
                var alpha: CGFloat = 0
                strip.backgroundColor?.resolvedColor(with: dark).getRed(nil, green: nil, blue: nil, alpha: &alpha)
                XCTAssertLessThan(alpha, 0.01)
                // Trailing 24pt alpha fade while the row overflows; none at the end.
                let scroll = strip.scroll
                XCTAssertGreaterThan(scroll.contentSize.width, scroll.bounds.width)
                let mask = try XCTUnwrap(scroll.layer.mask as? CAGradientLayer)
                XCTAssertEqual(try XCTUnwrap(mask.colors as? [CGColor]).map(\.alpha), [1, 1, 0])
                let stops = try XCTUnwrap(mask.locations).map { CGFloat($0.doubleValue) }
                XCTAssertEqual((1 - stops[1]) * mask.bounds.width, 24, accuracy: 0.01)
                scroll.contentOffset.x = scroll.contentSize.width - scroll.bounds.width; scroll.layoutIfNeeded()
                XCTAssertNil(scroll.layer.mask)
                XCTAssertFalse(scroll.showsHorizontalScrollIndicator)
                XCTAssertTrue(scroll.touchesShouldCancel(in: clip), "Scrolling cancels a pill tap")
            }
        }
    }

    func testTapPastesFullOriginalWithHapticAndKeepsOrder() async throws {
        try await withSavedPreferences {
            let (keyboard, proxy) = await makeKeyboard()
            defer { keyboard.viewWillDisappear(false) }
            try await openSymbols(keyboard)
            let original = "第一行\n\n第二行   with  spaces and a long tail that is truncated"
            keyboard.clipboardHistory.record(original); keyboard.clipboardHistory.record("newest")
            keyboard.refreshCopiedCodeIndicator(); keyboard.view.layoutIfNeeded()
            let strip = try pillStrip(keyboard)
            let pill = try XCTUnwrap(strip.clipButtons.last)
            XCTAssertEqual(pill.titleView.text, "第一行 第二行 with spaces…")
            XCTAssertEqual(pill.accessibilityLabel, "Paste text: 第一行 第二行 with spaces and a long tail that is truncated")
            let haptics = keyboard.testingTapFeedbackCount
            pill.sendActions(for: .touchUpInside)
            XCTAssertEqual(proxy.editor.text, original)
            XCTAssertEqual(keyboard.testingTapFeedbackCount, haptics + 1)
            XCTAssertEqual(keyboard.clipboardHistory.items, ["newest", original], "Order unchanged")
            XCTAssertEqual(strip.clipButtons.map { $0.clip?.text }, ["newest", original])
            try XCTUnwrap(strip.clipButtons.last).sendActions(for: .touchUpInside)
            XCTAssertEqual(proxy.editor.text, original + original, "Repeated taps hit the same pill")
            XCTAssertEqual(keyboard.clipboardHistory.items, ["newest", original])
            // Clearing history leaves only the shortcuts and the clock.
            keyboard.clipboardHistory.clear(); keyboard.refreshCopiedCodeIndicator()
            XCTAssertEqual(strip.pills.count, 4)
        }
    }

    func testEmptyStateAndNoFullAccessShowOnlyShortcutsAndClock() async throws {
        try await withSavedPreferences {
            for fullAccess in [true, false] {
                let (keyboard, _) = await makeKeyboard()
                defer { keyboard.viewWillDisappear(false) }
                keyboard.testingFullAccess = fullAccess
                try await openSymbols(keyboard)
                if !fullAccess { addFixtures(keyboard, code: true) }
                keyboard.refreshCopiedCodeIndicator(); keyboard.view.layoutIfNeeded()
                let strip = try pillStrip(keyboard)
                XCTAssertTrue(strip.clipButtons.isEmpty)
                XCTAssertEqual(strip.pills.map { $0.accessibilityIdentifier ?? "" },
                               ["keyboard.open-1password", "keyboard.open-messages", "keyboard.snippet", "keyboard.clipboard-history"])
                XCTAssertNil(strip.scroll.layer.mask, "Nothing to fade")
                XCTAssertFalse(descendants(strip).contains { ($0 as? UILabel).map { !$0.isHidden && !($0.text ?? "").isEmpty } ?? false },
                               "No hint text")
            }
        }
    }

    func testPinyinCandidatesAndMiniModeStillHideTheStrip() async throws {
        try await withSavedPreferences {
            var (keyboard, proxy) = await makeKeyboard()
            await withCheckedContinuation { c in PinyinEngine.shared.perform(.prepare) { _ in c.resume() } }
            var strip = try pillStrip(keyboard)
            for letter in "ni" {
                XCTAssertTrue(try XCTUnwrap(descendants(keyboard.view).compactMap { $0 as? KeyControl }.first { $0.value == String(letter) }).accessibilityActivate())
            }
            let deadline = Date().addingTimeInterval(5)
            while proxy.editor.text != "ni" || !descendants(keyboard.view).contains(where: { $0.accessibilityIdentifier == "candidate.0" }), Date() < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(descendants(keyboard.view).contains { $0.accessibilityIdentifier == "candidate.0" })
            XCTAssertTrue(strip.isHidden)
            keyboard.viewWillDisappear(false)
            (keyboard, proxy) = await makeKeyboard()
            defer { keyboard.viewWillDisappear(false) }
            strip = try self.pillStrip(keyboard)
            try await openSymbols(keyboard)
            XCTAssertFalse(strip.isHidden)
            keyboard.setMiniMode(true, animated: false); keyboard.view.layoutIfNeeded()
            XCTAssertTrue(strip.isHidden)
            keyboard.setMiniMode(false, animated: false)
        }
    }

    func testConcealedNativePasteIsNotRecorded() async throws {
        try await withSavedPreferences {
            let (keyboard, proxy) = await makeKeyboard(language: .english)
            defer { keyboard.viewWillDisappear(false) }
            let provider = NSItemProvider(object: "s3cret-Password" as NSString)
            provider.registerDataRepresentation(forTypeIdentifier: "org.nspasteboard.ConcealedType", visibility: .all) { completion in
                completion(Data(), nil); return nil
            }
            keyboard.paste(itemProviders: [provider])
            for _ in 0..<300 where proxy.editor.text != "s3cret-Password" { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(proxy.editor.text, "s3cret-Password")
            XCTAssertTrue(keyboard.clipboardHistory.items.isEmpty)
            keyboard.paste(itemProviders: [NSItemProvider(object: " plain" as NSString)])
            for _ in 0..<300 where proxy.editor.text != "s3cret-Password plain" { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(keyboard.clipboardHistory.items, [" plain"])
        }
    }

    // MARK: Evidence renders (offscreen drawHierarchy, same style as PhoneLayoutTests)

    private static let evidenceDirectory: URL = {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".airbuild/artifacts/phone-layout", isDirectory: true)
    }()

    private func render(name: String, width: CGFloat, style: UIUserInterfaceStyle, fixtures: Bool,
                        pressedScrolled: Bool = false) async throws {
        let (keyboard, _) = await makeKeyboard(width: width)
        defer { keyboard.viewWillDisappear(false) }
        let height = keyboard.view.bounds.height
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: height)
        window.overrideUserInterfaceStyle = style
        let backdrop = UIView(frame: window.bounds)
        // Neutral stand-in for the system keyboard glass (light #D1D3D9, dark #2B2B2E).
        backdrop.backgroundColor = style == .dark
            ? UIColor(red: 0x2B / 255.0, green: 0x2B / 255.0, blue: 0x2E / 255.0, alpha: 1)
            : UIColor(red: 0xD1 / 255.0, green: 0xD3 / 255.0, blue: 0xD9 / 255.0, alpha: 1)
        window.addSubview(backdrop)
        window.addSubview(keyboard.view)
        window.isHidden = false
        keyboard.view.frame = window.bounds
        keyboard.viewDidLayoutSubviews(); keyboard.view.layoutIfNeeded()
        try await openSymbols(keyboard)
        if fixtures { addFixtures(keyboard, code: true) } else { keyboard.refreshCopiedCodeIndicator() }
        keyboard.view.setNeedsLayout(); keyboard.view.layoutIfNeeded()
        let strip = try pillStrip(keyboard)
        XCTAssertFalse(strip.isHidden, name)
        if pressedScrolled {
            strip.scroll.contentOffset.x = 230; strip.scroll.layoutIfNeeded()
            strip.clipButtons.first { $0.clip?.kind == .text }?.isHighlighted = true
        }
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let png = try XCTUnwrap(image.pngData())
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = "clip-pills-\(name).png"; attachment.lifetime = .keepAlways
        add(attachment)
        do {
            try FileManager.default.createDirectory(at: Self.evidenceDirectory, withIntermediateDirectories: true)
            try png.write(to: Self.evidenceDirectory.appendingPathComponent("clip-pills-\(name).png"))
        } catch { print("clip-pills evidence not written to source tree: \(error)") }
        window.isHidden = true
        keyboard.view.removeFromSuperview()
    }

    func testRenderClipPillsEvidence() async throws {
        try await withSavedPreferences {
            for width: CGFloat in [375, 402, 440, 466] {
                try await render(name: "\(Int(width))-light", width: width, style: .light, fixtures: true)
                try await render(name: "\(Int(width))-dark", width: width, style: .dark, fixtures: true)
            }
            try await render(name: "empty-402-dark", width: 402, style: .dark, fixtures: false)
            try await render(name: "empty-402-light", width: 402, style: .light, fixtures: false)
            try await render(name: "402-light-scrolled-pressed", width: 402, style: .light, fixtures: true, pressedScrolled: true)
        }
    }
}
