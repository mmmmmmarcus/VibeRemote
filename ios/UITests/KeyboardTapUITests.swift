import XCTest

/// Sends coordinates through UIKit to the installed keyboard extension. These
/// tests deliberately do not call KeyControl.press or accessibilityActivate.
final class KeyboardTapUITests: XCTestCase {
    @MainActor func testHeldDeleteSweepsThroughMAndRestoresTyping() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.vvhisper.ios")
        app.launchArguments = ["--keyboard-test"]
        app.launch()
        let field = app.textViews["keyboard-test-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10)); field.tap()
        enableKeyboard(in: app)
        if app.descendants(matching: .any)["keyboard.key.dictate"].exists {
            app.descendants(matching: .any)["keyboard.key-surface"].pinch(withScale: 2.5, velocity: 2)
        }
        let language = app.descendants(matching: .any)["keyboard.key.language"]
        if language.label != "English" { language.tap() }
        app.buttons["keyboard-test.clear"].tap()
        // Long enough that held repeat alone cannot empty the fixture during the swipe.
        for letter in String(repeating: "abcdefgh", count: 3) { app.descendants(matching: .any)["keyboard.key.\(letter)"].tap() }
        XCTAssertFalse((field.value as? String ?? "").isEmpty)
        let delete = app.descendants(matching: .any)["keyboard.key.delete"]
        let m = app.descendants(matching: .any)["keyboard.key.m"]
        let origin = delete.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let broom = m.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: -2, dy: 0))
        origin.press(forDuration: 0.45, thenDragTo: broom)
        XCTAssertTrue(XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "value == ''"), evaluatedWith: field)], timeout: 4) == .completed)
        m.tap()
        XCTAssertTrue(XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "value ==[c] 'm'"), evaluatedWith: field)], timeout: 3) == .completed)
        delete.tap()
        XCTAssertTrue(XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "value == ''"), evaluatedWith: field)], timeout: 3) == .completed)
    }

    @MainActor func testCandidatePullExpandsWithoutSelectingAndChevronCollapses() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.vvhisper.ios")
        app.launchArguments = ["--keyboard-test"]
        app.launch()
        let field = app.textViews["keyboard-test-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10)); field.tap()
        enableKeyboard(in: app)
        if app.descendants(matching: .any)["keyboard.key.dictate"].exists {
            app.descendants(matching: .any)["keyboard.key-surface"].pinch(withScale: 2.5, velocity: 2)
        }
        let language = app.descendants(matching: .any)["keyboard.key.language"]
        if language.label == "English" { language.tap() }
        app.buttons["keyboard-test.clear"].tap()
        for letter in "shi" { app.descendants(matching: .any)["keyboard.key.\(letter)"].tap() }
        let first = app.buttons["candidate.0"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        let spelling = field.value as? String
        let expand = app.buttons["candidate.expand"]
        XCTAssertEqual(expand.label, "Show all candidates")
        let start = first.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 2, dy: 62)))
        XCTAssertTrue(XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "label == 'Collapse candidates'"), evaluatedWith: expand)], timeout: 3) == .completed)
        XCTAssertEqual(field.value as? String, spelling, "Pulling must not select a candidate or type")
        XCTAssertFalse(app.descendants(matching: .any)["keyboard.key.a"].isHittable)
        XCTAssertTrue(app.descendants(matching: .any)["keyboard.key.space"].isHittable)
        expand.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.9)).tap()
        XCTAssertTrue(XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "label == 'Show all candidates'"), evaluatedWith: expand)], timeout: 3) == .completed)
        XCTAssertTrue(app.descendants(matching: .any)["keyboard.key.a"].isHittable)
        XCTAssertEqual(field.value as? String, spelling)
        // Horizontal browsing remains a scroll, not an expansion or word commit.
        let strip = app.collectionViews["keyboard.candidates.list"]
        let right = strip.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
        right.press(forDuration: 0.05, thenDragTo: strip.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)))
        XCTAssertEqual(expand.label, "Show all candidates")
        XCTAssertEqual(field.value as? String, spelling)
        app.buttons["keyboard-test.clear"].tap()
    }

    @MainActor private func selectVvhisper(in app: XCUIApplication) -> Bool {
        for _ in 0..<5 {
            if app.descendants(matching: .any)["keyboard.key.a"].exists || app.descendants(matching: .any)["keyboard.key.dictate"].exists { return true }
            let next = app.buttons["Next keyboard"]
            guard next.waitForExistence(timeout: 2) else { return false }
            next.tap()
        }
        return app.descendants(matching: .any)["keyboard.key.a"].waitForExistence(timeout: 3)
    }

    @MainActor private func enableKeyboard(in app: XCUIApplication) {
        if selectVvhisper(in: app) { return }
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()
        let navigation = settings.cells["AddNewKeyboard"].exists ? [] : ["General", "Keyboard", "Keyboards"]
        for title in navigation {
            let cell = settings.cells.containing(.staticText, identifier: title).firstMatch
            if !cell.waitForExistence(timeout: 3) || !cell.isHittable { settings.swipeUp() }
            guard cell.waitForExistence(timeout: 3) else {
                print("KEYBOARD SETTINGS: \(settings.debugDescription)")
                XCTFail("Could not find simulator keyboard setting \(title)"); return
            }
            cell.tap()
        }
        let add = settings.cells["AddNewKeyboard"]
        XCTAssertTrue(add.waitForExistence(timeout: 3)); add.tap()
        let keyboard = settings.cells.matching(NSPredicate(format: "label ==[c] %@", "vvhisper")).firstMatch
        guard keyboard.waitForExistence(timeout: 3) else {
            print("KEYBOARD SETTINGS: \(settings.debugDescription)")
            XCTFail("vvhisper should appear in third-party keyboards"); return
        }
        keyboard.tap()
        let done = settings.buttons["Done"]
        if done.exists { done.tap() }
        app.activate()
        app.textViews["keyboard-test-field"].tap()
        XCTAssertTrue(selectVvhisper(in: app), "Select the installed vvhisper keyboard")
    }

    @MainActor func testEmojiRoundTripsKeepExtensionAndTypingAlive() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.vvhisper.ios")
        app.launchArguments = ["--keyboard-test"]; app.launch()
        let field = app.textViews["keyboard-test-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10)); field.tap()
        enableKeyboard(in: app)
        app.buttons["keyboard-test.clear"].tap()
        for _ in 0..<5 {
            let smile = app.buttons["keyboard.key.globe"]
            XCTAssertTrue(smile.waitForExistence(timeout: 3)); smile.tap()
            let close = app.buttons["emoji.close"]
            XCTAssertTrue(close.waitForExistence(timeout: 3)); close.tap()
            XCTAssertTrue(app.descendants(matching: .any)["keyboard.key.a"].waitForExistence(timeout: 3))
            XCTAssertEqual(field.value as? String, "")
        }
    }

    @MainActor func testGapTapsReachTheEditor() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.vvhisper.ios")
        app.launchArguments = ["--keyboard-test"]
        app.launch()
        let field = app.textViews["keyboard-test-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        let a = app.descendants(matching: .any)["keyboard.key.a"]
        if !a.waitForExistence(timeout: 2) { enableKeyboard(in: app) }
        let mini = app.descendants(matching: .any)["keyboard.key.dictate"]
        if mini.exists { app.descendants(matching: .any)["keyboard.key-surface"].pinch(withScale: 2.5, velocity: 2) }
        guard a.waitForExistence(timeout: 5) else {
            print("KEYBOARD TOUCH SETUP: \(app.debugDescription)")
            XCTFail("Enable vvhisper on this test simulator before running touch tests.")
            return
        }
        let language = app.descendants(matching: .any)["keyboard.key.language"]
        if language.label != "English" { language.tap() }
        app.buttons["keyboard-test.clear"].tap()
        let q = app.descendants(matching: .any)["keyboard.key.q"]
        let w = app.descendants(matching: .any)["keyboard.key.w"]
        let l = app.descendants(matching: .any)["keyboard.key.l"]
        let p = app.descendants(matching: .any)["keyboard.key.p"]
        let root = app.coordinate(withNormalizedOffset: .zero)
        var points: [(CGPoint, String)] = [
            (CGPoint(x: q.frame.midX, y: q.frame.midY), "q"),
            (CGPoint(x: q.frame.maxX + (w.frame.minX - q.frame.maxX) * 0.25, y: q.frame.midY), "q"),
            (CGPoint(x: q.frame.maxX + (w.frame.minX - q.frame.maxX) * 0.75, y: q.frame.midY), "w"),
            (CGPoint(x: q.frame.minX + 2, y: a.frame.midY), "a"),
            (CGPoint(x: p.frame.maxX - 2, y: l.frame.midY), "l"),
            (CGPoint(x: q.frame.minX + 2, y: a.frame.minY + 2), "a"),
            (CGPoint(x: p.frame.maxX - 2, y: l.frame.maxY - 2), "l")
        ]
        // Both sides of every horizontal letter gap, including the staggered
        // rows. These are physical coordinates, not accessibility activations.
        for row in ["qwertyuiop", "asdfghjkl", "zxcvbnm"] {
            let letters = row.map(String.init)
            for (left, right) in zip(letters, letters.dropFirst()) {
                let first = app.descendants(matching: .any)["keyboard.key.\(left)"].frame
                let second = app.descendants(matching: .any)["keyboard.key.\(right)"].frame
                let gap = second.minX - first.maxX
                points.append((CGPoint(x: first.maxX + gap * 0.25, y: first.midY), left))
                points.append((CGPoint(x: first.maxX + gap * 0.75, y: first.midY), right))
            }
        }
        // The gaps between rows also belong to keys on both sides.
        for (upper, lower) in [("q", "a"), ("p", "l"), ("s", "z"), ("k", "m")] {
            let first = app.descendants(matching: .any)["keyboard.key.\(upper)"].frame
            let second = app.descendants(matching: .any)["keyboard.key.\(lower)"].frame
            let x = (max(first.minX, second.minX) + min(first.maxX, second.maxX)) / 2
            let gap = second.minY - first.maxY
            points.append((CGPoint(x: x, y: first.maxY + gap * 0.25), upper))
            points.append((CGPoint(x: x, y: first.maxY + gap * 0.75), lower))
        }
        var expected = ""
        for (point, value) in points {
            root.withOffset(CGVector(dx: point.x, dy: point.y)).tap()
            expected += value
            let match = NSPredicate(format: "value ==[c] %@", expected)
            XCTAssertTrue(XCTWaiter.wait(for: [expectation(for: match, evaluatedWith: field)], timeout: 3) == .completed,
                          "Tap at \(point) should append \(value); editor: \(field.value ?? "nil")")
        }
        // Small thumb settling movement must not fall into a cancelled-tap /
        // unrecognized-swipe dead band. Exercise the remote keyboard boundary.
        for (value, dx): (String, CGFloat) in [("q", 18), ("a", 20), ("p", -18), ("l", -20)] {
            let key = app.descendants(matching: .any)["keyboard.key.\(value)"]
            let start = CGPoint(x: dx > 0 ? q.frame.minX + 2 : p.frame.maxX - 2, y: key.frame.midY)
            root.withOffset(CGVector(dx: start.x, dy: start.y)).press(forDuration: 0.05,
                thenDragTo: root.withOffset(CGVector(dx: start.x + dx, dy: start.y)))
            expected += value
            let match = NSPredicate(format: "value ==[c] %@", expected)
            XCTAssertTrue(XCTWaiter.wait(for: [expectation(for: match, evaluatedWith: field)], timeout: 3) == .completed,
                          "Edge drift on \(value) must remain a tap")
        }
    }

    @MainActor func testLanguageHoldOpensNativeKeyboardPicker() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.vvhisper.ios")
        app.launchArguments = ["--keyboard-test"]; app.launch()
        let field = app.textViews["keyboard-test-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10)); field.tap(); enableKeyboard(in: app)
        if app.descendants(matching: .any)["keyboard.key.dictate"].exists {
            app.descendants(matching: .any)["keyboard.key-surface"].pinch(withScale: 2.5, velocity: 2)
        }
        let language = app.descendants(matching: .any)["keyboard.key.language"]
        XCTAssertTrue(language.waitForExistence(timeout: 5))
        let original = language.label
        language.tap()
        XCTAssertNotEqual(language.label, original, "Tap changes vvhisper's language without switching keyboards")
        language.tap()
        XCTAssertEqual(language.label, original, "A second short tap must remain inside vvhisper")
        let tappedLanguage = language.label
        language.press(forDuration: 1.2)
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "Language hold native keyboard picker"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertTrue(app.staticTexts["English (US)"].exists || app.buttons["English (US)"].exists || app.buttons["Keyboard Settings…"].exists, "Holding Language should expose Apple's enabled-keyboard list")
        XCTAssertEqual(language.label, tappedLanguage, "Hold must consume the Chinese/English tap")
        app.cells["English (US)"].tap()
        XCTAssertTrue(XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: language)], timeout: 3) == .completed)
        XCTAssertTrue(app.keys["A"].exists || app.keys["a"].exists, "Selecting English activates Apple's keyboard")
    }

    @MainActor func testSymbolShortcutsAndReturnHoldThroughInstalledExtension() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.vvhisper.ios")
        app.launchArguments = ["--keyboard-test"]; app.launch()
        let field = app.textViews["keyboard-test-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10)); field.tap(); enableKeyboard(in: app)
        if app.descendants(matching: .any)["keyboard.key.dictate"].exists {
            app.descendants(matching: .any)["keyboard.key-surface"].pinch(withScale: 2.5, velocity: 2)
        }
        let language = app.descendants(matching: .any)["keyboard.key.language"]
        XCTAssertTrue(language.waitForExistence(timeout: 5))
        if language.label == "English" { language.tap() }
        XCTAssertFalse(app.descendants(matching: .any)["keyboard.key.。"].exists)
        XCTAssertFalse(app.buttons["keyboard.open-1password"].isHittable)
        app.descendants(matching: .any)["keyboard.key.123"].tap()
        for id in ["keyboard.clipboard-history", "keyboard.open-1password", "keyboard.open-messages"] {
            XCTAssertTrue(app.buttons[id].isHittable, id)
        }
        for id in ["keyboard.shortcut-pill", "keyboard.paste", "keyboard.open-phone"] { XCTAssertFalse(app.buttons[id].exists) }
        XCTAssertTrue(app.descendants(matching: .any)["keyboard.key.。"].exists)
        app.descendants(matching: .any)["keyboard.key.ABC"].tap()
        app.buttons["keyboard-test.clear"].tap()
        app.descendants(matching: .any)["keyboard.key.return"].press(forDuration: 0.7)
        XCTAssertEqual(field.value as? String, "\u{2028}")
        app.descendants(matching: .any)["keyboard.key.globe"].tap()
        XCTAssertTrue(app.buttons["emoji.close"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["emoji.system-keyboard"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "Emoji back pill and bottom fade"; attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["emoji.close"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["keyboard.key.a"].exists)
    }

    @MainActor func testPinchSwitchesModesWithoutTypingAndRemembersMini() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.vvhisper.ios")
        app.launchArguments = ["--keyboard-test"]
        app.launch()
        let field = app.textViews["keyboard-test-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10)); field.tap()
        enableKeyboard(in: app)
        let a = app.descendants(matching: .any)["keyboard.key.a"]
        let dictate = app.descendants(matching: .any)["keyboard.key.dictate"]
        if dictate.exists { app.descendants(matching: .any)["keyboard.key-surface"].pinch(withScale: 2.5, velocity: 2) }
        XCTAssertTrue(a.waitForExistence(timeout: 5))
        app.buttons["keyboard-test.clear"].tap()

        let surface = app.descendants(matching: .any)["keyboard.key-surface"]
        XCTAssertTrue(surface.exists)
        surface.pinch(withScale: 0.5, velocity: -2)
        XCTAssertTrue(dictate.waitForExistence(timeout: 5), "Pinching inward should enter mini mode")
        XCTAssertFalse(a.exists)
        XCTAssertEqual(field.value as? String, "", "Pinching must not type or begin voice")

        app.terminate(); app.launch()
        XCTAssertTrue(field.waitForExistence(timeout: 10)); field.tap()
        XCTAssertTrue(dictate.waitForExistence(timeout: 5), "Mini mode must survive reopening the keyboard")
        surface.pinch(withScale: 2.5, velocity: 2)
        XCTAssertTrue(a.waitForExistence(timeout: 5), "Pinching outward should restore the full keyboard")
        XCTAssertFalse(dictate.exists)
        XCTAssertEqual(field.value as? String, "")
        // Ensure the completed pinch no longer consumes ordinary key taps.
        a.tap()
        XCTAssertTrue(XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "value ==[c] 'a'"), evaluatedWith: field)], timeout: 3) == .completed)
    }
}
