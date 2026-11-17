import Foundation

/// Delete has no voice action. Swiping only arms after the initial hold delay.
struct DeleteGesture {
    enum Action: Equatable { case delete, clearAll }
    static let holdDelay = 0.38
    static let repeatInterval = 0.08
    static let swipeDistance = 60.0
    private var startedAt: TimeInterval?
    private var nextRepeat: TimeInterval = 0
    private var origin = CGPoint.zero
    private(set) var isHolding = false
    private(set) var didClear = false

    mutating func press(at time: TimeInterval, point: CGPoint) {
        startedAt = time; nextRepeat = time + Self.holdDelay
        origin = point; isHolding = false; didClear = false
    }
    mutating func advance(to time: TimeInterval) -> Action? {
        guard startedAt != nil, !didClear, time >= nextRepeat else { return nil }
        isHolding = true
        // No catch-up bursts after a stalled main run loop.
        nextRepeat = time + Self.repeatInterval
        return .delete
    }
    mutating func move(to point: CGPoint, at time: TimeInterval) -> Action? {
        guard let startedAt, !didClear, time - startedAt >= Self.holdDelay,
              origin.x - point.x >= Self.swipeDistance, abs(point.y - origin.y) <= 40 else { return nil }
        isHolding = true; didClear = true
        return .clearAll
    }
    mutating func release() -> Action? {
        let action: Action? = startedAt != nil && !isHolding && !didClear ? .delete : nil
        cancel()
        return action
    }
    mutating func cancel() { startedAt = nil; isHolding = false; didClear = false }
}
