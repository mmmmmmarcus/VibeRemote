import XCTest
@testable import vvhisper

@MainActor final class ClipboardHistoryTests: XCTestCase {
    func testBoundedUniqueNewestFirstAndExactText() {
        let history = ClipboardHistory(fileURL: nil)
        for text in ["one", "two", "three", "four", "five", "six", "two"] { history.record(text) }
        XCTAssertEqual(history.items, ["two", "six", "five", "four", "three"])
        history.record(" \n "); history.record(String(repeating: "x", count: 20_001))
        XCTAssertEqual(history.items.count, 5)
        history.record("  中文\n👨‍👩‍👧‍👦  ")
        XCTAssertEqual(history.items.first, "  中文\n👨‍👩‍👧‍👦  ")
        XCTAssertEqual(ClipboardHistory.preview(history.items[0]), "中文 👨‍👩‍👧‍👦")
    }
    func testPersistenceAndClear() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("recent.json")
        let history = ClipboardHistory(fileURL: url)
        history.record("first"); history.record("second")
        XCTAssertEqual(ClipboardHistory(fileURL: url).items, ["second", "first"])
        XCTAssertEqual(try folder.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        history.clear()
        XCTAssertTrue(ClipboardHistory(fileURL: url).items.isEmpty)
    }
    func testObservesOnlyNewStableClipboardVersions() {
        let board = TestCodeClipboard()
        let monitor = CopiedCodeMonitor(clipboard: board, defaults: nil, bootTime: { 100 })
        let history = ClipboardHistory(fileURL: nil)
        monitor.onObservedText = { history.record($0) }
        board.value = "existing"; monitor.refresh()
        XCTAssertTrue(history.items.isEmpty)
        board.copy("new text"); monitor.refresh(); monitor.refresh()
        XCTAssertEqual(history.items, ["new text"]); XCTAssertEqual(board.reads, 1)
        history.clear(); monitor.refresh(); XCTAssertTrue(history.items.isEmpty)
        board.copy("stale"); board.onRead = { board.copy("replacement") }
        monitor.refresh(); XCTAssertTrue(history.items.isEmpty)
        board.onRead = nil; monitor.refresh()
        XCTAssertEqual(history.items, ["replacement"])
    }
    func testHistoryPasteRejectsChangedDestinationAndDoesNotReorder() throws {
        let saved = UserDefaults.standard.object(forKey: KeyboardLayoutMode.preferenceKey)
        KeyboardLayoutMode.full.save()
        defer { UserDefaults.standard.set(saved, forKey: KeyboardLayoutMode.preferenceKey) }
        let keyboard = KeyboardViewController()
        let proxy = TextViewProxy("", selection: .init(location: 0, length: 0))
        keyboard.testingDocumentProxy = proxy; keyboard.loadViewIfNeeded()
        defer { keyboard.viewWillDisappear(false) }
        keyboard.clipboardHistory.record("first"); keyboard.clipboardHistory.record("second")
        let request = try XCTUnwrap(keyboard.beginPaste(codeOnly: false))
        keyboard.completePaste("first", request: request, remember: false)
        XCTAssertEqual(proxy.editor.text, "first")
        XCTAssertEqual(keyboard.clipboardHistory.items, ["second", "first"])
        let stale = try XCTUnwrap(keyboard.beginPaste(codeOnly: false))
        proxy.documentIdentifier = UUID()
        keyboard.completePaste("wrong", request: stale, remember: false)
        XCTAssertEqual(proxy.editor.text, "first")
    }
    func testRecentDictationSectionInsertsSavedResultWithoutTouchingClipboardHistory() throws {
        let saved = UserDefaults.standard.object(forKey: KeyboardLayoutMode.preferenceKey)
        KeyboardLayoutMode.full.save()
        defer { UserDefaults.standard.set(saved, forKey: KeyboardLayoutMode.preferenceKey) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vvhisper-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let keyboard = KeyboardViewController()
        let proxy = TextViewProxy("", selection: .init(location: 0, length: 0))
        keyboard.testingDocumentProxy = proxy; keyboard.loadViewIfNeeded()
        defer { keyboard.viewWillDisappear(false) }
        XCTAssertFalse(keyboard.clipboardHistoryMenu().contains { ($0 as? UIMenu)?.title == "Recent Dictation" })
        keyboard.dictationRecents = DictationRecentStore(fileURL: url)
        keyboard.dictationRecents.record("Dictated result.")
        let sections = keyboard.clipboardHistoryMenu().compactMap { $0 as? UIMenu }
        XCTAssertEqual(sections.map(\.title), ["Clipboard", "Recent Dictation"])
        let item = try XCTUnwrap(sections[1].children.first as? UIAction)
        XCTAssertEqual(item.title, "Dictated result.")
        XCTAssertEqual((sections[1].children.last as? UIAction)?.title, "Clear Recent Dictation")
        XCTAssertTrue(keyboard.clipboardHistory.items.isEmpty)
    }
}
