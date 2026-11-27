import XCTest
import UIKit
@testable import vvhisper

@MainActor final class SnippetKeyboardTests: XCTestCase {
    private func descendants(_ view: UIView) -> [UIView] { view.subviews.flatMap { [$0] + descendants($0) } }
    private func wait(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), file: file, line: line)
    }
    private func withKeyboard(width: CGFloat = 402, coalesced: Bool = false,
                              _ body: (KeyboardViewController, TextViewProxy, SnippetStore, Snippet) async throws -> Void) async throws {
        let oldLanguage = UserDefaults.standard.object(forKey: KeyboardLanguage.preferenceKey)
        let oldMode = UserDefaults.standard.object(forKey: KeyboardLayoutMode.preferenceKey)
        KeyboardLanguage.chinese.save(); KeyboardLayoutMode.full.save()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = SnippetStore(directory: directory)
        let record = try store.save(abbreviation: "gmail", content: "hello@example.com\n第二行 👨‍👩‍👧‍👦  ")
        _ = try store.save(abbreviation: "reply", content: "谢谢你的消息，我会尽快回复。")
        let keyboard = KeyboardViewController(), proxy = TextViewProxy("", selection: NSRange(location: 0, length: 0))
        proxy.coalescesTurnOutput = coalesced; proxy.excludesMarkedContext = coalesced
        keyboard.testingDocumentProxy = proxy; keyboard.testingLandscape = false; keyboard.testingTablet = false
        keyboard.snippetStore = store
        await withCheckedContinuation { c in PinyinEngine.shared.perform(.clear) { _ in c.resume() } }
        keyboard.loadViewIfNeeded()
        keyboard.view.frame = CGRect(x: 0, y: 0, width: width, height: KeyboardMetrics(width: width).contentHeight)
        keyboard.viewDidLayoutSubviews(); keyboard.view.layoutIfNeeded()
        await withCheckedContinuation { c in PinyinEngine.shared.perform(.prepare) { _ in c.resume() } }
        defer {
            keyboard.viewWillDisappear(false)
            try? FileManager.default.removeItem(at: directory)
            UserDefaults.standard.set(oldLanguage, forKey: KeyboardLanguage.preferenceKey)
            UserDefaults.standard.set(oldMode, forKey: KeyboardLayoutMode.preferenceKey)
        }
        try await body(keyboard, proxy, store, record)
    }
    private func tap(_ value: String, _ keyboard: KeyboardViewController) throws {
        let key = try XCTUnwrap(descendants(keyboard.view).compactMap { $0 as? KeyControl }.first { $0.value == value && !$0.isHidden }, value)
        XCTAssertTrue(key.accessibilityActivate()); keyboard.view.layoutIfNeeded()
    }
    private func typePrefix(_ keyboard: KeyboardViewController, suffix: String = "gmail") throws {
        for _ in 0..<2 { try tap("123", keyboard); try tap("@", keyboard) }
        for character in suffix { try tap(String(character), keyboard) }
    }
    func testRawPrefixBypassesRealRimeWithoutAutomaticExpansionAndExplicitTapWorks() async throws {
        for coalesced in [false, true] {
            try await withKeyboard(coalesced: coalesced) { keyboard, proxy, _, record in
                try typePrefix(keyboard)
                try await wait { keyboard.snippetStrip.records.first?.id == record.id }
                XCTAssertEqual(proxy.editor.text, "@@gmail"); XCTAssertNil(proxy.editor.markedTextRange)
                XCTAssertEqual(proxy.writes, 0, "Raw segment never goes through Rime marked text")
                XCTAssertFalse(keyboard.snippetStrip.isHidden)
                keyboard.selectSnippet(record)
                try await wait { proxy.editor.text == record.content }
                XCTAssertEqual(proxy.backspaces, 7); XCTAssertTrue(keyboard.snippetStrip.isHidden)
                XCTAssertTrue(keyboard.clipboardHistory.items.isEmpty)
                XCTAssertTrue(keyboard.dictationRecents.items.isEmpty)
            }
        }
    }
    func testManualInsertionPreservesPrefixFullContentAndStripAndDebounces() async throws {
        try await withKeyboard { keyboard, proxy, _, record in
            try typePrefix(keyboard)
            try await wait { proxy.editor.text == "@@gmail" }
            keyboard.openSnippets(); try await wait { keyboard.snippetStrip.records.count == 2 }
            keyboard.selectSnippet(record); keyboard.selectSnippet(record)
            try await wait { proxy.editor.text == "@@gmail" + record.content }
            XCTAssertEqual(proxy.backspaces, 0); XCTAssertTrue(keyboard.snippetsOpen)
            XCTAssertFalse(keyboard.snippetStrip.isHidden); XCTAssertTrue(keyboard.clipboardHistory.items.isEmpty)
        }
    }
    func testNoMatchForLongerTokenOrBoundaryAndNormalPinyinStillWorks() async throws {
        try await withKeyboard { keyboard, proxy, _, _ in
            try typePrefix(keyboard, suffix: "gmailx")
            try await wait { proxy.editor.text == "@@gmailx" }
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertTrue(keyboard.snippetStrip.isHidden); XCTAssertNil(proxy.editor.markedTextRange)
            try tap("space", keyboard)
            for character in "wozhidaole" { try tap(String(character), keyboard) }
            try await wait { self.descendants(keyboard.view).contains { $0.accessibilityIdentifier == "candidate.0" && $0.accessibilityLabel == "我知道了" } }
            XCTAssertNotNil(proxy.editor.markedTextRange)
            try tap("space", keyboard)
            try await wait { proxy.editor.text.hasSuffix("我知道了") }
        }
    }
    func testCancelSuppressesSameMatchButContinuedInputStaysLiteral() async throws {
        try await withKeyboard { keyboard, proxy, _, record in
            try typePrefix(keyboard)
            try await wait { keyboard.snippetStrip.records.first?.id == record.id }
            keyboard.closeSnippets(); try await Task.sleep(for: .milliseconds(100))
            XCTAssertTrue(keyboard.snippetStrip.isHidden); XCTAssertEqual(proxy.editor.text, "@@gmail")
            try tap("x", keyboard); XCTAssertEqual(proxy.editor.text, "@@gmailx"); XCTAssertNil(proxy.editor.markedTextRange)
            try tap("delete", keyboard)
            try await wait { !keyboard.snippetStrip.isHidden }
            XCTAssertEqual(proxy.editor.text, "@@gmail")
        }
    }
    func testRevisionAndDeletedRecordInvalidationNeverDeletePrefix() async throws {
        for deleted in [false, true] {
            try await withKeyboard { keyboard, proxy, store, record in
                try typePrefix(keyboard); try await wait { keyboard.snippetStrip.records.first?.id == record.id }
                if deleted { try store.delete(record) }
                else { try store.save(abbreviation: "gmail", content: "changed", replacing: record) }
                keyboard.selectSnippet(record)
                try await wait { keyboard.snippetStrip.state == .notice(SnippetError.stale.message) }
                XCTAssertEqual(proxy.editor.text, "@@gmail"); XCTAssertEqual(proxy.backspaces, 0)
            }
        }
    }
    func testSelectionCursorContextSessionCompositionAndPermissionInvalidateWithoutWrites() async throws {
        for invalidation in 0..<7 {
            try await withKeyboard { keyboard, proxy, _, record in
                try typePrefix(keyboard); try await wait { keyboard.snippetStrip.records.first?.id == record.id }
                switch invalidation {
                case 0: proxy.editor.selectedRange = NSRange(location: 0, length: 2)
                case 1: proxy.editor.selectedRange = NSRange(location: 1, length: 0)
                case 2: proxy.hidesContext = true
                case 3: proxy.documentIdentifier = UUID()
                case 4: keyboard.testingFullAccess = false
                case 5:
                    keyboard.selectionWillChange(nil); keyboard.selectionDidChange(nil) // Even away-and-back context.
                default:
                    proxy.editor.setMarkedText("x", selectedRange: NSRange(location: 1, length: 0))
                    keyboard.textWillChange(proxy.editor); keyboard.textDidChange(proxy.editor)
                }
                let text = proxy.editor.text
                keyboard.selectSnippet(record)
                try await Task.sleep(for: .milliseconds(100))
                XCTAssertEqual(proxy.backspaces, 0); XCTAssertEqual(proxy.editor.text, text)
            }
        }
    }
    func testStatePriorityFreshReadsAndLifecycleClearsPreviews() async throws {
        try await withKeyboard { keyboard, _, store, record in
            keyboard.testingFullAccess = false; keyboard.openSnippets()
            XCTAssertEqual(keyboard.snippetStrip.state, .permission)
            keyboard.snippetStrip.info.sendActions(for: .touchUpInside)
            keyboard.textDidChange(nil)
            XCTAssertEqual(keyboard.snippetStrip.state, .information(SnippetCopy.permissionDetail))
            keyboard.testingFullAccess = true; keyboard.openSnippets()
            XCTAssertEqual(keyboard.snippetStrip.state, .loading)
            try await wait { keyboard.snippetStrip.records.count == 2 }
            keyboard.snippetStore = SnippetStore(directory: nil); keyboard.openSnippets()
            try await wait { keyboard.snippetStrip.state == .failure }
            XCTAssertTrue(keyboard.snippetStrip.records.isEmpty)
            keyboard.snippetStore = store
            for item in try store.load() { try store.delete(item) }
            keyboard.openSnippets(); try await wait { keyboard.snippetStrip.state == .empty }
            _ = try store.save(abbreviation: record.abbreviation, content: record.content)
            keyboard.openSnippets(); try await wait { keyboard.snippetStrip.records.count == 1 }
            keyboard.clearSnippetSession()
            XCTAssertTrue(keyboard.snippetStrip.records.isEmpty); XCTAssertFalse(keyboard.snippetsOpen); XCTAssertTrue(keyboard.snippetStrip.isHidden)
        }
    }
    func testManualAsyncTapRejectsAwayAndBackSelectionRevision() async throws {
        try await withKeyboard { keyboard, proxy, _, record in
            keyboard.openSnippets(); try await wait { keyboard.snippetStrip.records.count == 2 }
            keyboard.selectSnippet(record)
            keyboard.selectionWillChange(nil); keyboard.selectionDidChange(nil)
            try await wait { keyboard.snippetStrip.state == .notice(SnippetCopy.insertionFailure) }
            XCTAssertEqual(proxy.editor.text, ""); XCTAssertEqual(proxy.backspaces, 0)
        }
    }
    func testHostSwitchClearsManualPreviewsWithoutInserting() async throws {
        try await withKeyboard { keyboard, proxy, _, _ in
            keyboard.openSnippets(); try await wait { keyboard.snippetStrip.records.count == 2 }
            proxy.documentIdentifier = UUID(); keyboard.textDidChange(nil)
            XCTAssertTrue(keyboard.snippetStrip.records.isEmpty); XCTAssertFalse(keyboard.snippetsOpen)
            XCTAssertTrue(keyboard.snippetStrip.isHidden); XCTAssertEqual(proxy.editor.text, "")
        }
    }
    func testWillChangeBarrierStopsExpansionBeforeStaleProxyCanDeleteAtMovedCursor() async throws {
        for selection in [true, false] {
            try await withKeyboard { keyboard, proxy, _, record in
                proxy.editor.text = "lead "; proxy.editor.selectedRange = NSRange(location: 5, length: 0)
                try typePrefix(keyboard); try await wait { keyboard.snippetStrip.records.first?.id == record.id }
                proxy.onDelete = {
                    guard proxy.backspaces == 1 else { return }
                    // The first delete is applied and visible, but the next host
                    // mutation is announced before its proxy context catches up.
                    proxy.contextOverride = (proxy.documentContextBeforeInput, proxy.documentContextAfterInput)
                    if selection { keyboard.selectionWillChange(nil) }
                    else { keyboard.textWillChange(nil) }
                    proxy.editor.selectedRange = NSRange(location: 2, length: 0)
                    // Deliberately withhold didChange until expansion stops.
                }
                defer { proxy.onDelete = nil; proxy.contextOverride = nil }
                keyboard.selectSnippet(record)
                try await wait { !keyboard.testingSnippetBusy }
                XCTAssertEqual(proxy.backspaces, 1, "An unresolved will-change must prevent the next delete")
                XCTAssertEqual(proxy.editor.text, "lead @@gmai", "Unrelated host prefix must survive")
                XCTAssertEqual(keyboard.snippetStrip.state, .notice(SnippetCopy.unsafe))
                proxy.contextOverride = nil
                if selection { keyboard.selectionDidChange(nil) } else { keyboard.textDidChange(nil) }
                XCTAssertEqual(proxy.backspaces, 1)
            }
        }
    }
    func testCancelledTapReadReleasesBusyAndOldCompletionCannotUnlockNewTap() async throws {
        for cursorChange in [false, true] {
            try await withKeyboard { keyboard, proxy, store, record in
                keyboard.openSnippets(); try await wait { keyboard.snippetStrip.records.count == 2 }
                let records = try store.load(), gate = SnippetReadGate()
                keyboard.testingSnippetRead = { await gate.load() }
                defer { gate.finishAll(records); keyboard.testingSnippetRead = nil }
                keyboard.selectSnippet(record); try await wait { gate.calls == 1 }
                XCTAssertTrue(keyboard.testingSnippetBusy)
                if cursorChange {
                    keyboard.selectionWillChange(nil); keyboard.selectionDidChange(nil)
                } else {
                    try tap("123", keyboard); try tap("@", keyboard)
                }
                XCTAssertFalse(keyboard.testingSnippetBusy)
                keyboard.selectSnippet(record); try await wait { gate.calls == 2 }
                gate.finish(1, records)
                try await Task.sleep(for: .milliseconds(30))
                XCTAssertTrue(keyboard.testingSnippetBusy, "Old defer must not unlock the newer operation")
                keyboard.selectSnippet(record); XCTAssertEqual(gate.calls, 2)
                gate.finish(2, records)
                try await wait { !keyboard.testingSnippetBusy }
                XCTAssertEqual(proxy.editor.text, (cursorChange ? "" : "@") + record.content)
                XCTAssertEqual(proxy.backspaces, 0)
            }
        }
    }
    func testSelectionRoundTripBeforePublicationInvalidatesScheduledAndPendingReads() async throws {
        for duringRead in [false, true] {
            try await withKeyboard { keyboard, proxy, store, record in
                let records = try store.load(), gate = SnippetReadGate()
                keyboard.testingSnippetRead = { await gate.load() }
                defer { gate.finishAll(records); keyboard.testingSnippetRead = nil }
                try typePrefix(keyboard)
                if duringRead { try await wait { gate.calls == 1 } }
                keyboard.selectionWillChange(nil); proxy.editor.selectedRange = NSRange(location: 0, length: 0)
                keyboard.selectionDidChange(nil)
                keyboard.selectionWillChange(nil); proxy.editor.selectedRange = NSRange(location: 7, length: 0)
                keyboard.selectionDidChange(nil)
                gate.finishAll(records)
                try await Task.sleep(for: .milliseconds(200))
                XCTAssertEqual(gate.calls, duringRead ? 1 : 0)
                XCTAssertTrue(keyboard.snippetStrip.isHidden); XCTAssertTrue(keyboard.snippetStrip.records.isEmpty)
                keyboard.selectSnippet(record)
                XCTAssertEqual(proxy.editor.text, "@@gmail"); XCTAssertEqual(proxy.backspaces, 0)
                keyboard.testingSnippetRead = nil
                try typePrefix(keyboard)
                try await wait { keyboard.snippetStrip.records.first?.id == record.id }
                XCTAssertEqual(proxy.editor.text, "@@gmail@@gmail", "New owned input may establish a fresh candidate")
            }
        }
    }
    func testLateOwnedRawAcknowledgmentRetriesWithoutRevivingInvalidSessions() async throws {
        // 0: no callback; 1: bare owned text acknowledgment; others invalidate.
        for invalidation in 0..<6 {
            try await withKeyboard { keyboard, proxy, _, record in
                proxy.defersTextEdits = true
                try typePrefix(keyboard)
                try await Task.sleep(for: .milliseconds(170)) // Beyond the original 80ms debounce.
                XCTAssertTrue(keyboard.snippetStrip.records.isEmpty)
                switch invalidation {
                case 2: keyboard.selectionWillChange(nil); keyboard.selectionDidChange(nil)
                case 3: keyboard.clearSnippetSession()
                case 4: keyboard.testingFullAccess = false; keyboard.textDidChange(nil)
                case 5: keyboard.closeSnippets()
                default: break
                }
                proxy.defersTextEdits = false; proxy.flushTextEdits()
                if invalidation == 1 { keyboard.textDidChange(nil) }
                if invalidation < 2 { try await wait { keyboard.snippetStrip.records.first?.id == record.id } }
                else {
                    try await Task.sleep(for: .milliseconds(150))
                    XCTAssertTrue(keyboard.snippetStrip.records.isEmpty)
                }
                XCTAssertEqual(proxy.editor.text, "@@gmail"); XCTAssertEqual(proxy.backspaces, 0)
                XCTAssertNil(proxy.editor.markedTextRange)
            }
        }
    }
    func testStripSwitchPreservesEveryKeyFrameAndVirtualizesManyPills() async throws {
        for width: CGFloat in [375, 402, 440, 466] {
            try await withKeyboard(width: width) { keyboard, _, _, record in
                try tap("123", keyboard)
                @MainActor func geometry() -> [String: CGRect] {
                    Dictionary(uniqueKeysWithValues: self.descendants(keyboard.view).filter { $0 is KeyControl || $0 is KeyboardSwitcherButton }.enumerated().map { index, view in
                        ("\(index)-" + (view.accessibilityIdentifier ?? ""), view.convert(view.bounds, to: keyboard.view))
                    })
                }
                let frames = geometry(), height = keyboard.view.bounds.height
                keyboard.openSnippets(); try await wait { keyboard.snippetStrip.records.count == 2 }
                keyboard.view.layoutIfNeeded()
                XCTAssertEqual(geometry(), frames); XCTAssertEqual(keyboard.view.bounds.height, height)
                let records = (0..<10_000).map { Snippet(id: UUID(), revision: UUID(), abbreviation: "n\($0)", content: record.content) }
                keyboard.snippetStrip.show(.data(records)); keyboard.snippetStrip.layoutIfNeeded()
                XCTAssertLessThan(keyboard.snippetStrip.collection.visibleCells.count, 20)
                let back = keyboard.snippetStrip.back.frame
                keyboard.snippetStrip.collection.contentOffset.x = 1000; keyboard.snippetStrip.layoutIfNeeded()
                XCTAssertEqual(keyboard.snippetStrip.back.frame, back)
                XCTAssertFalse(keyboard.snippetStrip.back.isDescendant(of: keyboard.snippetStrip.collection))
                for cell in keyboard.snippetStrip.collection.visibleCells {
                    XCTAssertFalse((cell.accessibilityLabel ?? "").contains("hello@example.com")); XCTAssertNil(cell.accessibilityValue)
                }
                let oldCells = keyboard.snippetStrip.collection.visibleCells
                keyboard.closeSnippets(); keyboard.view.layoutIfNeeded(); XCTAssertEqual(geometry(), frames)
                for cell in oldCells {
                    XCTAssertNil(cell.accessibilityLabel)
                    XCTAssertTrue(self.descendants(cell).compactMap { $0 as? UILabel }.allSatisfy { $0.attributedText == nil })
                    XCTAssertFalse(cell.accessibilityActivate())
                }
            }
        }
    }

    private func evidence(_ window: UIWindow, name: String) throws {
        window.layoutIfNeeded()
        let png = try XCTUnwrap(UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }.pngData())
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".airbuild/artifacts/phone-layout")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent(name + ".png"))
    }
    func testOffscreenKeyboardAndAppEvidence() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for width: CGFloat in [375, 402, 440, 466] {
            for style in [UIUserInterfaceStyle.light, .dark] {
                let theme = style == .light ? "light" : "dark", name = "snippets-\(Int(width))-\(theme)"
                try await withKeyboard(width: width) { keyboard, proxy, store, record in
                    let window = UIWindow(windowScene: scene); window.overrideUserInterfaceStyle = style
                    window.frame = keyboard.view.bounds
                    let backdrop = UIView(frame: window.bounds)
                    backdrop.backgroundColor = style == .light ? UIColor(white: 0.83, alpha: 1) : UIColor(white: 0.17, alpha: 1)
                    window.addSubview(backdrop); window.addSubview(keyboard.view); window.isHidden = false
                    defer { window.isHidden = true; keyboard.view.removeFromSuperview() }
                    keyboard.view.frame = window.bounds; keyboard.viewDidLayoutSubviews(); keyboard.view.layoutIfNeeded()
                    try tap("123", keyboard); try evidence(window, name: name + "-default")
                    keyboard.openSnippets(); try await wait { keyboard.snippetStrip.records.count == 2 }
                    keyboard.view.layoutIfNeeded(); try evidence(window, name: name + "-manual")
                    let capsule = try XCTUnwrap(keyboard.snippetStrip.collection.visibleCells.first?.contentView.subviews.first)
                    let expectedColor: UIColor = style == .dark ? .systemGray4 : .systemGray5
                    XCTAssertEqual(capsule.backgroundColor?.resolvedColor(with: window.traitCollection), expectedColor.resolvedColor(with: window.traitCollection))
                    keyboard.snippetStrip.show(.failure); try evidence(window, name: name + "-error")
                    if width == 402 {
                        for (state, suffix): (SnippetStripState, String) in [(.permission, "permission"), (.empty, "empty"), (.information(SnippetCopy.permissionDetail), "info")] {
                            keyboard.snippetStrip.show(state); try evidence(window, name: name + "-" + suffix)
                        }
                    }
                    keyboard.closeSnippets(); try tap("ABC", keyboard); try typePrefix(keyboard)
                    try await wait { keyboard.snippetStrip.records.first?.id == record.id }
                    keyboard.view.layoutIfNeeded(); try evidence(window, name: name + "-match")
                    keyboard.selectSnippet(record); try await wait { proxy.editor.text == record.content }
                    if width == 402 { try evidence(window, name: name + "-expanded") }
                    keyboard.view.removeFromSuperview()
                    window.frame = CGRect(x: 0, y: 0, width: width, height: 844)
                    let list = SnippetListViewController(store: store)
                    let navigation = UINavigationController(rootViewController: list); navigation.navigationBar.prefersLargeTitles = true
                    window.rootViewController = navigation
                    try await wait { list.records.count == 2 }
                    try evidence(window, name: name + "-app-list")
                    let editor = SnippetEditorViewController(store: store, original: record)
                    navigation.setViewControllers([editor], animated: false)
                    try evidence(window, name: name + "-app-edit")
                    if width == 402 {
                        editor.abbreviation.text = "@@invalid"; editor.save()
                        try await wait { self.descendants(editor.view).contains { ($0 as? UILabel)?.text == SnippetError.callMarker.message } }
                        try evidence(window, name: name + "-app-validation")
                        let unavailable = SnippetEditorViewController(store: SnippetStore(directory: nil), original: record)
                        navigation.setViewControllers([unavailable], animated: false); unavailable.loadViewIfNeeded(); unavailable.save()
                        try await wait { self.descendants(unavailable.view).contains { ($0 as? UILabel)?.text == "未能保存，请重试。" } }
                        try evidence(window, name: name + "-app-save-failure")
                        let delete = try XCTUnwrap(self.descendants(unavailable.view).compactMap { $0 as? UIButton }.first { $0.title(for: .normal) == "删除 Snippet" })
                        delete.sendActions(for: .touchUpInside)
                        try await Task.sleep(for: .milliseconds(400))
                        try evidence(window, name: name + "-app-delete-confirmation")
                    }
                }
            }
        }
    }
}

/// Main-actor gate makes store completion ordering deterministic, without disk
/// sleeps or locks on the UI actor. Every continuation is released by its test.
@MainActor private final class SnippetReadGate {
    private(set) var calls = 0
    private var pending: [Int: CheckedContinuation<Result<[Snippet], Error>, Never>] = [:]
    func load() async -> Result<[Snippet], Error> {
        calls += 1
        let call = calls
        return await withCheckedContinuation { pending[call] = $0 }
    }
    func finish(_ call: Int, _ records: [Snippet]) { pending.removeValue(forKey: call)?.resume(returning: .success(records)) }
    func finishAll(_ records: [Snippet]) { for call in Array(pending.keys) { finish(call, records) } }
}
