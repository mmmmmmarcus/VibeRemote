import AppKit
import ApplicationServices

/// Auto Computer Use (2026-11-13, user's request): with the switch on, a Siri dictation hold
/// first asks whether a text field has the keyboard focus. If one does, the hold dictates into
/// it as usual. If none does, the hold opens Computer Use instead, its words fill the bar while
/// Siri is held, and on release the polished transcript (the refined result after filler
/// cleanup and the dictionary) is sent as the command.
enum AutoComputerUse {
    static let enabledKey = "autoComputerUse"

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// What the probe found focused. Only editable text that takes a caret counts: a text area,
    /// a text field (search fields included) or a combo box whose selection can be read.
    static func isTextInput(role: String?, hasSelection: Bool) -> Bool {
        guard let role, hasSelection else { return false }
        return [kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole].contains(role)
    }

    /// Asks the frontmost app's focused element off the main thread (bounded AX timeouts, so a
    /// busy app cannot stall the remote) and answers on the main thread. It asks the app itself
    /// rather than the system-wide element, which fails at once in ChatGPT (see CaretAXQuery).
    @MainActor
    static func probeFocusedTextInput(_ completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            completion(false); return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let found = focusedTextInput(pid: pid)
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(found) } }
        }
    }

    private static func focusedTextInput(pid: pid_t) -> Bool {
        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
        }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.1)
        guard let raw = attribute(application, kAXFocusedUIElementAttribute),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return false }
        let element = unsafeBitCast(raw, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, 0.1)
        let role = attribute(element, kAXRoleAttribute) as? String
        let selection = attribute(element, kAXSelectedTextRangeAttribute)
        return isTextInput(role: role, hasSelection: selection.map { CFGetTypeID($0) == AXValueGetTypeID() } ?? false)
    }
}

/// How a dictation hold reaches the Computer Use bar. The app delegate supplies it, since the
/// bar belongs to its `AgentPanelController`; `DictationController` only calls it.
@MainActor
struct ComputerUseHandoff {
    /// The bar is up, focused and waiting for a command: dictate straight into it.
    let isComposing: () -> Bool
    /// A command is running; a new one cannot start, so the hold dictates as usual.
    let isBusy: () -> Bool
    /// What the bar already holds, so dictation adds to it.
    let text: () -> String
    let open: () -> Void
    let show: (String) -> Void
    let submit: (String) -> Void
}
