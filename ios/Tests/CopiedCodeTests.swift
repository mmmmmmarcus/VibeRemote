import XCTest
@testable import vvhisper

@MainActor final class TestCodeClipboard: CodeClipboard {
    var changeCount = 1
    var value: String?
    var reads = 0
    var onRead: (() -> Void)?
    var text: String? { reads += 1; onRead?(); return value }
    func copy(_ text: String?) { changeCount += 1; value = text }
}

@MainActor final class CopiedCodeTests: XCTestCase {
    func testIgnoresExistingClipboardAndReadsEachNewVersionOnceIncludingDeniedAccess() {
        let board = TestCodeClipboard(); board.value = "123456"
        let monitor = CopiedCodeMonitor(clipboard: board, defaults: nil, bootTime: { 100 })
        monitor.refresh(); XCTAssertFalse(monitor.isAvailable); XCTAssertEqual(board.reads, 0)
        board.copy(nil) // Permission denied / non-text clipboard.
        monitor.refresh(); monitor.refresh(); XCTAssertFalse(monitor.isAvailable); XCTAssertEqual(board.reads, 1)
        board.copy("ordinary text")
        monitor.refresh(); monitor.refresh(); XCTAssertFalse(monitor.isAvailable); XCTAssertEqual(board.reads, 2)
        board.copy("Your verification code: 482913")
        monitor.refresh(); monitor.refresh(); XCTAssertTrue(monitor.isAvailable); XCTAssertEqual(board.reads, 3)
        XCTAssertEqual(monitor.takeCode(), "482913"); XCTAssertFalse(monitor.isAvailable)
        XCTAssertNil(monitor.takeCode()); XCTAssertEqual(board.reads, 4)
        monitor.refresh(); XCTAssertFalse(monitor.isAvailable); XCTAssertEqual(board.reads, 4)
        board.copy("Your verification code: 482913") // Explicitly copying again is new.
        monitor.refresh(); XCTAssertTrue(monitor.isAvailable)
    }
    func testExpirationAndClipboardReplacementNeverPasteStaleCodes() {
        var date = Date(timeIntervalSince1970: 1000)
        let board = TestCodeClipboard()
        let monitor = CopiedCodeMonitor(clipboard: board, defaults: nil, now: { date }, bootTime: { 100 })
        monitor.refresh(); board.copy("123456"); monitor.refresh()
        date.addTimeInterval(121)
        XCTAssertFalse(monitor.isAvailable); XCTAssertNil(monitor.takeCode())
        board.copy("234567"); monitor.refresh(); XCTAssertTrue(monitor.isAvailable)
        board.copy("345678") // Changes just before tapping the old icon.
        XCTAssertNil(monitor.takeCode()); XCTAssertFalse(monitor.isAvailable)
        monitor.refresh(); XCTAssertTrue(monitor.isAvailable)
        board.copy(nil); monitor.refresh(); XCTAssertFalse(monitor.isAvailable)
    }
    func testChangingClipboardDuringPermissionResponseCannotPublishOrPasteNewerText() {
        let board = TestCodeClipboard()
        let monitor = CopiedCodeMonitor(clipboard: board, defaults: nil, bootTime: { 100 })
        monitor.refresh(); board.copy("123456")
        board.onRead = { board.copy("234567") }
        monitor.refresh(); XCTAssertFalse(monitor.isAvailable)
        board.onRead = nil; monitor.refresh(); XCTAssertTrue(monitor.isAvailable)
        board.onRead = { board.copy("345678") }
        XCTAssertNil(monitor.takeCode()); XCTAssertFalse(monitor.isAvailable)
        board.onRead = nil
    }
    func testMetadataSurvivesControllerRestartWithoutSavingClipboardText() throws {
        let suite = "CopiedCodeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let board = TestCodeClipboard()
        var boot: TimeInterval = 100
        var monitor = CopiedCodeMonitor(clipboard: board, defaults: defaults, bootTime: { boot })
        monitor.refresh(); board.copy("Your code: 928314"); monitor.refresh()
        let data = try XCTUnwrap(defaults.data(forKey: "keyboard.copiedCodeMetadata"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("928314"))
        monitor = CopiedCodeMonitor(clipboard: board, defaults: defaults, bootTime: { boot })
        monitor.refresh(); XCTAssertTrue(monitor.isAvailable); XCTAssertEqual(board.reads, 1)
        monitor.consume()
        monitor = CopiedCodeMonitor(clipboard: board, defaults: defaults, bootTime: { boot })
        monitor.refresh(); XCTAssertFalse(monitor.isAvailable); XCTAssertEqual(board.reads, 1)
        boot = 200; board.copy("345678")
        monitor.refresh(); XCTAssertFalse(monitor.isAvailable); XCTAssertEqual(board.reads, 1)
    }
}
