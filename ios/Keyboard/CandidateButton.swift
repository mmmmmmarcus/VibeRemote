import UIKit

/// Candidate sizing must follow its text, without UIButton's system minimum width.
final class CandidateButton: UIControl {
    private let label = UILabel()
    private let selectionFill = UIView()
    /// Every candidate, including the default one, uses regular weight; the
    /// default is marked only by its small rounded highlight.
    static let font = UIFont.systemFont(ofSize: 18, weight: .regular)

    init(title: String, identifier: String, isDefault: Bool) {
        super.init(frame: .zero)
        label.text = title
        label.font = Self.font
        label.textColor = .label
        label.textAlignment = .center
        label.numberOfLines = 1
        label.isUserInteractionEnabled = false
        selectionFill.backgroundColor = isDefault ? .secondarySystemFill : .clear
        selectionFill.layer.cornerRadius = 8
        selectionFill.isUserInteractionEnabled = false
        addSubview(selectionFill); addSubview(label)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        isAccessibilityElement = true
        accessibilityLabel = title
        accessibilityIdentifier = identifier
        accessibilityTraits = [.button]
        if isDefault {
            accessibilityTraits.insert(.selected)
            accessibilityHint = "Press Space to select this candidate."
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var intrinsicContentSize: CGSize {
        CGSize(width: ceil(label.intrinsicContentSize.width) + 16, height: 38)
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds.insetBy(dx: 8, dy: 0)
        selectionFill.frame = bounds.insetBy(dx: 0, dy: 5)
    }
    override var isHighlighted: Bool { didSet { alpha = isHighlighted ? 0.5 : 1 } }
    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        isHighlighted = true; return true
    }
    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        isHighlighted = bounds.contains(touch.location(in: self)); return true
    }
    override func endTracking(_ touch: UITouch?, with event: UIEvent?) { isHighlighted = false }
    override func cancelTracking(with event: UIEvent?) { isHighlighted = false }
    override func accessibilityActivate() -> Bool { sendActions(for: .touchUpInside); return true }
}
