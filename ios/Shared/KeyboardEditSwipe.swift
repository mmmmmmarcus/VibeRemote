import Foundation

enum KeyboardEditSwipe: String {
    case deleteWord = "editing.deleteWord"
    case restoreWord = "editing.restoreWord"
    case endOfText = "editing.endOfText"
    case lineBreak = "editing.lineBreak"

    static func action(for delta: CGPoint) -> Self? {
        guard delta.x.isFinite, delta.y.isFinite else { return nil }
        if abs(delta.x) >= 36, abs(delta.x) > abs(delta.y) * 1.25 {
            return delta.x < 0 ? .deleteWord : .restoreWord
        }
        if delta.y <= -28, -delta.y > abs(delta.x) * 1.25 { return .endOfText }
        if delta.y >= 28, delta.y > abs(delta.x) * 1.25 { return .lineBreak }
        return nil
    }
    static func begins(at delta: CGPoint) -> Bool {
        // Do not create a dead band where a tap is cancelled but no swipe can
        // succeed. A deliberate unsupported direction can still abandon a tap.
        delta.x.isFinite && delta.y.isFinite && (action(for: delta) != nil || hypot(delta.x, delta.y) >= 36)
    }
}
