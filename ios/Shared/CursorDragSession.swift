import UIKit

/// Distance-based movement only: no release momentum or timers that can outlive a touch.
@MainActor
final class CursorDragSession {
    static let characterStride: CGFloat = 8
    static let lineStride: CGFloat = 28
    private var expected: KeyboardTextDestination
    private var point: CGPoint
    private var remainder = CGPoint.zero
    private var preferredColumn: Int?
    private var queuedColumns = 0
    private var queuedLines = 0
    private var pending: (target: KeyboardTextDestination, sentAt: TimeInterval)?
    private(set) var isUpdating = false
    #if DEBUG
    private var verifyLegacyAcknowledgement = false
    func enableLegacyVerification(in proxy: UITextDocumentProxy) {
        verifyLegacyAcknowledgement = true
        expected = Self.observe(proxy)
    }
    #endif

    init(proxy: UITextDocumentProxy, point: CGPoint) {
        expected = Self.observe(proxy); self.point = point
    }
    private static func observe(_ proxy: UITextDocumentProxy) -> KeyboardTextDestination {
        let value = KeyboardTextDestination(proxy)
        // At a document edge iOS commonly returns nil on only the empty side.
        // Both sides absent still means that text context is unavailable.
        return KeyboardTextDestination(id: value.id,
            before: value.before ?? (value.after != nil ? "" : nil),
            after: value.after ?? (value.before != nil ? "" : nil), selection: value.selection)
    }
    static func matchesPress(_ expected: KeyboardTextDestination?, in proxy: UITextDocumentProxy) -> Bool {
        expected?.agreesWithCursorContext(observe(proxy)) == true
    }
    func matches(_ proxy: UITextDocumentProxy) -> Bool {
        let current = Self.observe(proxy)
        return expected.agreesWithCursorContext(current) || pending?.target.agreesWithCursorContext(current) == true
    }

    func move(to next: CGPoint, in proxy: UITextDocumentProxy) -> Bool {
        guard next.x.isFinite, next.y.isFinite, reconcile(in: proxy) else { return false }
        remainder.x += next.x - point.x; remainder.y += next.y - point.y; point = next
        queuedColumns = max(-64, min(64, queuedColumns + steps(&remainder.x, stride: Self.characterStride, limit: 64)))
        queuedLines = max(-4, min(4, queuedLines + steps(&remainder.y, stride: Self.lineStride, limit: 4)))
        return advance(in: proxy)
    }

    /// UIKit's remote proxy may acknowledge a movement on a later run-loop turn.
    /// Serialize commands and keep the touch alive through that acknowledgement.
    @discardableResult func advance(in proxy: UITextDocumentProxy) -> Bool {
        guard reconcile(in: proxy) else { return false }
        guard pending == nil, expected.before != nil, expected.after != nil else { return true }
        isUpdating = true
        defer { isUpdating = false }
        for _ in 0..<5 {
            guard pending == nil else { break }
            let offset: Int
            if queuedColumns != 0 {
                let columns = queuedColumns; queuedColumns = 0; preferredColumn = nil
                let context = (columns < 0 ? expected.before : expected.after) ?? ""
                let text = columns < 0 ? String(context.suffix(-columns)) : String(context.prefix(columns))
                offset = text.utf16.count * (columns < 0 ? -1 : 1)
            } else if queuedLines != 0 {
                let direction = queuedLines < 0 ? -1 : 1; queuedLines -= direction
                offset = lineOffset(direction: direction, proxy: proxy)
                if offset == 0 { queuedLines = 0 }
            } else { break }
            if offset != 0 {
                guard let target = expected.movingCursor(by: offset) else { return false }
                pending = (target, ProcessInfo.processInfo.systemUptime)
                proxy.adjustTextPosition(byCharacterOffset: offset)
                #if DEBUG
                if verifyLegacyAcknowledgement {
                    expected = Self.observe(proxy); pending = nil
                    continue
                }
                #endif
                guard reconcile(in: proxy) else { return false }
            }
        }
        return true
    }

    /// Advance in acknowledged chunks because remote editors expose bounded context.
    /// Return false at the end, on unavailable context, or after any external edit.
    func advanceToEnd(in proxy: UITextDocumentProxy) -> Bool {
        guard reconcile(in: proxy), let after = expected.after else { return false }
        if pending != nil { return advance(in: proxy) }
        guard !after.isEmpty else { return false }
        queuedColumns = min(64, after.count)
        return advance(in: proxy)
    }

    private func reconcile(in proxy: UITextDocumentProxy) -> Bool {
        let current = Self.observe(proxy)
        guard current.id == expected.id else { return false }
        #if DEBUG
        if verifyLegacyAcknowledgement { return current == expected }
        #endif
        // Context is sometimes temporarily absent during host refreshes. Never
        // issue a guessed movement or treat that absence as a new document.
        guard current.before != nil, current.after != nil else { return true }
        if let pending {
            if pending.target.agreesWithCursorContext(current) {
                self.pending = nil; expected = current; return true
            }
            guard expected.agreesWithCursorContext(current) else { return false }
            if ProcessInfo.processInfo.systemUptime - pending.sentAt >= 1 {
                // A host may decline a move at an edge. Drop stale movement, not
                // the held gesture; reversing must still work immediately.
                self.pending = nil; queuedColumns = 0; queuedLines = 0
            }
        } else {
            guard expected.agreesWithCursorContext(current) else { return false }
        }
        expected = current
        return true
    }

    private func steps(_ value: inout CGFloat, stride: CGFloat, limit: Int) -> Int {
        let scaled = value / stride
        let nearest = scaled.rounded()
        // Split layouts have fractional points; 24 pt can arrive as 23.99999999999999.
        let whole = abs(scaled - nearest) < 1e-9 ? nearest : scaled.rounded(.towardZero)
        value -= whole * stride
        // Drop excess at boundaries instead of accumulating movement debt.
        return Int(max(CGFloat(-limit), min(CGFloat(limit), whole)))
    }
    private func lineOffset(direction: Int, proxy: UITextDocumentProxy) -> Int {
        guard let before = expected.before, let after = expected.after else { return 0 }
        let current = lineSuffix(before[...])
        if preferredColumn == nil { preferredColumn = current.count }
        let column = preferredColumn ?? 0
        if direction < 0 {
            let prefix = before.dropLast(current.count)
            guard let newline = prefix.last, newline.isNewline else { return 0 }
            let previous = lineSuffix(prefix.dropLast())
            return -(current.utf16.count + String(newline).utf16.count + previous.dropFirst(min(column, previous.count)).utf16.count)
        }
        let suffix = after.prefix { !$0.isNewline }
        let rest = after.dropFirst(suffix.count)
        guard let newline = rest.first, newline.isNewline else { return 0 }
        let next = rest.dropFirst().prefix { !$0.isNewline }
        return suffix.utf16.count + String(newline).utf16.count + next.prefix(column).utf16.count
    }
    private func lineSuffix(_ text: Substring) -> Substring {
        guard let boundary = text.lastIndex(where: { $0.isNewline }) else { return text }
        return text[text.index(after: boundary)...]
    }
}

private extension KeyboardTextDestination {
    init(id: UUID, before: String?, after: String?, selection: String? = nil) {
        self.id = id; self.before = before; self.after = after; self.selection = selection
    }
    func agreesWithCursorContext(_ other: Self) -> Bool {
        guard id == other.id, selection == other.selection else { return false }
        func agrees(_ a: String?, _ b: String?, preceding: Bool) -> Bool {
            guard let a, let b else { return true }
            if a.isEmpty || b.isEmpty { return a.isEmpty == b.isEmpty }
            // iOS can grow/truncate the exposed context without moving the caret.
            let count = min(32, a.count, b.count)
            return preceding ? a.suffix(count) == b.suffix(count) : a.prefix(count) == b.prefix(count)
        }
        return agrees(before, other.before, preceding: true) && agrees(after, other.after, preceding: false)
    }
    func movingCursor(by offset: Int) -> Self? {
        guard let before, let after else { return nil }
        let text = (before + (selection ?? "") + after) as NSString
        let position = before.utf16.count + offset
        guard position >= 0, position <= text.length else { return nil }
        return Self(id: id, before: text.substring(to: position), after: text.substring(from: position))
    }
}
