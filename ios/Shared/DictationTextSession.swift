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
            id = proxy.documentIdentifier
            before = proxy.documentContextBeforeInput
            after = proxy.documentContextAfterInput
            selection = proxy.selectedText
        }
    }

    let id: UUID
    private var expected: Destination
    private let originalSelection: String?
    private var previousPartial = ""
    private var lastReplyDate = Date.distantPast
    private var ownsMarkedText = false
    private var recordingEnded = false
    private var submitAfterPolish = false
    private var active = true
    private(set) var displayed = ""
    private(set) var isUpdating = false

    init(id: UUID, proxy: UITextDocumentProxy) {
        self.id = id
        expected = Destination(proxy)
        originalSelection = proxy.selectedText
    }

    func matches(_ proxy: UITextDocumentProxy) -> Bool { expected == Destination(proxy) }
    func finishRecording(submitAfterPolish: Bool = false) {
        guard active, !recordingEnded else { return }
        recordingEnded = true
        self.submitAfterPolish = submitAfterPolish
    }

    func receive(_ reply: VoiceReply, in proxy: UITextDocumentProxy, now: Date = Date()) -> Outcome {
        let age = now.timeIntervalSince(reply.updatedAt)
        guard active, reply.id == id, age >= 0, age < 15,
              reply.updatedAt > lastReplyDate else { return .ignored }
        guard matches(proxy) else { active = false; return .destinationChanged }
        lastReplyDate = reply.updatedAt
        if let error = reply.error {
            cancel(in: proxy) // Keep already-visible speech if recognition fails.
            return .failed(error)
        }
        if reply.isFinal {
            let destinationID = expected.id
            replace(with: reply.text, in: proxy, commit: true)
            active = false
            // Use the same public Return operation as the keyboard's Enter key,
            // only after this hold's nonempty final text is committed. A host may
            // treat Return as Send or as a newline; never guess another app's UI.
            if submitAfterPolish, !reply.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               proxy.documentIdentifier == destinationID, matches(proxy) {
                isUpdating = true
                proxy.insertText("\n")
                isUpdating = false
            }
            return .finished
        }
        guard !recordingEnded else { return .ignored }
        let next = StableDictationPreview.growth(shown: displayed, previous: previousPartial, latest: reply.text)
        previousPartial = reply.text
        if next != displayed { replace(with: next, in: proxy, commit: false) }
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
        expected = Destination(proxy)
        isUpdating = false
    }

    private func replace(with text: String, in proxy: UITextDocumentProxy, commit: Bool) {
        // An empty final with no preview must not erase an existing selection.
        guard ownsMarkedText || !text.isEmpty else { return }
        isUpdating = true
        proxy.setMarkedText(text, selectedRange: NSRange(location: text.utf16.count, length: 0))
        if commit { proxy.unmarkText() }
        ownsMarkedText = !commit && !text.isEmpty
        displayed = text
        expected = Destination(proxy)
        isUpdating = false
    }
}
