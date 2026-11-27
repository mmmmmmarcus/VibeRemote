import XCTest
import UIKit
@testable import vvhisper

@MainActor final class SnippetEditorTests: XCTestCase {
    private func descendants(_ view: UIView) -> [UIView] { view.subviews.flatMap { [$0] + descendants($0) } }
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }
    private func withEditor(original: Bool = false, unavailable: Bool = false,
                            _ body: (SnippetEditorViewController, SnippetStore, UIViewController) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = SnippetStore(directory: directory)
        let record = original ? try store.save(abbreviation: "gmail", content: "original\nfull content") : nil
        let editor = SnippetEditorViewController(store: unavailable ? SnippetStore(directory: nil) : store, original: record)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene), root = UIViewController()
        window.rootViewController = root; window.frame = CGRect(x: 0, y: 0, width: 402, height: 844); window.isHidden = false
        let navigation = UINavigationController(rootViewController: editor)
        await withCheckedContinuation { continuation in
            root.present(navigation, animated: false) { continuation.resume() }
        }
        editor.loadViewIfNeeded()
        defer { window.isHidden = true; root.dismiss(animated: false); try? FileManager.default.removeItem(at: directory) }
        try await body(editor, store, root)
    }
    func testInactiveSceneSnapshotCoverIsOpaqueAndReversible() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.frame = CGRect(x: 0, y: 0, width: 402, height: 844)
        let sensitive = UILabel(frame: window.bounds); sensitive.text = "synthetic private draft"; window.addSubview(sensitive)
        let delegate = SceneDelegate(); delegate.window = window
        delegate.sceneWillResignActive(scene); delegate.sceneWillResignActive(scene)
        let cover = try XCTUnwrap(window.subviews.last)
        XCTAssertFalse(cover === sensitive); XCTAssertEqual(cover.frame, window.bounds)
        XCTAssertEqual(cover.backgroundColor, .systemBackground); XCTAssertEqual(cover.alpha, 1)
        XCTAssertTrue(cover.accessibilityViewIsModal); XCTAssertTrue(cover.subviews.isEmpty)
        XCTAssertEqual(window.subviews.count, 2)
        delegate.setPrivacyCovered(false); XCTAssertTrue(window.subviews.last === sensitive)
    }
    func testExactlyTwoFieldsAndUnsavedCancelConfirmationDoesNotWrite() async throws {
        try await withEditor { editor, store, _ in
            XCTAssertEqual(descendants(editor.view).filter { $0 is UITextField }.count, 1)
            XCTAssertEqual(descendants(editor.view).filter { $0 is UITextView }.count, 1)
            XCTAssertFalse(editor.dirty)
            editor.abbreviation.text = "Draft"; editor.abbreviation.sendActions(for: .editingChanged)
            editor.content.text = "  draft\n👨‍👩‍👧‍👦  "; editor.textViewDidChange(editor.content)
            XCTAssertTrue(editor.dirty); XCTAssertTrue(editor.navigationController?.isModalInPresentation == true)
            editor.cancel()
            try await wait { editor.presentedViewController is UIAlertController || editor.navigationController?.presentedViewController is UIAlertController }
            let alert = try XCTUnwrap((editor.presentedViewController ?? editor.navigationController?.presentedViewController) as? UIAlertController)
            XCTAssertEqual(alert.title, "放弃未保存的修改？")
            XCTAssertEqual(alert.actions.map(\.title), ["继续编辑", "放弃修改"])
            XCTAssertEqual(alert.preferredAction?.title, "继续编辑")
            XCTAssertEqual(editor.content.text, "  draft\n👨‍👩‍👧‍👦  ")
            XCTAssertEqual(try store.load(), [])
        }
    }
    func testValidationDuplicateAndWhitespaceKeepDraftAndCaret() async throws {
        try await withEditor { editor, store, _ in
            _ = try store.save(abbreviation: "gmail", content: "one")
            editor.abbreviation.text = "GMAIL"; editor.content.text = " draft "
            editor.content.selectedRange = NSRange(location: 2, length: 0)
            editor.save()
            try await wait { self.descendants(editor.view).contains { ($0 as? UILabel)?.text == SnippetError.duplicate.message } }
            XCTAssertEqual(editor.abbreviation.text, "GMAIL"); XCTAssertEqual(editor.content.text, " draft ")
            XCTAssertEqual(editor.content.selectedRange.location, 2)
            XCTAssertEqual(editor.abbreviation.accessibilityHint, SnippetError.duplicate.message)
            editor.abbreviation.text = "new"; editor.content.text = " \n\t"; editor.save()
            try await wait { editor.content.accessibilityHint == SnippetError.contentRequired.message }
            XCTAssertEqual(try store.load().count, 1)
        }
    }
    func testSaveFailureKeepsDraftCaretAndRestoresRetry() async throws {
        try await withEditor(unavailable: true) { editor, _, _ in
            editor.abbreviation.text = "gmail"; editor.content.text = "  full\ntext  "
            editor.content.selectedRange = NSRange(location: 4, length: 0)
            editor.save(); editor.save() // Single mutation despite a duplicate activation.
            XCTAssertEqual(editor.navigationItem.rightBarButtonItem?.isEnabled, false)
            try await wait { editor.navigationItem.rightBarButtonItem?.isEnabled == true }
            XCTAssertTrue(self.descendants(editor.view).contains { ($0 as? UILabel)?.text == "未能保存，请重试。" })
            XCTAssertEqual(editor.content.text, "  full\ntext  "); XCTAssertEqual(editor.content.selectedRange.location, 4)
            XCTAssertNotNil(editor.presentingViewController)
        }
    }
    func testSaveIsDurableBeforeCompletionAndNoPermissionRequired() async throws {
        try await withEditor { editor, store, root in
            var completed = false
            editor.onComplete = { message in
                XCTAssertEqual(message, "已保存。")
                XCTAssertEqual(try? store.load().first?.content, " full\noriginal ")
                completed = true
            }
            editor.abbreviation.text = "Gmail"; editor.content.text = " full\noriginal "
            editor.save(); try await wait { completed }
            XCTAssertNil(root.presentedViewController)
            XCTAssertEqual(try store.load().first?.abbreviation, "Gmail")
        }
    }
    func testDeletionConfirmationAndDurableDeletion() async throws {
        try await withEditor(original: true) { editor, store, _ in
            let delete = try XCTUnwrap(self.descendants(editor.view).compactMap { $0 as? UIButton }.first { $0.title(for: .normal) == "删除 Snippet" })
            delete.sendActions(for: .touchUpInside)
            try await wait { editor.presentedViewController is UIAlertController || editor.navigationController?.presentedViewController is UIAlertController }
            let alert = try XCTUnwrap((editor.presentedViewController ?? editor.navigationController?.presentedViewController) as? UIAlertController)
            XCTAssertEqual(alert.title, "删除这个 Snippet？")
            XCTAssertEqual(alert.message, "缩写「gmail」和保存的内容将被删除，已经填入其他 App 的文字不会删除。")
            XCTAssertEqual(alert.preferredAction?.title, "取消")
            XCTAssertEqual(try store.load().count, 1)
            await withCheckedContinuation { continuation in
                alert.dismiss(animated: false) { continuation.resume() }
            }
            var completed = false
            editor.onComplete = { message in XCTAssertEqual(message, "已删除。"); XCTAssertEqual(try? store.load().count, 0); completed = true }
            editor.deleteConfirmed(); try await wait { completed }
        }
    }
    func testStaleEditorSavePreservesNewerRecordAndDraft() async throws {
        try await withEditor(original: true) { editor, store, _ in
            let original = try XCTUnwrap(editor.original)
            _ = try store.save(abbreviation: "GMAIL", content: "newer revision", replacing: original)
            editor.content.text = "older draft"; editor.save()
            try await wait { self.descendants(editor.view).contains { ($0 as? UILabel)?.text == "未能保存，请重试。" } }
            XCTAssertEqual(editor.content.text, "older draft"); XCTAssertEqual(try store.load().first?.content, "newer revision")
        }
    }
    func testDeleteFailurePreservesRecordAndDraft() async throws {
        try await withEditor(original: true, unavailable: true) { editor, store, _ in
            editor.content.text = "draft changed"; editor.deleteConfirmed()
            try await wait { self.descendants(editor.view).contains { ($0 as? UILabel)?.text == "未能删除，请重试。" } }
            XCTAssertEqual(editor.content.text, "draft changed"); XCTAssertEqual(try store.load().count, 1)
        }
    }
}
