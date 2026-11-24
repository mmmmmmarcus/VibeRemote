import UIKit
import UIKit.UIGestureRecognizerSubclass

struct KeyboardModePinch {
    enum Direction { case inward, outward }
    static let pairingGrace: TimeInterval = 0.25
    private(set) var recognizedDirection: Direction?

    /// Count a brief head start, never movement from an earlier held key.
    static func pairOrigins(initial: [CGPoint], current: [CGPoint], stagger: TimeInterval) -> [CGPoint] {
        stagger >= 0 && stagger <= pairingGrace ? initial : current
    }
    private static func distance(_ points: [CGPoint]) -> CGFloat? {
        guard points.count == 2, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        let distance = hypot(points[1].x - points[0].x, points[1].y - points[0].y)
        return distance.isFinite ? distance : nil
    }
    static func separationChange(from origins: [CGPoint], to locations: [CGPoint]) -> CGFloat? {
        guard let initial = distance(origins), initial > 0, let current = distance(locations) else { return nil }
        return current - initial
    }
    static func direction(from origins: [CGPoint], to locations: [CGPoint]) -> Direction? {
        guard let initial = distance(origins), let change = separationChange(from: origins, to: locations) else { return nil }
        // Small pinches work on mini's short surface; a wide thumb span does not
        // require a huge movement. Translation/rotation at constant span do nothing.
        let threshold = max(12, min(24, initial * 0.08))
        guard abs(change) >= threshold else { return nil }
        return change < 0 ? .inward : .outward
    }
    /// Recognize during movement and consume the rest of this finger pair.
    mutating func advance(from origins: [CGPoint], to locations: [CGPoint]) -> Direction? {
        guard recognizedDirection == nil, let direction = Self.direction(from: origins, to: locations) else { return nil }
        recognizedDirection = direction
        return direction
    }
}

/// Captures a two-finger chord before key rollover can insert text. Stationary,
/// brief overlaps can be replayed as ordinary taps in their original press order.
final class KeyboardModeGesture: UIGestureRecognizer {
    var onPair: (([CGPoint]) -> Void)?
    var onChange: ((CGFloat) -> Void)?
    var onFinish: ((KeyboardModePinch.Direction?, Bool, CGFloat) -> Void)?
    private var fingers: [UITouch] = []
    private var origins: [CGPoint] = []
    private var locations: [CGPoint] = []
    private var pairedAt: TimeInterval = 0
    private var firstBeganAt: TimeInterval = 0
    private var paired = false
    private var lastChange: CGFloat = 0
    private var lastMoveAt: TimeInterval = 0
    private var velocity: CGFloat = 0

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = true; delaysTouchesBegan = false; delaysTouchesEnded = false
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard state == .possible else {
            if paired { finish(cancelled: true) }
            return
        }
        for touch in touches.sorted(by: { $0.timestamp < $1.timestamp }) {
            var ancestor = touch.view
            var startsOnKeys = false
            while let item = ancestor {
                // Leave candidate browsing, helper actions and the native picker
                // to their own controls. Pinches begin on the key surface only.
                if item is CandidatePanel || item is KeyboardSwitcherButton { state = .failed; return }
                if item is KeyboardTouchSurface { startsOnKeys = true; break }
                ancestor = item.superview
            }
            guard startsOnKeys else { state = .failed; return }
            if fingers.isEmpty { firstBeganAt = touch.timestamp }
            fingers.append(touch); origins.append(touch.location(in: view)); locations.append(touch.location(in: view))
        }
        guard fingers.count <= 2 else { state = .failed; return }
        if fingers.count == 2 {
            locations = fingers.map { $0.location(in: view) }
            origins = KeyboardModePinch.pairOrigins(initial: origins, current: locations,
                                                    stagger: event.timestamp - firstBeganAt)
            paired = true; pairedAt = ProcessInfo.processInfo.systemUptime
            lastMoveAt = event.timestamp; lastChange = 0; velocity = 0
            onPair?(locations)
            state = .began
        }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        update(touches)
        if paired {
            let change = KeyboardModePinch.separationChange(from: origins, to: locations) ?? 0
            let dt = event.timestamp - lastMoveAt
            if dt > 0 { velocity = (change-lastChange) / CGFloat(dt) }
            lastMoveAt = event.timestamp; lastChange = change
            onChange?(change); state = .changed
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        update(touches)
        if paired { finish(cancelled: false) }
        else { state = .failed }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        if paired { finish(cancelled: true) } else { state = .failed }
    }
    private func update(_ touches: Set<UITouch>) {
        for touch in touches {
            if let index = fingers.firstIndex(of: touch) { locations[index] = touch.location(in: view) }
        }
    }
    private func finish(cancelled: Bool) {
        let deltas = zip(locations, origins).map { CGPoint(x: $0.x - $1.x, y: $0.y - $1.y) }
        let direction = cancelled ? nil : KeyboardModePinch.direction(from: origins, to: locations)
        let taps = !cancelled && direction == nil && ProcessInfo.processInfo.systemUptime - pairedAt < 0.35 && deltas.allSatisfy { hypot($0.x, $0.y) < 12 }
        paired = false
        let recentVelocity = !cancelled && ProcessInfo.processInfo.systemUptime-lastMoveAt < 0.12 ? velocity : 0
        onFinish?(direction, taps, recentVelocity)
        state = cancelled ? .cancelled : .ended
    }
    override func reset() {
        if paired { onFinish?(nil, false, 0) }
        fingers = []; origins = []; locations = []; paired = false
        velocity = 0; lastChange = 0
        super.reset()
    }
}
