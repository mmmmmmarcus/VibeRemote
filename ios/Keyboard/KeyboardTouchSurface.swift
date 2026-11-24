import UIKit

/// Visible keycaps stay fixed. Every gap inside the key surface belongs to the
/// nearest key in its row, including the full side areas beside A and L.
enum KeyboardHitGeometry {
    static func target(at point: CGPoint, frames: [CGRect]) -> Int? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        var best: (index: Int, vertical: CGFloat, horizontal: CGFloat)?
        for (index, frame) in frames.enumerated() where frame.width > 0 && frame.height > 0 {
            // A deliberate hit always wins, including Delete, Return and switches.
            if frame.contains(point) { return index }
            let dx = max(frame.minX - point.x, 0, point.x - frame.maxX)
            let dy = max(frame.minY - point.y, 0, point.y - frame.maxY)
            // Choose the row first. A far horizontal inset must never select Q
            // or Shift when the finger is level with A (or P/Delete beside L).
            if best == nil || dy < best!.vertical || dy == best!.vertical && dx < best!.horizontal {
                best = (index, dy, dx)
            }
        }
        return best?.index
    }
}

final class KeyboardTouchSurface: UIView {
    var controls: [UIControl] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "keyboard.key-surface"
        // The remote keyboard host skips completely unpainted gaps before our
        // hitTest runs. A visually imperceptible fill gives the whole surface
        // an event region while retaining the system's translucent backdrop.
        // Keep view alpha at 1; only the background color is nearly transparent.
        backgroundColor = UIColor.white.withAlphaComponent(0.001)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func target(at point: CGPoint) -> UIControl? {
        guard bounds.contains(point) else { return nil }
        let available = controls.filter { control in
            guard control.isEnabled, control.isDescendant(of: self) else { return false }
            var ancestor: UIView? = control
            while let item = ancestor, item !== self {
                if item.isHidden || item.alpha <= 0.01 { return false }
                ancestor = item.superview
            }
            return true
        }
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
    let quietFeedback = QuietKeyFeedback()
    private var dictating = false
    func setDictating(_ active: Bool, animated: Bool = true) {
        quietFeedback.setRecording(active, dimBase: true, mini: false)
        if !active { quietFeedback.reset(animated: animated) }
        guard dictating != active else { return }; dictating = active
        let update = { self.subviews.compactMap { $0 as? UIImageView }.forEach { $0.alpha = active ? 0 : 1 } }
        if animated, window != nil, !UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: 0.12, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: update)
        } else { update() }
    }
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard let touchSurface else { return super.point(inside: point, with: event) }
        return touchSurface.target(at: convert(point, to: touchSurface)) === self
    }
}
