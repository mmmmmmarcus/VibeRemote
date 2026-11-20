import UIKit
import NaturalLanguage

enum WordDeletion {
    /// Include trailing spaces/punctuation, while keeping grapheme clusters whole.
    static func suffix(in before: String) -> String? {
        guard !before.isEmpty else { return nil }
        let text = String(before.suffix(512))
        let spaceCount = text.reversed().prefix { $0.isWhitespace && !$0.isNewline }.count
        let spaces = text.suffix(spaceCount)
        let body = text.dropLast(spaces.count)
        guard let last = body.last else { return spaces.count <= 128 ? String(spaces) : nil }
        if last.isNewline { return String(last) + String(spaces) }
        let tokenizer = NLTokenizer(unit: .word)
        var lastWord: Range<String.Index>?
        let words = String(body)
        tokenizer.string = words
        tokenizer.enumerateTokens(in: words.startIndex..<words.endIndex) { range, _ in lastWord = range; return true }
        let deletion: String
        if let lastWord {
            let afterSpace = words.lastIndex(where: { $0.isWhitespace }).map { words.index(after: $0) } ?? words.startIndex
            deletion = String(words[max(lastWord.lowerBound, afterSpace)...]) + String(spaces)
        } else { deletion = String(last) + String(spaces) }
        return deletion.count <= 128 ? deletion : nil
    }
}

/// In-memory, bounded undo for swipe deletions only. Other editing/field changes
/// discard it. The proxy can acknowledge a command on a later run-loop turn.
@MainActor final class WordEditingSession {
    private struct Context {
        let id: UUID
        let before: String
        let after: String
        @MainActor init?(_ proxy: UITextDocumentProxy) {
            guard proxy.selectedText?.isEmpty != false,
                  proxy.documentContextBeforeInput != nil || proxy.documentContextAfterInput != nil || !proxy.hasText else { return nil }
            id = KeyboardDocumentIdentity.snapshot(proxy)
            before = proxy.documentContextBeforeInput ?? ""; after = proxy.documentContextAfterInput ?? ""
        }
        init(id: UUID, before: String, after: String) { self.id = id; self.before = before; self.after = after }
        func matches(_ other: Self) -> Bool {
            guard id == other.id else { return false }
            func same(_ a: String, _ b: String, before: Bool) -> Bool {
                if a.isEmpty || b.isEmpty { return a.isEmpty == b.isEmpty }
                let count = min(32, a.count, b.count)
                return before ? a.suffix(count) == b.suffix(count) : a.prefix(count) == b.prefix(count)
            }
            return same(before, other.before, before: true) && same(after, other.after, before: false)
        }
    }
    private var deleted: [String] = []
    private var expected: Context?
    private var pendingOrigin: Context?
    private var pendingUntil: TimeInterval = 0
    private(set) var isUpdating = false
    var hasPendingEdit: Bool { pendingOrigin != nil }
    var hasTrackedContext: Bool { expected != nil }
    func clear() { deleted = []; expected = nil; pendingOrigin = nil }
    @discardableResult func observe(_ proxy: UITextDocumentProxy) -> Bool {
        guard !isUpdating, let expected else { return true }
        guard let current = Context(proxy) else { clear(); return false }
        if expected.matches(current) { self.expected = current; pendingOrigin = nil; return true }
        if let pendingOrigin, pendingOrigin.matches(current), ProcessInfo.processInfo.systemUptime < pendingUntil { return false }
        clear(); return false
    }
    @discardableResult func deleteWord(in proxy: UITextDocumentProxy) -> Bool {
        guard observe(proxy), let origin = Context(proxy), let text = WordDeletion.suffix(in: origin.before) else { return false }
        expected = Context(id: origin.id, before: String(origin.before.dropLast(text.count)), after: origin.after)
        pendingOrigin = origin; pendingUntil = ProcessInfo.processInfo.systemUptime + 1
        deleted.append(text); if deleted.count > 10 { deleted.removeFirst() }
        isUpdating = true
        for _ in text {
            guard KeyboardDocumentIdentity.snapshot(proxy) == origin.id else { isUpdating = false; clear(); return false }
            proxy.deleteBackward()
        }
        isUpdating = false; observe(proxy)
        return true
    }
    @discardableResult func restoreWord(in proxy: UITextDocumentProxy) -> Bool {
        guard observe(proxy), let origin = Context(proxy), let text = deleted.popLast() else { return false }
        expected = Context(id: origin.id, before: origin.before + text, after: origin.after)
        pendingOrigin = origin; pendingUntil = ProcessInfo.processInfo.systemUptime + 1
        isUpdating = true; proxy.insertText(text); isUpdating = false
        observe(proxy)
        return true
    }
}
