import UIKit

struct KeyboardTextDestination: Equatable {
    let id: UUID
    let before: String?
    let after: String?
    let selection: String?
    @MainActor init(_ proxy: UITextDocumentProxy) {
        id = KeyboardDocumentIdentity.snapshot(proxy)
        before = proxy.documentContextBeforeInput; after = proxy.documentContextAfterInput
        selection = proxy.selectedText
    }
}

/// Clear through public keyboard editing operations, including text after the caret.
/// Work is bounded and yielded between batches so a new touch/field can cancel it.
@MainActor
final class ClearTextSession {
    enum Outcome: Equatable { case pending, finished, destinationChanged, unavailable }
    private var expected: KeyboardTextDestination
    private var remaining = 20_000
    private let deadline = ProcessInfo.processInfo.systemUptime + 10
    private(set) var isUpdating = false
    init(proxy: UITextDocumentProxy) { expected = KeyboardTextDestination(proxy) }
    func matches(_ proxy: UITextDocumentProxy) -> Bool { expected == KeyboardTextDestination(proxy) }

    func advance(in proxy: UITextDocumentProxy, batchSize: Int = 24) -> Outcome {
        guard matches(proxy) else { return .destinationChanged }
        isUpdating = true
        defer { isUpdating = false; expected = KeyboardTextDestination(proxy) }
        for _ in 0..<batchSize {
            guard KeyboardDocumentIdentity.snapshot(proxy) == expected.id else { return .destinationChanged }
            guard proxy.hasText else { return .finished }
            guard remaining > 0, ProcessInfo.processInfo.systemUptime < deadline else { return .unavailable }
            remaining -= 1
            let before = proxy.documentContextBeforeInput
            let after = proxy.documentContextAfterInput
            guard before != nil || after != nil || proxy.selectedText != nil else { return .unavailable }
            if proxy.selectedText?.isEmpty == false || before?.isEmpty == false {
                proxy.deleteBackward()
            } else if before == "", after == "" {
                // Some editors expose only the current paragraph. Empty context
                // can therefore be a blank line, not the end of the document.
                let prior = KeyboardTextDestination(proxy)
                proxy.deleteBackward()
                guard KeyboardDocumentIdentity.snapshot(proxy) == expected.id else { return .destinationChanged }
                if proxy.hasText, KeyboardTextDestination(proxy) == prior {
                    proxy.adjustTextPosition(byCharacterOffset: 1)
                    guard KeyboardDocumentIdentity.snapshot(proxy) == expected.id else { return .destinationChanged }
                    proxy.deleteBackward()
                }
            } else {
                // Move across the exposed suffix, then delete backwards again.
                // A one-character probe also crosses an empty paragraph boundary.
                let prior = KeyboardTextDestination(proxy)
                proxy.adjustTextPosition(byCharacterOffset: max(1, after?.utf16.count ?? 0))
                guard KeyboardDocumentIdentity.snapshot(proxy) == expected.id else { return .destinationChanged }
                guard KeyboardTextDestination(proxy) != prior else { return .unavailable }
                proxy.deleteBackward()
            }
        }
        return proxy.hasText ? .pending : .finished
    }
}
