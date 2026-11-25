import XCTest
import UIKit
@testable import vvhisper

@MainActor
final class DictationTextTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)
    private func reply(_ session: DictationTextSession, _ text: String, step: Double,
                       final: Bool = false, error: String? = nil) -> VoiceReply {
        VoiceReply(id: session.id, text: text, isFinal: final, error: error,
                   updatedAt: now.addingTimeInterval(-1 + step * 0.01))
    }
    private func show(_ text: String, session: DictationTextSession, proxy: TextViewProxy) {
        _ = session.receive(reply(session, text, step: 1), in: proxy, now: now)
        _ = session.receive(reply(session, text + " more", step: 2), in: proxy, now: now)
    }

    func testLiveTextGrowsInEditorAndPolishReplacesOnlyItsSpan() {
        let proxy = TextViewProxy("Before:  after", selection: NSRange(location: 8, length: 0))
        let session = DictationTextSession(id: UUID(), proxy: proxy)
        let first = reply(session, "we can", step: 1)
        XCTAssertEqual(session.receive(first, in: proxy, now: now), .partial)
        XCTAssertEqual(proxy.editor.text, "Before:  after")
        // Polling the same IPC file is not a second recognition result.
        XCTAssertEqual(session.receive(first, in: proxy, now: now), .ignored)
        XCTAssertEqual(proxy.writes, 0)
        _ = session.receive(reply(session, "we can meet", step: 2), in: proxy, now: now)
        XCTAssertEqual(proxy.editor.text, "Before: we can after")
        XCTAssertNotNil(proxy.editor.markedTextRange)
        _ = session.receive(reply(session, "we can meet today", step: 3), in: proxy, now: now)
        XCTAssertEqual(proxy.editor.text, "Before: we can meet after")
        session.finishRecording()
        _ = session.receive(reply(session, "we can meet today!", step: 4), in: proxy, now: now)
        XCTAssertEqual(proxy.editor.text, "Before: we can meet after")
        let final = reply(session, "We can meet tomorrow.", step: 5, final: true)
        XCTAssertEqual(session.receive(final, in: proxy, now: now), .finished)
        XCTAssertEqual(proxy.editor.text, "Before: We can meet tomorrow. after")
        XCTAssertNil(proxy.editor.markedTextRange)
        XCTAssertEqual(session.receive(final, in: proxy, now: now), .ignored)
        XCTAssertEqual(proxy.backspaces, 0)
    }

    func testDelayedMarkedWritesDoNotCancelAndFinalUnmarksAfterAcknowledgement() {
        for limit: Int? in [nil, 8] {
            let proxy = TextViewProxy("prefix ", selection: .init(location: 7, length: 0))
            proxy.contextLimit = limit; proxy.defersMarkedEdits = true; proxy.defersTextEdits = true; proxy.nilAtEmptyContext = true
            let session = DictationTextSession(id: UUID(), proxy: proxy)
            show("rough speech", session: session, proxy: proxy)
            XCTAssertTrue(session.matches(proxy)) // The write is still in flight.
            XCTAssertEqual(proxy.editor.text, "prefix ")
            proxy.flushTextEdits()
            XCTAssertTrue(session.matches(proxy)) // The acknowledgement is not a user edit.
            XCTAssertNotNil(proxy.editor.markedTextRange)
            proxy.returnKeyType = .send
        session.finishRecording(submitAfterPolish: true)
            let final = reply(session, "Polished speech.", step: 3, final: true)
            XCTAssertEqual(session.receive(final, in: proxy, now: now), .partial)
            XCTAssertEqual(session.receive(final, in: proxy, now: now), .partial)
            XCTAssertEqual(proxy.unmarks, 1)
            XCTAssertEqual(proxy.editor.text, "prefix rough speech")
            proxy.flushTextEdits()
            XCTAssertEqual(session.receive(final, in: proxy, now: now), .finished)
            XCTAssertEqual(proxy.unmarks, 1)
            proxy.flushTextEdits()
            XCTAssertNil(proxy.editor.markedTextRange)
            XCTAssertEqual(proxy.editor.text, "prefix Polished speech.\n")
            XCTAssertEqual(session.receive(final, in: proxy, now: now), .ignored)
        }
    }

    func testDelayedDraftCancellationUnmarksWithoutReplacingAnUnrelatedField() {
        for changedField in [false, true] {
            let proxy = TextViewProxy("", selection: .init(location: 0, length: 0))
            proxy.defersMarkedEdits = true
            let session = DictationTextSession(id: UUID(), proxy: proxy)
            show("visible draft", session: session, proxy: proxy)
            proxy.flushTextEdits()
            if changedField { proxy.documentIdentifier = UUID() }
            session.cancel(in: proxy)
            proxy.flushTextEdits()
            XCTAssertEqual(proxy.editor.text, "visible draft")
            XCTAssertEqual(proxy.unmarks, changedField ? 0 : 1)
            if !changedField { XCTAssertNil(proxy.editor.markedTextRange) }
            XCTAssertEqual(session.receive(reply(session, "late", step: 3, final: true), in: proxy, now: now), .ignored)
        }
    }

    func testRemoteProxyExcludingMarkedTextCommitsAndClearsUnderline() async {
        let proxy = TextViewProxy("prefix  suffix", selection: .init(location: 7, length: 0))
        proxy.excludesMarkedContext = true
        let session = DictationTextSession(id: UUID(), proxy: proxy)
        show("rough speech", session: session, proxy: proxy)
        XCTAssertEqual(proxy.documentContextBeforeInput, "prefix ")
        XCTAssertTrue(session.matches(proxy))
        XCTAssertNotNil(proxy.editor.markedTextRange)
        await Task.yield()
        session.finishRecording()
        let final = reply(session, "Polished speech.", step: 3, final: true)
        XCTAssertEqual(session.receive(final, in: proxy, now: now), .finished)
        XCTAssertEqual(proxy.editor.text, "prefix Polished speech. suffix")
        XCTAssertNil(proxy.editor.markedTextRange)
    }

    func testInitiallyEmptyRemoteFieldKeepsDictationWithNilMarkedContext() async {
        for (rough, final) in [("rough speech", "Polished speech."), ("我知道了", "我知道了。"), ("first\nsecond", "First.\nSecond.")] {
            let proxy = TextViewProxy("", selection: .init(location: 0, length: 0))
            proxy.excludesMarkedContext = true; proxy.nilAtEmptyContext = true
            let session = DictationTextSession(id: UUID(), proxy: proxy)
            show(rough, session: session, proxy: proxy)
            XCTAssertTrue(proxy.hasText)
            XCTAssertNil(proxy.documentContextBeforeInput)
            XCTAssertNil(proxy.documentContextAfterInput)
            XCTAssertTrue(session.matches(proxy))
            await Task.yield()
            session.finishRecording()
            XCTAssertEqual(session.receive(reply(session, final, step: 3, final: true), in: proxy, now: now), .finished)
            XCTAssertEqual(proxy.editor.text, final)
            XCTAssertNil(proxy.editor.markedTextRange)
        }
    }

    func testEmptyMarkedContextStillRejectsOtherFieldsAndHiddenNonemptyContext() {
        for wasEmpty in [false, true] {
            let prefix = wasEmpty ? "" : "prefix "
            let proxy = TextViewProxy(prefix, selection: .init(location: prefix.count, length: 0))
            proxy.excludesMarkedContext = true; proxy.nilAtEmptyContext = true
            let session = DictationTextSession(id: UUID(), proxy: proxy)
            show("draft", session: session, proxy: proxy)
            if wasEmpty { proxy.documentIdentifier = UUID() }
            else { proxy.hidesContext = true }
            XCTAssertFalse(session.matches(proxy))
            XCTAssertEqual(session.receive(reply(session, "must not replace", step: 3, final: true), in: proxy, now: now), .destinationChanged)
            XCTAssertEqual(proxy.editor.text, prefix + "draft")
        }
    }

    func testChineseEmojiAndMultilineFinalReplaceASelectionUsingUTF16() {
        let proxy = TextViewProxy("开头旧文字结尾", selection: NSRange(location: 2, length: 3))
        let session = DictationTextSession(id: UUID(), proxy: proxy)
        show("你好👨‍👩‍👧‍👦", session: session, proxy: proxy)
        XCTAssertEqual(proxy.editor.text, "开头你好👨‍👩‍👧‍👦结尾")
        let polished = "你好，世界。\n👨‍👩‍👧‍👦🙂"
        _ = session.receive(reply(session, polished, step: 3, final: true), in: proxy, now: now)
        XCTAssertEqual(proxy.editor.text, "开头" + polished + "结尾")
        XCTAssertEqual(proxy.editor.selectedRange, NSRange(location: 2 + polished.utf16.count, length: 0))
        XCTAssertNil(proxy.editor.markedTextRange)
    }

    func testExplicitCancelRestoresDisplacedSelectionAndRejectsLatePolish() {
        let proxy = TextViewProxy("keep old text safe", selection: NSRange(location: 5, length: 8))
        let session = DictationTextSession(id: UUID(), proxy: proxy)
        show("new speech", session: session, proxy: proxy)
        session.cancel(in: proxy, discard: true)
        XCTAssertEqual(proxy.editor.text, "keep old text safe")
        XCTAssertNil(proxy.editor.markedTextRange)
        XCTAssertEqual(session.receive(reply(session, "late result", step: 3, final: true), in: proxy, now: now), .ignored)
        XCTAssertEqual(proxy.editor.text, "keep old text safe")
    }

    func testTypingInterruptionPreservesVisibleSpeechAndUnmarksIt() {
        let proxy = TextViewProxy("", selection: .init(location: 0, length: 0))
        let session = DictationTextSession(id: UUID(), proxy: proxy)
        show("hello", session: session, proxy: proxy)
        session.cancel(in: proxy)
        proxy.insertText(" world")
        XCTAssertEqual(proxy.editor.text, "hello world")
        XCTAssertEqual(session.receive(reply(session, "replacement", step: 3, final: true), in: proxy, now: now), .ignored)
        XCTAssertEqual(proxy.editor.text, "hello world")
    }

    func testDeletionWhilePolishingRejectsLateResultAndKeepsEdit() {
        let proxy = TextViewProxy("", selection: .init(location: 0, length: 0))
        let session = DictationTextSession(id: UUID(), proxy: proxy)
        show("hello", session: session, proxy: proxy)
        session.finishRecording()
        var polishing = reply(session, "hello", step: 3)
        polishing.polishing = true
        _ = session.receive(polishing, in: proxy, now: now)
        session.cancel(in: proxy)
        XCTAssertNil(proxy.editor.markedTextRange)
        proxy.deleteBackward()
        let edited = proxy.editor.text
        XCTAssertEqual(session.receive(reply(session, "Replacement.", step: 4, final: true), in: proxy, now: now), .ignored)
        XCTAssertEqual(proxy.editor.text, edited)
        XCTAssertEqual(edited, "hell")
    }

    func testCursorSelectionFieldAndExternalEditsRejectLateReplacement() {
        for change in 0..<4 {
            let proxy = TextViewProxy("prefix ", selection: NSRange(location: 7, length: 0))
            let session = DictationTextSession(id: UUID(), proxy: proxy)
            show("speech", session: session, proxy: proxy)
            proxy.editor.unmarkText()
            switch change {
            case 0: proxy.editor.selectedRange = NSRange(location: 0, length: 0)
            case 1: proxy.editor.selectedRange = NSRange(location: 0, length: 3)
            case 2: proxy.documentIdentifier = UUID() // Identical text in another field.
            default: proxy.insertText(" user edit")
            }
            let untouched = proxy.editor.text
            XCTAssertEqual(session.receive(reply(session, "must not appear", step: 3, final: true), in: proxy, now: now), .destinationChanged)
            session.cancel(in: proxy, discard: true)
            XCTAssertEqual(proxy.editor.text, untouched)
        }
    }

    func testFailureKeepsPreviewAndFinalWithoutPartialsCanStillInsert() {
        let proxy = TextViewProxy("", selection: NSRange(location: 0, length: 0))
        let session = DictationTextSession(id: UUID(), proxy: proxy)
        show("already spoken", session: session, proxy: proxy)
        XCTAssertEqual(session.receive(reply(session, "", step: 3, final: true, error: "Offline"), in: proxy, now: now), .failed("Offline"))
        XCTAssertEqual(proxy.editor.text, "already spoken")
        XCTAssertNil(proxy.editor.markedTextRange)
        let next = DictationTextSession(id: UUID(), proxy: proxy)
        XCTAssertEqual(next.receive(reply(next, "。", step: 1, final: true), in: proxy, now: now), .finished)
        XCTAssertEqual(proxy.editor.text, "already spoken。")
    }

    func testWrongHoldExpiredFutureAndOutOfOrderRepliesDoNotEditText() {
        let proxy = TextViewProxy("", selection: NSRange(location: 0, length: 0))
        let session = DictationTextSession(id: UUID(), proxy: proxy)
        var invalid = reply(session, "wrong", step: 1, final: true)
        invalid.id = UUID()
        XCTAssertEqual(session.receive(invalid, in: proxy, now: now), .ignored)
        invalid.id = session.id; invalid.updatedAt = now.addingTimeInterval(-16)
        XCTAssertEqual(session.receive(invalid, in: proxy, now: now), .ignored)
        invalid.updatedAt = now.addingTimeInterval(1)
        XCTAssertEqual(session.receive(invalid, in: proxy, now: now), .ignored)
        show("hello", session: session, proxy: proxy)
        XCTAssertEqual(session.receive(reply(session, "old", step: 1, final: true), in: proxy, now: now), .ignored)
        XCTAssertEqual(proxy.editor.text, "hello")
    }

    func testLongDictationToleratesBoundedProxyContextAndOwnWriteCallbacks() {
        let proxy = TextViewProxy("prefix ", selection: NSRange(location: 7, length: 0))
        proxy.contextLimit = 8
        let session = DictationTextSession(id: UUID(), proxy: proxy)
        proxy.onWrite = { XCTAssertTrue(session.isUpdating) }
        let speech = String(repeating: "中文🙂", count: 100)
        show(speech, session: session, proxy: proxy)
        XCTAssertTrue(session.matches(proxy))
        XCTAssertEqual(session.receive(reply(session, "polished", step: 3, final: true), in: proxy, now: now), .finished)
        XCTAssertEqual(proxy.editor.text, "prefix polished")
    }

    func testPreviewPreservesVisibleTextAcrossPunctuationAndRecognitionCorrections() {
        XCTAssertEqual(StableDictationPreview.growth(shown: "we spoke quickly and", previous: "we spoke quickly, and then", latest: "we spoke quickly, and then left"), "we spoke quickly and then")
        XCTAssertEqual(StableDictationPreview.growth(shown: "我知道", previous: "我知道了", latest: "我知道了谢谢"), "我知道了")
        XCTAssertEqual(StableDictationPreview.growth(shown: "a wrong phrase", previous: "a different result", latest: "a different result now"), "a wrong phrase")
    }

    func testRequestedSendWaitsForNonemptyFinalAndCommitsBeforeReturn() {
        let proxy = TextViewProxy("prefix ", selection: NSRange(location: 7, length: 0))
        let session = DictationTextSession(id: UUID(), proxy: proxy)
        show("rough speech", session: session, proxy: proxy)
        proxy.returnKeyType = .send
        session.finishRecording(submitAfterPolish: true)
        session.finishRecording() // A later release cannot erase the gesture's intent.
        XCTAssertEqual(proxy.editor.text, "prefix rough speech")
        var returns = 0
        proxy.onInsert = { text in
            if text == "Polished speech." { return }
            XCTAssertEqual(text, "\n")
            XCTAssertEqual(proxy.editor.text, "prefix Polished speech.")
            XCTAssertNil(proxy.editor.markedTextRange)
            XCTAssertTrue(session.isUpdating)
            returns += 1
        }
        let final = reply(session, "Polished speech.", step: 3, final: true)
        XCTAssertEqual(session.receive(final, in: proxy, now: now), .finished)
        XCTAssertEqual(session.receive(final, in: proxy, now: now), .ignored)
        XCTAssertEqual(returns, 1)
        XCTAssertEqual(proxy.editor.text, "prefix Polished speech.\n")
    }

    func testEmptyFailedCancelledAndStaleFinalsNeverSendExistingText() {
        for mode in 0..<6 {
            let proxy = TextViewProxy("existing draft", selection: NSRange(location: 14, length: 0))
            let session = DictationTextSession(id: UUID(), proxy: proxy)
            proxy.returnKeyType = .send
        session.finishRecording(submitAfterPolish: true)
            var response = reply(session, "final", step: 1, final: true)
            switch mode {
            case 0: response.text = ""
            case 1: response.text = "   "
            case 2: response.error = "Offline"
            case 3: session.cancel(in: proxy)
            case 4: response.updatedAt = now.addingTimeInterval(-16)
            default: response.id = UUID()
            }
            proxy.onInsert = { text in XCTAssertNotEqual(text, "\n", "No Return without a valid nonempty final") }
            _ = session.receive(response, in: proxy, now: now)
            XCTAssertFalse(proxy.editor.text.contains("\n"))
        }
    }

    func testHostChangingFieldsWhileAcceptingFinalCannotReceivePendingReturn() {
        let proxy = TextViewProxy("", selection: NSRange(location: 0, length: 0))
        let session = DictationTextSession(id: UUID(), proxy: proxy)
        proxy.returnKeyType = .send
        session.finishRecording(submitAfterPolish: true)
        proxy.onInsert = { text in
            XCTAssertNotEqual(text, "\n", "Do not send in the host's newly focused field")
            proxy.documentIdentifier = UUID()
        }
        _ = session.receive(reply(session, "final", step: 1, final: true), in: proxy, now: now)
        XCTAssertEqual(proxy.editor.text, "final")
    }
}

/// Test the production session against UIKit's real marked-text implementation.
/// Only the extension's proxy transport is substituted; editing is not reimplemented.
@MainActor
final class TextViewProxy: NSObject, UITextDocumentProxy {
    var keyboardAppearance: UIKeyboardAppearance = .default
    var textContentType: UITextContentType!
    var keyboardType: UIKeyboardType = .default
    var returnKeyType: UIReturnKeyType = .default
    let editor = UITextView()
    var documentIdentifier = UUID()
    var contextLimit: Int?
    var hidesContext = false
    var nilAtEmptyContext = false
    var paragraphContextOnly = false
    var defersCursorMoves = false
    var defersTextEdits = false
    var defersMarkedEdits = false
    var excludesMarkedContext = false
    /// Models a remote host that receives one coalesced output per main-loop
    /// turn and applies its insertions/deletions before marked-text writes.
    var coalescesTurnOutput = false
    private var turnTextEdits: [() -> Void] = []
    private var turnMarkedEdits: [() -> Void] = []
    private var turnFlushScheduled = false
    private var pendingTextEdits: [() -> Void] = []
    private(set) var pendingCursorMoves: [Int] = []
    var onWrite: (() -> Void)?
    var onInsert: ((String) -> Void)?
    private(set) var writes = 0
    private(set) var backspaces = 0
    private(set) var unmarks = 0
    init(_ text: String, selection: NSRange) {
        super.init()
        editor.text = text; editor.selectedRange = selection
    }
    var documentContextBeforeInput: String? {
        if hidesContext { return nil }
        let position = excludesMarkedContext ? editor.markedTextRange?.start : nil
        let offset = position.map { editor.offset(from: editor.beginningOfDocument, to: $0) } ?? editor.selectedRange.location
        var text = (editor.text as NSString).substring(to: offset)
        if paragraphContextOnly { text = text.components(separatedBy: "\n").last ?? "" }
        if nilAtEmptyContext && text.isEmpty { return nil }
        return contextLimit.map { String(text.suffix($0)) } ?? text
    }
    var documentContextAfterInput: String? {
        if hidesContext { return nil }
        let position = excludesMarkedContext ? editor.markedTextRange?.end : nil
        let offset = position.map { editor.offset(from: editor.beginningOfDocument, to: $0) } ?? NSMaxRange(editor.selectedRange)
        var text = (editor.text as NSString).substring(from: offset)
        if paragraphContextOnly { text = text.components(separatedBy: "\n").first ?? "" }
        if nilAtEmptyContext && text.isEmpty { return nil }
        return contextLimit.map { String(text.prefix($0)) } ?? text
    }
    var selectedText: String? {
        editor.selectedRange.length == 0 ? nil : (editor.text as NSString).substring(with: editor.selectedRange)
    }
    var documentInputMode: UITextInputMode? { nil }
    var hasText: Bool { editor.hasText }
    private func coalesce(marked: Bool, _ edit: @escaping () -> Void) -> Bool {
        guard coalescesTurnOutput else { return false }
        if marked { turnMarkedEdits.append(edit) } else { turnTextEdits.append(edit) }
        if !turnFlushScheduled {
            turnFlushScheduled = true
            DispatchQueue.main.async { [weak self] in self?.flushTurnOutput() }
        }
        return true
    }
    func flushTurnOutput() {
        let edits = turnTextEdits + turnMarkedEdits
        turnTextEdits = []; turnMarkedEdits = []; turnFlushScheduled = false
        edits.forEach { $0() }
    }
    func insertText(_ text: String) {
        onInsert?(text)
        if coalesce(marked: false, { [weak self] in self?.editor.insertText(text) }) { return }
        if defersTextEdits { pendingTextEdits.append { [weak self] in self?.editor.insertText(text) } }
        else { editor.insertText(text) }
    }
    func deleteBackward() {
        backspaces += 1
        if coalesce(marked: false, { [weak self] in self?.editor.deleteBackward() }) { return }
        if defersTextEdits { pendingTextEdits.append { [weak self] in self?.editor.deleteBackward() } }
        else { editor.deleteBackward() }
    }
    func flushTextEdits() { let edits = pendingTextEdits; pendingTextEdits = []; edits.forEach { $0() } }
    func adjustTextPosition(byCharacterOffset offset: Int) {
        if defersCursorMoves { pendingCursorMoves.append(offset); return }
        editor.selectedRange = NSRange(location: max(0, min(editor.text.utf16.count, editor.selectedRange.location + offset)), length: 0)
    }
    func flushCursorMoves() {
        let offsets = pendingCursorMoves; pendingCursorMoves = []
        for offset in offsets {
            editor.selectedRange = NSRange(location: max(0, min(editor.text.utf16.count, editor.selectedRange.location + offset)), length: 0)
        }
    }
    func setMarkedText(_ markedText: String, selectedRange: NSRange) {
        writes += 1
        if coalesce(marked: true, { [weak self] in self?.editor.setMarkedText(markedText, selectedRange: selectedRange); self?.onWrite?() }) { return }
        if defersMarkedEdits { pendingTextEdits.append { [weak self] in self?.editor.setMarkedText(markedText, selectedRange: selectedRange); self?.onWrite?() } }
        else { editor.setMarkedText(markedText, selectedRange: selectedRange); onWrite?() }
    }
    func unmarkText() {
        unmarks += 1
        if coalesce(marked: true, { [weak self] in self?.editor.unmarkText(); self?.onWrite?() }) { return }
        if defersMarkedEdits { pendingTextEdits.append { [weak self] in self?.editor.unmarkText(); self?.onWrite?() } }
        else { editor.unmarkText(); onWrite?() }
    }
}
