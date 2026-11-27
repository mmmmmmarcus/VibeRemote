import UIKit
#if KEYBOARD_TESTING
@testable import vvhisper
#endif

/// Symbol-page strip (designer spec 2026-11-27): 1Password → Messages → copied
/// code → up to five clips → Clipboard History, one horizontally scrolling row
/// with no fill of its own and a 24pt trailing alpha fade.
final class ClipPillStrip: UIView {
    static let stripHeight: CGFloat = 42
    static let pillHeight: CGFloat = 32
    static let leadingInset: CGFloat = 8
    static let spacing: CGFloat = 6
    static let trailingFadeWidth: CGFloat = 24
    static let shortcutWidth: CGFloat = 44

    let scroll = ClipPillScrollView()
    let onePassword = ClipPillButton(shortcutFill: UIColor(red: 0x05 / 255.0, green: 0x72 / 255.0, blue: 0xEC / 255.0, alpha: 1))
    let messages = ClipPillButton(shortcutFill: UIColor(red: 0x34 / 255.0, green: 0xC7 / 255.0, blue: 0x59 / 255.0, alpha: 1))
    let history = ClipPillButton(historyIcon: ())
    private(set) var clips: [ClipPill] = []
    private(set) var clipButtons: [ClipPillButton] = []
    private let trailingFade = CAGradientLayer()
    var onSelect: ((ClipPill) -> Void)?

    /// Every pill in visual order.
    var pills: [ClipPillButton] { [onePassword, messages] + clipButtons + [history] }

    override init(frame: CGRect) {
        super.init(frame: frame)
        // No visible fill (designer 2026-11-27), but keep an imperceptible paint so
        // the remote keyboard host still delivers touches in the gaps.
        backgroundColor = UIColor.label.withAlphaComponent(0.001)
        isOpaque = false
        accessibilityIdentifier = "keyboard.input-helpers"
        scroll.showsHorizontalScrollIndicator = false; scroll.showsVerticalScrollIndicator = false
        scroll.alwaysBounceVertical = false
        scroll.delaysContentTouches = false; scroll.canCancelContentTouches = true
        for effect in [scroll.topEdgeEffect, scroll.bottomEdgeEffect, scroll.leftEdgeEffect, scroll.rightEdgeEffect] { effect.isHidden = true }
        scroll.accessibilityIdentifier = "keyboard.clip-pills"
        trailingFade.startPoint = CGPoint(x: 0, y: 0.5)
        trailingFade.endPoint = CGPoint(x: 1, y: 0.5)
        trailingFade.colors = [UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor]
        scroll.onLayout = { [weak self] in self?.updateTrailingFade() }
        addSubview(scroll)
        for pill in [onePassword, messages, history] { scroll.addSubview(pill) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Rebuilds only when the clips change, so taps never reorder or flicker pills.
    func show(_ newClips: [ClipPill]) {
        guard newClips != clips else { return }
        clips = newClips
        clipButtons.forEach { $0.removeFromSuperview() }
        clipButtons = newClips.enumerated().map { index, clip in
            let button = ClipPillButton(clip: clip)
            button.accessibilityIdentifier = clip.isCode ? "keyboard.paste-code" : "keyboard.clip.\(index - (newClips.first?.isCode == true ? 1 : 0))"
            button.addAction(UIAction { [weak self] _ in self?.onSelect?(clip) }, for: .touchUpInside)
            scroll.insertSubview(button, belowSubview: history)
            return button
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scroll.frame = bounds
        var x = Self.leadingInset
        for pill in pills {
            let width = pill.intrinsicContentSize.width
            pill.frame = CGRect(x: x, y: 0, width: width, height: bounds.height)
            x += width + Self.spacing
        }
        scroll.contentSize = CGSize(width: x - Self.spacing + Self.leadingInset, height: bounds.height)
        updateTrailingFade()
    }

    /// Same alpha-only technique as CandidatePanel: pills fade to transparent over
    /// the system glass while the row continues past the trailing edge.
    private func updateTrailingFade() {
        let bounds = scroll.bounds
        let fade = Self.trailingFadeWidth
        let overflows = scroll.contentSize.width - bounds.maxX > 0.5
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard overflows, bounds.width > fade else {
            if scroll.layer.mask != nil { scroll.layer.mask = nil }
            return
        }
        trailingFade.frame = bounds
        trailingFade.locations = [0, NSNumber(value: Double((bounds.width - fade) / bounds.width)), 1]
        if scroll.layer.mask !== trailingFade { scroll.layer.mask = trailingFade }
    }
}

final class ClipPillScrollView: UIScrollView {
    var onLayout: (() -> Void)?
    override func layoutSubviews() { super.layoutSubviews(); onLayout?() }
    // Scrolling from a pill cancels its tap (UIScrollView keeps UIControl touches by default).
    override func touchesShouldCancel(in view: UIView) -> Bool { true }
}

/// A 32pt capsule, vertically centred in a full-height (42pt) tap target.
final class ClipPillButton: UIButton {
    enum Style { case shortcut, clip, history }
    let style: Style
    let capsule = UIView()
    /// Shortcut pills: black 15% over the brand colour while pressed.
    let pressOverlay = UIView()
    let iconView = UIImageView()
    let titleView = UILabel()
    private(set) var clip: ClipPill?

    static let restingFill = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.14) : UIColor(white: 0, alpha: 0.07) }
    static let pressedFill = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.26) : UIColor(white: 0, alpha: 0.15) }
    static let titleFont = UIFont.systemFont(ofSize: 15, weight: .regular)
    static let clipIconConfiguration = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
    static let leadingPadding: CGFloat = 11, trailingPadding: CGFloat = 14, iconGap: CGFloat = 5

    private init(style: Style) {
        self.style = style
        super.init(frame: .zero)
        for part in [capsule, pressOverlay, iconView, titleView] as [UIView] { part.isUserInteractionEnabled = false; addSubview(part) }
        capsule.layer.cornerRadius = ClipPillStrip.pillHeight / 2; capsule.layer.cornerCurve = .circular
        capsule.clipsToBounds = true
        pressOverlay.backgroundColor = UIColor(white: 0, alpha: 0.15)
        pressOverlay.layer.cornerRadius = ClipPillStrip.pillHeight / 2
        pressOverlay.isHidden = true
        iconView.contentMode = .center
        titleView.font = Self.titleFont; titleView.textColor = .label
        titleView.numberOfLines = 1; titleView.lineBreakMode = .byClipping
        titleView.isHidden = true
        isExclusiveTouch = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    convenience init(shortcutFill: UIColor) {
        self.init(style: .shortcut)
        capsule.backgroundColor = shortcutFill
        iconView.tintColor = .white
    }
    convenience init(historyIcon: Void) {
        self.init(style: .history)
        capsule.backgroundColor = Self.restingFill
        iconView.tintColor = .secondaryLabel
        iconView.image = Self.fitted(UIImage(systemName: "clock.arrow.circlepath"))
    }
    convenience init(clip: ClipPill) {
        self.init(style: .clip)
        self.clip = clip
        capsule.backgroundColor = Self.restingFill
        iconView.tintColor = .secondaryLabel
        iconView.image = UIImage(systemName: clip.kind.symbol, withConfiguration: Self.clipIconConfiguration)
        titleView.text = clip.title; titleView.isHidden = false
        accessibilityLabel = clip.accessibilityLabel
        accessibilityTraits = .button
    }

    /// Shortcut artwork fits the same 20pt box (SF Symbols and the vector 1Password mark).
    func setShortcutImage(_ image: UIImage?) { iconView.image = Self.fitted(image) }

    static func fitted(_ image: UIImage?, side: CGFloat = 20) -> UIImage? {
        image.map { source in
            let scale = side / max(max(source.size.width, source.size.height), 1)
            let size = CGSize(width: source.size.width * scale, height: source.size.height * scale)
            return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
                source.draw(in: CGRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height))
            }.withRenderingMode(.alwaysTemplate)
        }
    }

    override var intrinsicContentSize: CGSize {
        guard style == .clip else { return CGSize(width: ClipPillStrip.shortcutWidth, height: ClipPillStrip.stripHeight) }
        let icon = iconView.image?.size.width ?? 0
        let text = ceil((titleView.text as NSString? ?? "").size(withAttributes: [.font: Self.titleFont]).width)
        return CGSize(width: Self.leadingPadding + icon + Self.iconGap + text + Self.trailingPadding, height: ClipPillStrip.stripHeight)
    }

    override var isHighlighted: Bool { didSet { updatePressed() } }
    private func updatePressed() {
        switch style {
        case .shortcut: pressOverlay.isHidden = !isHighlighted
        case .clip, .history: capsule.backgroundColor = isHighlighted ? Self.pressedFill : Self.restingFill
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let height = ClipPillStrip.pillHeight
        capsule.frame = CGRect(x: 0, y: ((bounds.height - height) / 2).rounded(), width: bounds.width, height: height)
        pressOverlay.frame = capsule.frame
        if style == .clip {
            let icon = iconView.image?.size ?? .zero
            iconView.frame = CGRect(x: Self.leadingPadding, y: capsule.frame.midY - icon.height / 2, width: icon.width, height: icon.height)
            let x = iconView.frame.maxX + Self.iconGap
            let line = ceil(Self.titleFont.lineHeight)
            titleView.frame = CGRect(x: x, y: capsule.frame.midY - line / 2, width: max(0, bounds.width - x - Self.trailingPadding), height: line)
        } else {
            iconView.frame = CGRect(x: (bounds.width - 20) / 2, y: capsule.frame.midY - 10, width: 20, height: 20)
        }
    }
}
