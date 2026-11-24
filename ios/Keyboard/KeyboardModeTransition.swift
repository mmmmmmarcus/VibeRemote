import UIKit

struct KeyboardModeAppearance {
    struct Item { var id: String; var view: UIView; var frame: CGRect }
    var height: CGFloat
    var items: [Item]
}

/// A single reversible full→mini timeline. Finger updates render immediately;
/// only the short release settle runs a display link. No key legends are scaled.
@MainActor final class KeyboardModeTransition {
    let fromMini: Bool
    let originalPage: Int
    let overlay = UIView()
    private let full: KeyboardModeAppearance
    private let mini: KeyboardModeAppearance
    private let reduced: Bool
    private let onHeight: (CGFloat) -> Void
    private let onCompletion: (Bool) -> Void
    private(set) var progress: CGFloat
    private var link: CADisplayLink?
    private var linkTarget: ModeFrameTarget?
    private var startTime: CFTimeInterval = 0
    private var startProgress: CGFloat = 0
    private var targetProgress: CGFloat = 0
    private var duration: CFTimeInterval = 0

    init(fromMini: Bool, originalPage: Int, full: KeyboardModeAppearance, mini: KeyboardModeAppearance,
         reduced: Bool, onHeight: @escaping (CGFloat) -> Void, onCompletion: @escaping (Bool) -> Void) {
        self.fromMini = fromMini; self.originalPage = originalPage; self.full = full; self.mini = mini
        self.reduced = reduced; self.onHeight = onHeight; self.onCompletion = onCompletion
        progress = fromMini ? 1 : 0
        overlay.isUserInteractionEnabled = false; overlay.accessibilityElementsHidden = true
        overlay.accessibilityIdentifier = "keyboard.mode-transition"; overlay.clipsToBounds = true
        for item in full.items + mini.items { overlay.addSubview(item.view) }
    }
    private func smooth(_ value: CGFloat) -> CGFloat { let x = min(1, max(0, value)); return x*x*(3-2*x) }
    private func mix(_ a: CGFloat, _ b: CGFloat, _ p: CGFloat) -> CGFloat { a+(b-a)*p }
    private func frame(_ a: CGRect, _ b: CGRect, _ p: CGFloat) -> CGRect {
        CGRect(x: mix(a.minX,b.minX,p), y: mix(a.minY,b.minY,p), width: mix(a.width,b.width,p), height: mix(a.height,b.height,p))
    }
    func render(_ value: CGFloat) {
        progress = min(1, max(0, value))
        let p = progress, geometry = reduced ? (p < 0.5 ? CGFloat(0) : 1) : p
        let height = mix(full.height, mini.height, geometry)
        // Remote keyboard hosts coalesce repeated height-constraint changes.
        // Keep one full-height canvas and animate bottom-anchored faces inside it.
        let canvasHeight = max(full.height, mini.height)
        onHeight(canvasHeight)
        overlay.frame = CGRect(x: 0, y: canvasHeight-height, width: overlay.superview?.bounds.width ?? 0, height: height)
        let miniByID = Dictionary(uniqueKeysWithValues: mini.items.map { ($0.id, $0) })
        for item in full.items {
            var origin = item.frame; origin.origin.y -= full.height
            if let target = miniByID[item.id] {
                var end = target.frame; end.origin.y -= mini.height
                var box = frame(origin, end, geometry)
                if !reduced {
                    let horizontal = smooth(p / 0.6)
                    if ["return", "delete"].contains(item.id) {
                        box.origin.x = mix(origin.minX,end.minX,horizontal)
                        box.size.width = mix(origin.width,end.width,horizontal)
                    }
                    if item.id == "delete" { box.origin.y = mix(origin.minY,end.minY,smooth((p-0.55)/0.45)) }
                    if item.id == "dictate" { box.size.width = max(1, mix(origin.maxX,end.maxX,horizontal)-box.minX) }
                }
                box.origin.y += height
                item.view.frame = box; target.view.frame = box
                item.view.alpha = 1-smooth((p-0.55)/0.45); target.view.alpha = smooth(p/0.45)
            } else {
                origin.origin.y += height + (reduced ? 0 : 14*smooth(p/0.65))
                item.view.frame = origin; item.view.alpha = 1-smooth(p/0.52)
            }
        }
    }
    func settle(toMini: Bool) {
        stopLink(); targetProgress = toMini ? 1 : 0; startProgress = progress
        duration = reduced ? 0.12 : max(0.12, 0.20 * Double(abs(targetProgress-startProgress)))
        startTime = CACurrentMediaTime()
        let target = ModeFrameTarget(); target.owner = self; linkTarget = target
        let link = CADisplayLink(target: target, selector: #selector(ModeFrameTarget.frame(_:)))
        self.link = link; link.add(to: .main, forMode: .common)
    }
    fileprivate func tick(_ link: CADisplayLink) {
        let t = min(1, max(0, (link.timestamp-startTime)/duration))
        render(mix(startProgress,targetProgress,CGFloat(1-pow(1-t,2))))
        if t >= 1 { stopLink(); onCompletion(targetProgress == 1) }
    }
    func stop() { stopLink(); overlay.removeFromSuperview() }
    private func stopLink() { link?.invalidate(); link = nil; linkTarget = nil }
    isolated deinit { link?.invalidate() }
}
@MainActor private final class ModeFrameTarget: NSObject {
    weak var owner: KeyboardModeTransition?
    @objc func frame(_ link: CADisplayLink) { owner?.tick(link) }
}

/// Re-layout the face at each width; never stretch a bitmap of a key legend.
@MainActor final class ModeKeyFace: UIView {
    private let label = UILabel()
    private let icon = UIImageView()
    private let offset: CGFloat
    init(key: KeyControl) {
        offset = key.labelOffset
        super.init(frame: key.bounds)
        accessibilityIdentifier = "keyboard.mode-face.\(key.value)"
        backgroundColor = key.backgroundColor; layer.cornerRadius = key.layer.cornerRadius
        label.text = key.label.text; label.font = key.label.font; label.textColor = key.label.textColor
        label.textAlignment = .center; label.isHidden = key.label.isHidden; label.alpha = key.label.alpha
        icon.image = key.icon.image; icon.tintColor = key.icon.tintColor; icon.contentMode = .scaleAspectFit; icon.isHidden = key.icon.isHidden
        addSubview(label); addSubview(icon)
        isUserInteractionEnabled = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds.offsetBy(dx: 0, dy: offset)
        icon.frame = CGRect(x: (bounds.width-25)/2, y: (bounds.height-24)/2, width: 25, height: 24)
    }
}
