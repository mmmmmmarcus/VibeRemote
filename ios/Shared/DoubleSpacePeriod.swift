import UIKit

/// Own only the first explicit Space, in this exact field/caret, for 450 ms.
@MainActor final class DoubleSpacePeriod {
    private var expected: KeyboardTextDestination?
    private var timestamp: TimeInterval = 0
    func reset() { expected = nil }
    func replaceIfMatching(in proxy: UITextDocumentProxy, language: KeyboardLanguage,
                           now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        defer { reset() }
        guard now - timestamp >= 0, now - timestamp <= 0.45,
              expected == KeyboardTextDestination(proxy), proxy.selectedText?.isEmpty != false,
              let before = proxy.documentContextBeforeInput, before.last == " ",
              let last = before.dropLast().last, last.isLetter || last.isNumber,
              ![UIKeyboardType.URL, .emailAddress, .numberPad, .phonePad, .decimalPad].contains(proxy.keyboardType ?? .default),
              proxy.textContentType != .oneTimeCode else { return false }
        proxy.deleteBackward(); proxy.insertText(language == .chinese ? "。" : ". ")
        return true
    }
    func remember(in proxy: UITextDocumentProxy, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard proxy.documentContextBeforeInput?.last == " " else { reset(); return }
        expected = KeyboardTextDestination(proxy); timestamp = now
    }
}
