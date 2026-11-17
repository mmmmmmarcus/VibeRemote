import UIKit

/// Visible keycaps stay fixed. Nearby whitespace belongs to the closest key edge.
/// Bounded reach leaves split-keyboard centers and accessory spacers untargeted.
enum KeyboardHitGeometry {
    static func target(at point: CGPoint, frames: [CGRect]) -> Int? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        var best: (index: Int, distance: CGFloat)?
        for (index, frame) in frames.enumerated() where frame.width > 0 && frame.height > 0 {
            // A deliberate hit always wins, including Delete, Return and switches.
            if frame.contains(point) { return index }
            let dx = max(frame.minX - point.x, 0, point.x - frame.maxX)
            let dy = max(frame.minY - point.y, 0, point.y - frame.maxY)
            guard dx <= 14, dy <= 10 else { continue }
            let distance = dx * dx + dy * dy
            if best == nil || distance < best!.distance { best = (index, distance) }
        }
        return best?.index
    }
}

final class KeyboardTouchSurface: UIView {
    var controls: [UIControl] = []

    func target(at point: CGPoint) -> UIControl? {
        guard bounds.contains(point) else { return nil }
        let available = controls.filter { $0.isEnabled && !$0.isHidden && $0.alpha > 0.01 && $0.isDescendant(of: self) }
        let frames = available.map { $0.convert($0.bounds, to: self) }
        if let direct = frames.firstIndex(where: { $0.contains(point) }) { return available[direct] }
        // Native keyboard-picker gestures belong to its keycap. Ordinary gaps
        // use a KeyControl so a hold can dictate without pressing that function.
        let gapControls = available.filter { ($0 as? KeyControl)?.onGapHold != nil }
        if !gapControls.isEmpty {
            let gapFrames = gapControls.map { $0.convert($0.bounds, to: self) }
            guard let index = KeyboardHitGeometry.target(at: point, frames: gapFrames) else { return nil }
            return gapControls[index]
        }
        guard let index = KeyboardHitGeometry.target(at: point, frames: frames) else { return nil }
        return available[index]
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01 else { return nil }
        return target(at: point)
    }
}

/// UIButton's tracking must use the same ownership rule as the surrounding keys.
final class KeyboardSwitcherButton: UIButton {
    weak var touchSurface: KeyboardTouchSurface?
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard let touchSurface else { return super.point(inside: point, with: event) }
        return touchSurface.target(at: convert(point, to: touchSurface)) === self
    }
}
