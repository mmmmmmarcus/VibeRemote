import XCTest
import UIKit
@testable import vvhisper

final class SnippetStoreTests: XCTestCase {
    private func withStore(_ body: (SnippetStore) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(SnippetStore(directory: directory))
    }
    func testValidationOrderASCIIAndPreservedOriginal() throws {
        try withStore { store in
            for (abbreviation, expected): (String, SnippetError) in [("", .abbreviationRequired), ("@@a", .callMarker), (" a", .invalidAbbreviation), ("a ", .invalidAbbreviation), ("中文", .invalidAbbreviation), ("a-b", .invalidAbbreviation), ("é", .invalidAbbreviation)] {
                XCTAssertThrowsError(try store.save(abbreviation: abbreviation, content: "")) { XCTAssertEqual($0 as? SnippetError, expected) }
            }
            let content = "  e\u{301} 👨‍👩‍👧‍👦\r\n第二行\t "
            let first = try store.save(abbreviation: "0_GMail", content: content)
            XCTAssertEqual(first.content.utf8.map { $0 }, content.utf8.map { $0 })
            XCTAssertThrowsError(try store.save(abbreviation: "0_gmail", content: "")) { XCTAssertEqual($0 as? SnippetError, .duplicate) }
            XCTAssertThrowsError(try store.save(abbreviation: "new", content: " \r\n\t")) { XCTAssertEqual($0 as? SnippetError, .contentRequired) }
            XCTAssertEqual(try store.load(), [first])
        }
    }
    func testStableIDRevisionAndOrderWithOptimisticEditsAndDelete() throws {
        try withStore { store in
            let a = try store.save(abbreviation: "a", content: "first")
            let b = try store.save(abbreviation: "b", content: "second")
            let edited = try store.save(abbreviation: "A", content: "changed", replacing: a)
            XCTAssertEqual(a.id, edited.id); XCTAssertNotEqual(a.revision, edited.revision)
            XCTAssertEqual(try store.load(), [edited, b])
            XCTAssertThrowsError(try store.save(abbreviation: "c", content: "stale", replacing: a)) { XCTAssertEqual($0 as? SnippetError, .stale) }
            XCTAssertThrowsError(try store.delete(a)) { XCTAssertEqual($0 as? SnippetError, .stale) }
            try store.delete(edited); XCTAssertEqual(try store.load(), [b])
            XCTAssertThrowsError(try store.save(abbreviation: "a", content: "", replacing: b))
            XCTAssertEqual(try store.load(), [b])
        }
    }
    func testNoProductLengthOrCountCapAndGraphemePreview() throws {
        try withStore { store in
            let content = " \n" + String(repeating: "👨‍👩‍👧‍👦e\u{301}\r\n", count: 12_000) + " END "
            let abbreviation = String(repeating: "a", count: 2000)
            let record = try store.save(abbreviation: abbreviation, content: content)
            XCTAssertEqual(try store.load().first?.content, content)
            XCTAssertEqual(record.preview, content.prefix(20).map { $0.isNewline ? " " : String($0) }.joined() + "…")
            for index in 0..<100 { try store.save(abbreviation: "n_\(index)", content: "item") }
            XCTAssertEqual(try store.load().count, 101)
        }
    }
    func testBackupExclusionAndCompleteProtectionBeforeAndAfterReplacement() throws {
        try withStore { store in
            var record = try store.save(abbreviation: "a", content: "synthetic")
            for _ in 0..<2 {
                let directory = try XCTUnwrap(store.directory)
                for url in [directory, directory.appendingPathComponent("records.json"), directory.appendingPathComponent("store.lock")] {
                    XCTAssertEqual(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
                    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                    XCTAssertEqual(attributes[.posixPermissions] as? Int, url.hasDirectoryPath ? 0o700 : 0o600)
                    #if targetEnvironment(simulator)
                    // Simulator has no Data Protection classes and returns nil.
                    // Verify the production policy; actual locked-device behavior
                    // remains a mandatory device check, not a simulated pass.
                    XCTAssertEqual(SnippetStore.protectionAttributes(directory: url.hasDirectoryPath)[.protectionKey] as? FileProtectionType, .complete)
                    #else
                    XCTAssertEqual(attributes[.protectionKey] as? FileProtectionType, .complete)
                    #endif
                }
                record = try store.save(abbreviation: "A", content: "replacement", replacing: record)
            }
        }
    }
    func testCorruptionIsNotEmptyAndFailedSavePreservesDisk() throws {
        try withStore { store in
            XCTAssertEqual(try store.load(), [])
            let file = try XCTUnwrap(store.directory).appendingPathComponent("records.json")
            try Data("broken".utf8).write(to: file)
            XCTAssertThrowsError(try store.load()) { XCTAssertEqual($0 as? SnippetError, .corrupt) }
            XCTAssertThrowsError(try store.save(abbreviation: "a", content: "new"))
            XCTAssertEqual(try Data(contentsOf: file), Data("broken".utf8))
            XCTAssertThrowsError(try SnippetStore(directory: nil).load())
        }
    }
    func testConcurrentIndependentStoreInstancesAtomicallyEnforceUniqueness() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let successes = await withTaskGroup(of: Bool.self) { group in
            for index in 0..<24 {
                group.addTask {
                    let store = SnippetStore(directory: directory)
                    return (try? store.save(abbreviation: index.isMultiple(of: 2) ? "GMAIL" : "gmail", content: "synthetic")) != nil
                }
            }
            var count = 0
            for await success in group { if success { count += 1 } }
            return count
        }
        XCTAssertEqual(successes, 1)
        XCTAssertEqual(try SnippetStore(directory: directory).load().count, 1)
    }
}

@MainActor final class SnippetInputTests: XCTestCase {
    private func proxy(_ text: String = "prefix @@GMAIL") -> TextViewProxy {
        TextViewProxy(text, selection: NSRange(location: text.utf16.count, length: 0))
    }
    func testExpansionPreservesPrefixAndEntireUnicodeContentForImmediateAndCoalescingHosts() async throws {
        for coalesced in [false, true] {
            let proxy = proxy(); proxy.coalescesTurnOutput = coalesced
            let destination = try XCTUnwrap(SnippetDestination.capture(proxy, composing: false))
            let operation = SnippetExpansion(destination: destination)
            let content = "  第一行\n" + String(repeating: "👨‍👩‍👧‍👦e\u{301}", count: 12_000) + "\r\n尾部 "
            let result = await operation.run(token: "@@GMAIL", content: content, proxy: proxy, permitted: { true }, composing: { false })
            proxy.flushTurnOutput()
            XCTAssertTrue(result); XCTAssertEqual(proxy.backspaces, 7)
            XCTAssertEqual(proxy.editor.text, "prefix " + content)
        }
    }
    func testNoDeletionForChangedCaseSelectionDocumentHiddenContextOrComposition() async throws {
        for invalidation in 0..<6 {
            let proxy = proxy()
            let destination = try XCTUnwrap(SnippetDestination.capture(proxy, composing: false))
            let operation = SnippetExpansion(destination: destination)
            switch invalidation {
            case 0: proxy.editor.text = "prefix @@gmail"; proxy.editor.selectedRange = NSRange(location: 14, length: 0)
            case 1: proxy.editor.selectedRange = NSRange(location: 0, length: 2)
            case 2: proxy.documentIdentifier = UUID()
            case 3: proxy.hidesContext = true
            case 4: proxy.editor.selectedRange = NSRange(location: 5, length: 0)
            default: break
            }
            let result = await operation.run(token: "@@GMAIL", content: "NEVER", proxy: proxy, permitted: { true }, composing: { invalidation == 5 })
            XCTAssertFalse(result); XCTAssertEqual(proxy.backspaces, 0); XCTAssertFalse(proxy.editor.text.contains("NEVER"))
        }
    }
    func testUnacknowledgedDeletionStopsWithoutBlindDeletesInsertionOrCompensation() async throws {
        let proxy = proxy(); proxy.defersTextEdits = true
        let operation = SnippetExpansion(destination: try XCTUnwrap(SnippetDestination.capture(proxy, composing: false)))
        let result = await operation.run(token: "@@GMAIL", content: "NEVER", proxy: proxy, permitted: { true }, composing: { false })
        XCTAssertFalse(result); XCTAssertEqual(proxy.backspaces, 1)
        XCTAssertEqual(proxy.editor.text, "prefix @@GMAIL")
        proxy.flushTextEdits(); XCTAssertEqual(proxy.editor.text, "prefix @@GMAI")
    }
    func testPermissionRevocationAndCancellationBetweenDeletesStopImmediately() async throws {
        for cancel in [true, false] {
            let proxy = proxy()
            let operation = SnippetExpansion(destination: try XCTUnwrap(SnippetDestination.capture(proxy, composing: false)))
            let result = await operation.run(token: "@@GMAIL", content: "NEVER", proxy: proxy, permitted: {
                if proxy.backspaces == 1 { if cancel { operation.cancel() }; return cancel }
                return true
            }, composing: { false })
            XCTAssertFalse(result); XCTAssertEqual(proxy.backspaces, 1); XCTAssertEqual(proxy.editor.text, "prefix @@GMAI")
        }
    }
    func testRawInputRequiresOwnedExactSuffixAndResetsOnCursorChange() throws {
        let proxy = proxy("prefix ")
        let raw = SnippetRawInput()
        XCTAssertNil(raw.matchable(at: SnippetDestination.capture(proxy, composing: false)))
        for character in "@@GMAIL" {
            let destination = try XCTUnwrap(SnippetDestination.capture(proxy, composing: false))
            let text = String(character)
            XCTAssertTrue(raw.wantsLiteral(text, at: destination))
            raw.inserted(text, from: destination); proxy.insertText(text)
        }
        XCTAssertEqual(raw.matchable(at: SnippetDestination.capture(proxy, composing: false)), "@@GMAIL")
        XCTAssertFalse(raw.wantsLiteral(" ", at: SnippetDestination.capture(proxy, composing: false)))
        raw.observe(SnippetDestination.capture(proxy, composing: false))
        proxy.editor.selectedRange = NSRange(location: 2, length: 0)
        raw.observe(SnippetDestination.capture(proxy, composing: false))
        XCTAssertEqual(raw.token, "")
    }
}
