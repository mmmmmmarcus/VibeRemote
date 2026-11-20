import UIKit

/// Owns only one hold's marked span in one editor. Interim speech stays in that
/// span until the polished result replaces it; unrelated text is never deleted.
@MainActor
final class DictationTextSession {
    enum Outcome: Equatable {
        case ignored, partial, finished, destinationChanged
        case failed(String)
    }
    private struct Destination: Equatable {
        let id: UUID
        let before: String?
        let after: String?
        let selection: String?
        @MainActor init(_ proxy: UITextDocumentProxy) {
            id = KeyboardDocumentIdentity.snapshot(proxy)
            let before = proxy.documentContextBeforeInput, after = proxy.documentContextAfterInput
            self.before = before ?? (after != nil || !proxy.hasText ? "" : nil)
            self.after = after ?? (before != nil || !proxy.hasText ? "" : nil)
            selection = proxy.selectedText
        }
        init(id: UUID, before: String, after: String?) {
            self.id = id; self.before = before; self.after = after; selection = nil
        }
        func acknowledges(_ target: Self) -> Bool {
            guard id == target.id, selection == target.selection else { return false }
            func agrees(_ actual: String?, _ predicted: String?, suffix: Bool) -> Bool {
                guard let actual, let predicted else { return actual == predicted }
                if actual.isEmpty || predicted.isEmpty { return actual.isEmpty == predicted.isEmpty }
                let count = min(actual.count, predicted.count)
                return suffix ? actual.suffix(count) == predicted.suffix(count) : actual.prefix(count) == predicted.prefix(count)
            }
            return agrees(before, target.before, suffix: true) && agrees(after, target.after, suffix: false)
        }
    }

    let id: UUID
    private var expected: Destination
    private let compositionAnchor: Destination?
    private var pendingWrite: Destination?
    private var pendingWriteYielded = false
    private var writeGeneration = 0
    private var awaitingFinalCommit = false
    private let originalSelection: String?
    private var previousPartial = ""
    private var lastReplyDate = Date.distantPast
    private var ownsMarkedText = false
    private var recordingEnded = false
    private var submitAfterPolish = false
    private var active = true
    private(set) var displayed = ""
    private(set) var isUpdating = false
    private(set) var needsManualSend = false
    #if DEBUG
    func verificationState(in proxy: UITextDocumentProxy) -> [String: Int] {
        let current = Destination(proxy)
        return ["before": current.before?.count ?? -1, "after": current.after?.count ?? -1,
                "selection": current.selection?.count ?? -1, "expectedBefore": expected.before?.count ?? -1,
                "expectedAfter": expected.after?.count ?? -1, "expectedSelection": expected.selection?.count ?? -1,
                "pendingBefore": pendingWrite?.before?.count ?? -1, "displayed": displayed.count,
                "sameDocument": current.id == expected.id ? 1 : 0, "sameContext": current == expected ? 1 : 0,
                "active": active ? 1 : 0, "awaitingFinal": awaitingFinalCommit ? 1 : 0]
    }
    #endif

    init(id: UUID, proxy: UITextDocumentProxy) {
        self.id = id
        let destination = Destination(proxy)
        expected = destination
        compositionAnchor = destination.before.map { Destination(id: destination.id, before: $0, after: destination.after) }
        originalSelection = proxy.selectedText
    }

    func matches(_ proxy: UITextDocumentProxy) -> Bool {
        var current = Destination(proxy)
        // An initially empty field contains text after our first marked write,
        // but the remote proxy excludes that marked span and returns nil on
        // BOTH sides. Normalize only this known-empty, still-owned destination;
        // unknown/hidden context in another or previously nonempty field fails.
        if (ownsMarkedText || pendingWrite != nil), current.before == nil, current.after == nil,
           current.selection == nil, let anchor = compositionAnchor,
           anchor.before == "", anchor.after == "", current.id == anchor.id {
            current = anchor
        }
        if let pendingWrite, current.acknowledges(pendingWrite) {
            expected = current; self.pendingWrite = nil
            return true
        }
        // Real iOS proxies can expose only context OUTSIDE the marked span,
        // unlike a local UITextView proxy. The unchanged composition anchor is
        // still the same destination; it must not be mistaken for a stale edit.
        if ownsMarkedText, current == compositionAnchor {
            expected = current
            if pendingWriteYielded { pendingWrite = nil }
            return true
        }
        return current == expected
    }
    func finishRecording(submitAfterPolish: Bool = false) {
        guard active, !recordingEnded else { return }
        recordingEnded = true
        self.submitAfterPolish = submitAfterPolish
    }

    func receive(_ reply: VoiceReply, in proxy: UITextDocumentProxy, now: Date = Date()) -> Outcome {
        let age = now.timeIntervalSince(reply.updatedAt)
        guard active, reply.id == id, age >= 0, age < 15 else { return .ignored }
        guard matches(proxy) else { active = false; return .destinationChanged }
        // Separate replacement and unmarking across the remote editor boundary.
        // Accept an exact acknowledgement, or the same outside-marked context
        // on a later main-loop turn. Polling the final reply completes the commit.
        if awaitingFinalCommit {
            guard pendingWrite == nil else { return .partial }
            return commitFinal(in: proxy)
        }
        guard pendingWrite == nil, reply.updatedAt > lastReplyDate else { return .ignored }
        lastReplyDate = reply.updatedAt
        if let error = reply.error {
            cancel(in: proxy) // Keep already-visible speech if recognition fails.
            return .failed(error)
        }
        if reply.isFinal {
            replaceFinal(with: reply.text, in: proxy)
            guard matches(proxy) else { active = false; return .destinationChanged }
            awaitingFinalCommit = true
            return pendingWrite == nil ? commitFinal(in: proxy) : .partial
        }
        if reply.polishing == true {
            replace(with: reply.text, in: proxy)
            return .partial
        }
        guard !recordingEnded else { return .ignored }
        let next = StableDictationPreview.growth(shown: displayed, previous: previousPartial, latest: reply.text)
        previousPartial = reply.text
        if next != displayed { replace(with: next, in: proxy) }
        return .partial
    }

    /// Explicit slide-to-cancel restores the selection displaced by this hold.
    /// Typing, timeout and dismissal preserve visible speech; a changed editor is untouched.
    func cancel(in proxy: UITextDocumentProxy, discard: Bool = false) {
        guard active else { return }
        active = false
        guard ownsMarkedText, matches(proxy) else { return }
        isUpdating = true
        if discard {
            let restored = originalSelection ?? ""
            proxy.setMarkedText(restored, selectedRange: NSRange(location: 0, length: restored.utf16.count))
        }
        proxy.unmarkText()
        ownsMarkedText = false
        pendingWrite = nil; awaitingFinalCommit = false
        writeGeneration += 1
        expected = Destination(proxy)
        isUpdating = false
    }

    private func commitFinal(in proxy: UITextDocumentProxy) -> Outcome {
        let destinationID = expected.id
        isUpdating = true
        ownsMarkedText = false; awaitingFinalCommit = false; active = false
        // Return follows the acknowledged final replacement, never the stale draft.
        if submitAfterPolish, !displayed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           KeyboardDocumentIdentity.snapshot(proxy) == destinationID, matches(proxy) {
            if proxy.returnKeyType == .send { proxy.insertText("\n") }
            else { needsManualSend = true }
        }
        isUpdating = false
        return .finished
    }

    private func replaceFinal(with text: String, in proxy: UITextDocumentProxy) {
        guard ownsMarkedText || !text.isEmpty else { return }
        isUpdating = true
        pendingWrite = compositionAnchor.flatMap { anchor in
            anchor.before.map { Destination(id: anchor.id, before: $0 + text, after: anchor.after) }
        }
        writeGeneration += 1; pendingWriteYielded = false
        // A normal insertion replaces the current marked span and commits plain
        // text. setMarkedText(final) + unmarkText can leave its blue styling on
        // the real host editor even after markedTextRange becomes nil.
        if text.isEmpty { proxy.setMarkedText("", selectedRange: NSRange(location: 0, length: 0)) }
        else { proxy.insertText(text) }
        proxy.unmarkText()
        ownsMarkedText = false; displayed = text
        if pendingWrite != nil { _ = matches(proxy) }
        else { expected = Destination(proxy) }
        isUpdating = false
    }

    private func replace(with text: String, in proxy: UITextDocumentProxy) {
        // An empty final with no preview must not erase an existing selection.
        guard ownsMarkedText || !text.isEmpty else { return }
        // An unchanged final only needs unmarkText, not another marked write.
        guard !ownsMarkedText || text != displayed else { return }
        isUpdating = true
        pendingWrite = compositionAnchor.flatMap { anchor in
            anchor.before.map { Destination(id: anchor.id, before: $0 + text, after: anchor.after) }
        }
        pendingWriteYielded = false; writeGeneration += 1
        let generation = writeGeneration
        Task { @MainActor [weak self] in
            guard let self, self.active, self.writeGeneration == generation else { return }
            self.pendingWriteYielded = true
        }
        proxy.setMarkedText(text, selectedRange: NSRange(location: text.utf16.count, length: 0))
        ownsMarkedText = true
        displayed = text
        if pendingWrite != nil { _ = matches(proxy) }
        else { expected = Destination(proxy) }
        isUpdating = false
    }
}
