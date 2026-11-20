import UIKit
#if KEYBOARD_TESTING
@testable import vvhisper
#endif

/// Only paints inside a keycap. Core Animation interpolates bounded meter
/// updates; there is no frame timer, drawing loop, hit target or accessibility item.
@MainActor final class QuietKeyFeedback: UIView {
    private let shade = CALayer()
    private let light = CAGradientLayer()
    private var recording = false
    private var dimBase = false
    private var mini = false
    private var level = 0.0
    private var position = 0.5
    private var suppressed = false
    private(set) var brightness = 0.0
    private(set) var baseOpacity = 1.0
    var reducedMotionOverride: Bool?
    private var reducedMotion: Bool { reducedMotionOverride ?? UIAccessibility.isReduceMotionEnabled }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false; isAccessibilityElement = false
        accessibilityElementsHidden = true; isOpaque = false; clipsToBounds = true
        layer.addSublayer(shade); layer.addSublayer(light)
        shade.backgroundColor = UIColor.black.cgColor
        shade.opacity = 0; light.opacity = 0
        light.startPoint = CGPoint(x: 0, y: 0.5); light.endPoint = CGPoint(x: 1, y: 0.5)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) { (view: QuietKeyFeedback, _: UITraitCollection) in view.render(animated: false) }
        NotificationCenter.default.addObserver(self, selector: #selector(motionChanged), name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    isolated deinit { NotificationCenter.default.removeObserver(self) }
    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        shade.frame = bounds; light.bounds = bounds; light.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
        layer.cornerRadius = superview?.layer.cornerRadius ?? 0; layer.cornerCurve = .continuous
        if let cap = superview?.layer {
            cap.shadowColor = UIColor.white.cgColor; cap.shadowRadius = 6; cap.shadowOffset = .zero
            cap.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: cap.cornerRadius).cgPath
        }
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { shade.removeAllAnimations(); light.removeAllAnimations() }
    }
    @objc private func motionChanged() { render(animated: false) }
    func setRecording(_ recording: Bool, dimBase: Bool, mini: Bool) {
        guard self.recording != recording || self.dimBase != dimBase || self.mini != mini else { return }
        self.recording = recording; self.dimBase = dimBase; self.mini = mini
        render(animated: true)
    }
    func setLevel(_ level: Double, position: Double) {
        guard self.level != level || self.position != position else { return }
        self.level = level; self.position = position; render(animated: true)
    }
    func setSuppressed(_ suppressed: Bool) { self.suppressed = suppressed; render(animated: false) }
    func reset(animated: Bool) {
        recording = false; level = 0; render(animated: animated)
    }
    private func render(animated: Bool) {
        let dark = traitCollection.userInterfaceStyle == .dark
        let value = reducedMotion ? (level > 0 ? 0.24 : 0) : level
        let strength = mini ? min(1, value * 1.4) : QuietKeys.strength(level: value, position: position)
        let peakOpacity = reducedMotion ? (dark ? 0.12 : 0.18) : (dark ? 0.32 : 0.9)
        brightness = recording && !suppressed ? strength * peakOpacity * (reducedMotion ? 1 : 0.45 + 0.55 * value) : 0
        let duration = animated && !reducedMotion ? (recording ? 0.05 : 0.12) : 0
        // Fade only the resting fill, not the control, icons or white meter. This
        // creates contrast without making speech darken the key or weakening hit tests.
        let accessible = UIAccessibility.isReduceTransparencyEnabled || traitCollection.accessibilityContrast == .high
        baseOpacity = recording && !suppressed && !dark && !accessible ? 0.22 : 1
        if let cap = superview?.layer, !suppressed {
            let fill = KeyboardMetrics.keyFill.resolvedColor(with: traitCollection)
            let alpha = fill.cgColor.alpha * baseOpacity
            let target = fill.withAlphaComponent(alpha).cgColor
            if cap.backgroundColor != target {
            let previous = cap.presentation()?.backgroundColor ?? cap.backgroundColor
            CATransaction.begin(); CATransaction.setDisableActions(true); cap.backgroundColor = target; CATransaction.commit()
            cap.removeAnimation(forKey: "dictation.baseFill")
            if duration > 0, window != nil {
                let animation = CABasicAnimation(keyPath: "backgroundColor")
                animation.fromValue = previous; animation.toValue = target; animation.duration = 0.12
                cap.add(animation, forKey: "dictation.baseFill")
            }
            }
        }
        let tint = UIColor.white
        let clear = tint.withAlphaComponent(0).cgColor
        let colors = mini ? [clear, tint.cgColor, tint.cgColor, clear] : [tint.cgColor, tint.cgColor]
        CATransaction.begin(); CATransaction.setDisableActions(true)
        light.colors = colors; light.locations = mini ? [0, 0.22, 0.78, 1] : [0, 1]
        CATransaction.commit()
        transition(shade, key: "opacity", to: recording && dimBase && !suppressed && dark ? 0.04 : 0, duration: duration)
        if let cap = superview?.layer { transition(cap, key: "shadowOpacity", to: dark ? 0 : brightness * 0.85, duration: duration) }
        transition(light, key: "opacity", to: brightness, duration: duration)
        transition(light, key: "transform.scale.x", to: mini ? 0.08 + value * 0.92 : 1, duration: duration)
    }
    private func transition(_ target: CALayer, key: String, to value: Double, duration: Double) {
        let previous = (target.value(forKeyPath: key) as? NSNumber)?.doubleValue ?? 0
        guard abs(previous - value) > 0.0001 || duration == 0 else { return }
        let from = target.presentation()?.value(forKeyPath: key) ?? target.value(forKeyPath: key)
        target.removeAnimation(forKey: key)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        target.setValue(value, forKeyPath: key); CATransaction.commit()
        if duration > 0, window != nil {
            let animation = CABasicAnimation(keyPath: key)
            animation.fromValue = from; animation.toValue = value; animation.duration = duration
            animation.timingFunction = CAMediaTimingFunction(name: .linear)
            target.add(animation, forKey: key)
        }
    }
}
