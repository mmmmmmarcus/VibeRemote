import UIKit

/// Exact context is deliberately stricter than the cursor/dictation transports:
/// a truncated or moving context window cannot authorize destructive expansion.
struct SnippetDestination: Equatable {
    let document: UUID
    let before: String
    let after: String
    @MainActor static func capture(_ proxy: UITextDocumentProxy, composing: Bool) -> Self? {
        guard !composing, proxy.isSecureTextEntry != true, proxy.selectedText?.isEmpty != false,
              let id = KeyboardDocumentIdentity.read(proxy),
              let before = proxy.documentContextBeforeInput ?? (!proxy.hasText ? "" : nil) else { return nil }
        return Self(document: id, before: before, after: proxy.documentContextAfterInput ?? "")
    }
    func appending(_ text: String) -> Self { Self(document: document, before: before + text, after: after) }
    func deletingASCII() -> Self { Self(document: document, before: String(before.dropLast()), after: after) }
}

/// Serial, single-use prefix transaction. UIKit has no atomic replace-prefix or
/// success receipt. Issue exactly ONE delete, await its exact acknowledgment,
/// then revalidate before any next operation. Never recover/compensate/retry a
/// write. A timeout can leave a partial prefix; it can never justify blind edits.
@MainActor
final class SnippetExpansion {
    private(set) var cancelled = false
    private(set) var expected: SnippetDestination
    private var preceding: SnippetDestination?
    private var awaiting = false
    private var pendingTextChanges = 0
    init(destination: SnippetDestination) { expected = destination }
    func cancel() { cancelled = true }
    func willChange(selection: Bool) {
        // A selection notification is never proof of an owned delete. Cancel
        // before the proxy updates, including between acknowledged writes.
        guard !selection, awaiting else { cancel(); return }
        pendingTextChanges += 1
    }
    func changed(_ current: SnippetDestination?, selection: Bool = false) {
        guard !selection else { cancel(); return }
        pendingTextChanges = max(0, pendingTextChanges - 1)
        guard let current else { cancel(); return }
        // A delayed proxy may still show the pre-write context. This is not an
        // acknowledgment: wait without issuing any further operation.
        if current != expected && !(awaiting && current == preceding) { cancel() }
    }
    func run(token: String, content: String, proxy: UITextDocumentProxy,
             permitted: () -> Bool, composing: () -> Bool) async -> Bool {
        guard token.hasPrefix("@@"), token.count > 2,
              token.dropFirst(2).allSatisfy(SnippetStore.validCharacter), expected.before.hasSuffix(token) else { return false }
        for _ in token.utf8 {
            guard !cancelled, pendingTextChanges == 0, permitted(), SnippetDestination.capture(proxy, composing: composing()) == expected else { return false }
            preceding = expected; expected = expected.deletingASCII(); awaiting = true
            proxy.deleteBackward()
            let deadline = ContinuousClock.now.advanced(by: .milliseconds(600))
            while !cancelled, permitted(), pendingTextChanges != 0 || SnippetDestination.capture(proxy, composing: composing()) != expected {
                guard let current = SnippetDestination.capture(proxy, composing: composing()), current == preceding || current == expected,
                      ContinuousClock.now < deadline else { cancel(); return false }
                do { try await Task.sleep(for: .milliseconds(10)) } catch { cancel(); return false }
            }
            awaiting = false; preceding = nil
            guard !cancelled, permitted() else { return false }
            // Yield between deletes so document/selection/lifecycle callbacks run.
            await Task.yield()
        }
        guard !cancelled, pendingTextChanges == 0, permitted(), SnippetDestination.capture(proxy, composing: composing()) == expected else { return false }
        proxy.insertText(content) // Once, unchanged; there is no general success receipt.
        return true
    }
}

/// An owned raw segment bypasses Pinyin and English correction. Merely finding
/// someone else's @@ in a truncated context is NOT sufficient proof of position.
@MainActor
final class SnippetRawInput {
    private(set) var token = ""
    private(set) var expected: SnippetDestination?
    private var anchor: SnippetDestination?
    private(set) var generation = 0
    func clear() { token = ""; expected = nil; anchor = nil; generation &+= 1 }
    func observe(_ destination: SnippetDestination?) {
        guard let destination, destination == expected || destination == anchor else { clear(); return }
        if destination == expected { anchor = nil }
    }
    func wantsLiteral(_ text: String, at destination: SnippetDestination?) -> Bool {
        guard let destination else { clear(); return false }
        if expected != nil, destination != expected, destination != anchor { clear() }
        if text == "@" { return true }
        return token.hasPrefix("@@") && !text.isEmpty && text.allSatisfy(SnippetStore.validCharacter)
    }
    func inserted(_ text: String, from destination: SnippetDestination) {
        if expected == nil { expected = destination }
        if anchor == nil { anchor = destination }
        if text == "@" {
            token = token == "@" ? "@@" : "@"
        } else { token += text }
        expected = expected?.appending(text); generation &+= 1
    }
    func canDelete(at destination: SnippetDestination?) -> Bool {
        !token.isEmpty && destination != nil && destination == expected
    }
    func deleted(from destination: SnippetDestination) {
        anchor = destination; expected = destination.deletingASCII()
        token = String(token.dropLast()); generation &+= 1
    }
    func matchable(at destination: SnippetDestination?) -> String? {
        guard token.hasPrefix("@@"), token.count > 2, token.dropFirst(2).allSatisfy(SnippetStore.validCharacter),
              destination == expected, destination?.before.hasSuffix(token) == true else { return nil }
        return token
    }
}
