import UIKit

@MainActor protocol CodeClipboard {
    var changeCount: Int { get }
    var text: String? { get }
}

@MainActor struct SystemCodeClipboard: CodeClipboard {
    var changeCount: Int { UIPasteboard.general.changeCount }
    var text: String? { UIPasteboard.general.string }
}

/// Stores clipboard version/expiry metadata only, never text or a code.
@MainActor final class CopiedCodeMonitor {
    var onObservedText: ((String) -> Void)?
    private struct State: Codable {
        let changeCount: Int
        let bootTime: TimeInterval
        var expiresAt: Date?
    }
    private static let preferenceKey = "keyboard.copiedCodeMetadata"
    private let clipboard: any CodeClipboard
    private let defaults: UserDefaults?
    private let now: () -> Date
    private let bootTime: () -> TimeInterval
    private var state: State?

    init(clipboard: (any CodeClipboard)? = nil, defaults: UserDefaults? = .standard,
         now: @escaping () -> Date = Date.init,
         bootTime: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime }) {
        self.clipboard = clipboard ?? SystemCodeClipboard(); self.defaults = defaults; self.now = now; self.bootTime = bootTime
        if let data = defaults?.data(forKey: Self.preferenceKey) {
            state = try? JSONDecoder().decode(State.self, from: data)
        }
    }
    var isAvailable: Bool { state?.expiresAt.map { now() < $0 } == true }

    /// Called only while the keyboard is visible and idle. A new installation or
    /// reboot establishes a baseline; existing clipboard contents are not new.
    func refresh() {
        let count = clipboard.changeCount, boot = bootTime()
        guard let previous = state, abs(previous.bootTime - boot) < 5 else {
            state = State(changeCount: count, bootTime: boot); save(); return
        }
        guard count != previous.changeCount else {
            if state?.expiresAt != nil, !isAvailable { consume() }
            return
        }
        state = State(changeCount: count, bootTime: boot)
        save() // Mark this version attempted before a possible system permission prompt.
        guard count > previous.changeCount else { return }
        let text = clipboard.text
        guard clipboard.changeCount == count, state?.changeCount == count,
              let text else { return }
        onObservedText?(text)
        guard VerificationCode.extract(from: text) != nil else { return }
        state?.expiresAt = now().addingTimeInterval(120)
        save()
    }

    /// Re-read on the explicit tap; never paste a retained code or a changed item.
    func takeCode() -> String? {
        guard let expected = state, isAvailable,
              abs(expected.bootTime - bootTime()) < 5,
              clipboard.changeCount == expected.changeCount else { consume(); return nil }
        consume()
        guard let text = clipboard.text, clipboard.changeCount == expected.changeCount else { return nil }
        return VerificationCode.extract(from: text)
    }
    func consume() { state?.expiresAt = nil; save() }
    private func save() {
        if let state, let data = try? JSONEncoder().encode(state) { defaults?.set(data, forKey: Self.preferenceKey) }
    }
}
