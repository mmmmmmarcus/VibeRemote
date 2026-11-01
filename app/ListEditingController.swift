import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// A fresh observation, never a remembered guess about what earlier remote presses did.
struct ListEditingContext {
    enum Structure: Equatable { case paragraph, list, code, unknown }
    let structure: Structure
    let selectionLength: Int
    let spansParagraphs: Bool
    let composing: Bool
}

enum ListEditingDirection { case increase, decrease }

enum ListEditingCommand: Equatable {
    case createList, indent, outdent

    var key: (code: Int, flags: CGEventFlags) {
        switch self {
        case .createList: return (kVK_ANSI_8, [.maskCommand, .maskShift])
        case .indent: return (kVK_Tab, [])
        case .outdent: return (kVK_Tab, .maskShift)
        }
    }

    static func plan(_ direction: ListEditingDirection, context: ListEditingContext) -> Self? {
        guard !context.composing, !context.spansParagraphs else { return nil }
        switch (context.structure, direction) {
        case (.paragraph, .increase): return .createList
        case (.list, .increase): return .indent
        case (.list, .decrease): return .outdent
        default: return nil
        }
    }
}

/// The Codex adapter uses the editor's native commands, preserving text, formatting,
/// selection and undo. Other editors require their own verified command contract.
/// AX reads stay bounded and never write text, move focus, or use the clipboard.
@MainActor
final class ListEditingController {
    static let codexBundleID = "com.openai.codex"
    private var deadline: TimeInterval = 0
    private var fallbackEditor: AXUIElement?
    private var fallbackDepth = 0

    func command(_ direction: ListEditingDirection) -> ListEditingCommand? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier == Self.codexBundleID else {
            rmDebug("📝 List action skipped: unsupported editor; use manual hold")
            return nil
        }
        deadline = ProcessInfo.processInfo.systemUptime + 0.25
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.04)
        guard let focus = element(attribute(application, kAXFocusedUIElementAttribute)),
              let observation = context(focus, application: application),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
              let currentFocus = element(attribute(application, kAXFocusedUIElementAttribute)),
              CFEqual(focus, currentFocus),
              let currentRange = range(attribute(focus, kAXSelectedTextRangeAttribute)),
              currentRange.location == observation.range.location,
              currentRange.length == observation.range.length,
              let currentText = attribute(focus, kAXValueAttribute) as? String,
              currentText == observation.text else {
            rmDebug("📝 List action skipped: inaccessible or changed editor context")
            return nil
        }
        let observedCommand = ListEditingCommand.plan(direction, context: observation.context)
        let command = observedCommand ?? fallbackCommand(
            direction,
            context: observation.context,
            focus: focus
        )
        // Deliberately no text, selected text, window title or document content in logs.
        rmDebug("📝 List context=\(observation.context.structure) selectionLength=\(observation.context.selectionLength) composing=\(observation.context.composing) action=\(command.map { String(describing: $0) } ?? "none")")
        return command
    }

    /// Current Codex builds expose the editor text and selection but may flatten its
    /// ProseMirror paragraph/list descendants into one AX text area. In that case a tap
    /// must remain useful: the first + invokes the native list command, subsequent + taps
    /// in that same focused editor indent, and - walks back out. A real AX observation
    /// always wins and resynchronizes this fallback.
    private func fallbackCommand(
        _ direction: ListEditingDirection,
        context: ListEditingContext,
        focus: AXUIElement
    ) -> ListEditingCommand? {
        guard !context.composing, !context.spansParagraphs else { return nil }
        let sameEditor = fallbackEditor.map { CFEqual($0, focus) } == true
        switch context.structure {
        case .paragraph:
            fallbackEditor = nil
            fallbackDepth = 0
            return direction == .increase ? .createList : nil
        case .list:
            fallbackEditor = focus
            return direction == .increase ? .indent : .outdent
        case .code:
            return nil
        case .unknown:
            switch direction {
            case .increase:
                if sameEditor {
                    fallbackDepth += 1
                    return .indent
                }
                fallbackEditor = focus
                fallbackDepth = 0
                return .createList
            case .decrease:
                // Shift+Tab is Codex's native outdent/remove-list command. It is the
                // requested short-press fallback even for a list created by keyboard.
                if sameEditor, fallbackDepth > 0 {
                    fallbackDepth -= 1
                } else {
                    fallbackEditor = nil
                    fallbackDepth = 0
                }
                return .outdent
            }
        }
    }

    private func context(
        _ focus: AXUIElement,
        application: AXUIElement
    ) -> (context: ListEditingContext, range: CFRange, text: String)? {
        guard attribute(focus, kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole,
              let text = attribute(focus, kAXValueAttribute) as? String,
              let selected = range(attribute(focus, kAXSelectedTextRangeAttribute)),
              let span = Self.paragraphSpan(text: text, selection: selected) else { return nil }
        let composing = attribute(focus, "AXTextInputMarkedTextMarkerRange") != nil
        var structure: ListEditingContext.Structure = .unknown
        // Some editors expose AppKit list attributes; Chromium may expose the list in
        // the AX hierarchy instead. Absence of list attributes alone is not proof of
        // a plain paragraph: a rendered bullet often isn't part of AXValue at all.
        let count = (text as NSString).length
        let probe = min(selected.location, max(0, count - 1))
        if count > 0, let value = axRange(CFRange(location: probe, length: 1)),
           let rich = parameter(focus, kAXAttributedStringForRangeParameterizedAttribute, value) as? NSAttributedString,
           rich.length > 0 {
            let attrs = rich.attributes(at: 0, effectiveRange: nil)
            if attrs[NSAttributedString.Key(kAXListItemLevelTextAttribute.takeUnretainedValue() as String)] != nil ||
                attrs[NSAttributedString.Key(kAXListItemPrefixTextAttribute.takeUnretainedValue() as String)] != nil ||
                (attrs[.paragraphStyle] as? NSParagraphStyle)?.textLists.isEmpty == false {
                structure = .list
            }
        }
        let hierarchy = structureAtCaret(focus, application: application, location: selected.location)
        if hierarchy == .code || structure == .unknown { structure = hierarchy }
        return (ListEditingContext(structure: structure, selectionLength: selected.length,
                                   spansParagraphs: span, composing: composing), selected, text)
    }

    /// UTF-16 is the AX range unit (not Swift Character offsets). A selection extending
    /// across paragraphs needs a separate mixed-list policy; leave it untouched for now.
    static func paragraphSpan(text: String, selection: CFRange) -> Bool? {
        let string = text as NSString
        guard string.length <= 65_536, selection.location >= 0, selection.length >= 0,
              selection.location <= string.length,
              selection.length <= string.length - selection.location else { return nil }
        let selected = string.substring(with: NSRange(location: selection.location, length: selection.length))
        return selected.rangeOfCharacter(from: .newlines) != nil
    }

    private func structureAtCaret(
        _ focus: AXUIElement,
        application: AXUIElement,
        location: Int
    ) -> ListEditingContext.Structure {
        guard let caret = axRange(CFRange(location: location, length: 0)),
              let raw = parameter(focus, kAXBoundsForRangeParameterizedAttribute, caret),
              CFGetTypeID(raw) == AXValueGetTypeID() else { return .unknown }
        let value = unsafeBitCast(raw, to: AXValue.self)
        guard AXValueGetType(value) == .cgRect else { return .unknown }
        var rect = CGRect.zero
        guard AXValueGetValue(value, .cgRect, &rect), rect.height > 0 else { return .unknown }
        // Hit-test only in this editor. Walk back to the exact focused element so a
        // neighbouring pane or an ancestor containing unrelated lists cannot classify it.
        var hit: AXUIElement?
        // AXUIElementCopyElementAtPosition is an application/system-wide hit test. Calling
        // it on the focused text element returns no descendant in Chromium and made every
        // otherwise valid Codex observation look unknown.
        guard AXUIElementCopyElementAtPosition(application, Float(rect.midX), Float(rect.midY), &hit) == .success,
              var current = hit else { return .unknown }
        var path: [(role: String, subrole: String)] = []
        for _ in 0..<16 {
            let role = attribute(current, kAXRoleAttribute) as? String
            let subrole = attribute(current, kAXSubroleAttribute) as? String
            if CFEqual(current, focus) {
                return Self.structure(in: path, reachedEditor: true)
            }
            path.append((role ?? "", subrole ?? ""))
            guard let parent = element(attribute(current, kAXParentAttribute)) else { return .unknown }
            current = parent
        }
        return .unknown
    }

    static func structure(in path: [(role: String, subrole: String)], reachedEditor: Bool) -> ListEditingContext.Structure {
        guard reachedEditor, !path.isEmpty else { return .unknown }
        // Chromium exposes paragraphs/list items as AXGroup on macOS, but preserves
        // AXList ancestors and AXCodeStyleGroup. Do not use localized role descriptions.
        if path.contains(where: { $0.subrole == "AXCodeStyleGroup" || $0.role == "AXCode" }) { return .code }
        if path.contains(where: { $0.role == "AXList" || $0.role == "AXListItem" }) { return .list }
        guard path.contains(where: { ["AXStaticText", "AXParagraph", "AXGroup"].contains($0.role) }) else { return .unknown }
        return .paragraph
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }

    private func parameter(_ element: AXUIElement, _ name: String, _ value: CFTypeRef) -> CFTypeRef? {
        guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, name as CFString, value, &result) == .success else { return nil }
        return result
    }

    private func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func range(_ value: CFTypeRef?) -> CFRange? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let boxed = unsafeBitCast(value, to: AXValue.self)
        guard AXValueGetType(boxed) == .cfRange else { return nil }
        var result = CFRange()
        return AXValueGetValue(boxed, .cfRange, &result) ? result : nil
    }

    private func axRange(_ value: CFRange) -> AXValue? {
        var value = value
        return AXValueCreate(.cfRange, &value)
    }
}
