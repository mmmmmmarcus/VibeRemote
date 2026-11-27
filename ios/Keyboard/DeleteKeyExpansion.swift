import UIKit

/// Visual-only hold affordance. The original Delete control owns the touch for
/// its entire lifetime; this overlay never changes key frames or hit regions.
@MainActor final class DeleteKeyExpansion: UIView {
    struct Geometry {
        let frame: CGRect
        let sourceFrame: CGRect
        let broomCenter: CGPoint
        let coversNeighbor: Bool
        var clearTargetX: CGFloat { frame.minX + broomCenter.x - sourceFrame.minX }
        init(source: CGRect, neighbor: CGRect, limited: Bool) {
            let borrowed = limited ? min(74, max(44, neighbor.width * 0.25)) : neighbor.width
            let left = max(neighbor.minX, neighbor.maxX - borrowed)
            frame = CGRect(x: left, y: source.minY, width: source.maxX - left, height: source.height)
            sourceFrame = source
            broomCenter = CGPoint(x: min(borrowed / 2, 26), y: source.height / 2)
            coversNeighbor = !limited
        }
    }
    let geometry: Geometry
    private weak var source: KeyControl?
    private weak var neighbor: KeyControl?
    private let cap = UIView()
    private let broom = UIImageView(image: UIImage(systemName: "trash"))
    private let deleteIcon = UIImageView()
    private let neighborFace: ModeKeyFace?
    private let neighborFrame: CGRect
    private var saved: [(KeyControl, UIColor?, CGFloat, CGFloat, Bool)] = []
    private var shown = false
    private var dismissed = false
    private(set) var cleared = false
    private var originX: CGFloat = 0
    private var reduced: Bool { UIAccessibility.isReduceMotionEnabled }
    private var closedFrame: CGRect {
        CGRect(x: geometry.sourceFrame.minX - frame.minX, y: 0, width: geometry.sourceFrame.width, height: bounds.height)
    }

    init(source: KeyControl, neighbor: KeyControl, container: UIView) {
        self.source = source; self.neighbor = neighbor
        geometry = Geometry(source: source.convert(source.bounds, to: container),
                            neighbor: neighbor.convert(neighbor.bounds, to: container), limited: neighbor.value == "dictate")
        neighborFrame = neighbor.convert(neighbor.bounds, to: container)
        neighborFace = neighbor.value == "dictate" ? ModeKeyFace(key: neighbor) : nil
        super.init(frame: geometry.frame)
        isUserInteractionEnabled = false; accessibilityElementsHidden = true
        accessibilityIdentifier = "keyboard.delete-expansion"
        cap.backgroundColor = KeyboardMetrics.keyFill
        cap.layer.cornerRadius = source.layer.cornerRadius; cap.layer.cornerCurve = .continuous
        if let neighborFace { addSubview(neighborFace) }
        addSubview(cap)
        for icon in [broom, deleteIcon] { icon.contentMode = .scaleAspectFit; addSubview(icon) }
        broom.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 20, weight: .regular).applying(.preferringMonochrome())
        broom.tintColor = .secondaryLabel
        broom.accessibilityIdentifier = "keyboard.delete-broom"
        broom.frame = CGRect(x: geometry.broomCenter.x - 12, y: bounds.midY - 12, width: 24, height: 24)
        deleteIcon.image = source.restingIcon ?? source.icon.image
        deleteIcon.tintColor = .label
        deleteIcon.frame = CGRect(x: closedFrame.midX - 12.5, y: bounds.midY - 12, width: 25, height: 24)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(in container: UIView, originX: CGFloat) {
        guard !shown, !dismissed, let source, let neighbor else { return }
        shown = true; self.originX = originX
        for key in [source, neighbor] {
            saved.append((key, key.backgroundColor, key.label.alpha, key.icon.alpha, key.quietFeedback.isHidden))
            // Hide paint, not the control. A second finger still reaches the
            // real key and cancels this hold through normal keyboard arbitration.
            key.backgroundColor = .clear; key.label.alpha = 0; key.icon.alpha = 0; key.quietFeedback.isHidden = true
        }
        source.alpha = 1
        container.addSubview(self)
        let remaining = CGRect(x: neighborFrame.minX - frame.minX, y: 0,
                               width: max(1, frame.minX - neighborFrame.minX - (geometry.sourceFrame.minX - neighborFrame.maxX)),
                               height: bounds.height)
        neighborFace?.frame = reduced ? remaining : neighborFrame.offsetBy(dx: -frame.minX, dy: -frame.minY)
        cap.frame = reduced ? bounds : closedFrame
        broom.alpha = 0
        if !reduced { broom.transform = CGAffineTransform(translationX: 7, y: 0) }
        UIView.animate(withDuration: reduced ? 0 : 0.18, delay: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut]) {
            self.cap.frame = self.bounds; self.broom.alpha = 1; self.broom.transform = .identity
            self.neighborFace?.frame = remaining
        }
    }
    func track(_ point: CGPoint) {
        guard shown, !dismissed, !cleared else { return }
        let distance = max(1, originX - geometry.clearTargetX)
        let progress = min(1, max(0, (originX - point.x) / distance))
        if !reduced {
            deleteIcon.transform = CGAffineTransform(translationX: (geometry.broomCenter.x - closedFrame.midX) * progress, y: 0)
        }
        deleteIcon.alpha = 1 - progress * 0.9
        broom.tintColor = progress > 0.65 ? .label : .secondaryLabel
    }
    func confirmClear() {
        guard shown, !dismissed else { return }
        cleared = true
        cap.layer.removeAllAnimations(); cap.frame = bounds
        cap.backgroundColor = .systemRed; broom.tintColor = .white; deleteIcon.alpha = 0
    }
    func dismiss(animated: Bool) {
        guard !dismissed else { return }
        dismissed = true
        for (key, color, textAlpha, iconAlpha, feedbackHidden) in saved {
            key.backgroundColor = color; key.label.alpha = textAlpha; key.icon.alpha = iconAlpha; key.quietFeedback.isHidden = feedbackHidden
        }
        saved.removeAll()
        guard shown, animated, !reduced, window != nil else { removeFromSuperview(); return }
        // Restore real keys synchronously so a new press cannot be overwritten
        // by an old completion. Only this disposable overlay animates out.
        UIView.animate(withDuration: 0.12, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut]) {
            self.cap.frame = self.closedFrame; self.alpha = 0
            self.deleteIcon.transform = .identity; self.broom.alpha = 0
            self.neighborFace?.frame = self.neighborFrame.offsetBy(dx: -self.frame.minX, dy: -self.frame.minY)
        } completion: { _ in self.removeFromSuperview() }
    }
}
