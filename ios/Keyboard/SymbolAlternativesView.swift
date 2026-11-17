import UIKit

/// The originating key owns the gesture; this overlay never steals its touch.
final class SymbolAlternativesView: UIView {
    private let material = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    private let highlight = UIView()
    private var labels: [UILabel] = []
    private var sourceRect = CGRect.zero
    private(set) var choices: [String] = []
    private(set) var selectedIndex: Int?
    var selectedSymbol: String? { selectedIndex.map { choices[$0] } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false; isHidden = true
        accessibilityIdentifier = "keyboard.symbol-alternatives"
        material.layer.cornerRadius = 12; material.clipsToBounds = true
        // Keep alternatives legible over key legends even when backdrop blur is unavailable.
        material.contentView.backgroundColor = .secondarySystemBackground
        layer.shadowColor = UIColor.black.cgColor; layer.shadowOpacity = 0.22
        layer.shadowRadius = 5; layer.shadowOffset = CGSize(width: 0, height: 2)
        addSubview(material)
        highlight.backgroundColor = .systemBlue; highlight.layer.cornerRadius = 8
        material.contentView.addSubview(highlight)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ choices: [String], above key: CGRect, within container: CGRect) {
        sourceRect = key
        for label in labels { label.removeFromSuperview() }; labels = []
        let cellWidth = min(46, (container.width - 8 - 8) / CGFloat(choices.count))
        let width = cellWidth * CGFloat(choices.count) + 8
        frame = CGRect(x: min(container.maxX - width - 4, max(container.minX + 4, key.midX - cellWidth / 2 - 4)),
                       y: max(container.minY + 2, key.minY - 58), width: width, height: min(54, key.minY - container.minY - 4))
        material.frame = bounds
        let anchor = min(choices.count - 1, max(0, Int((key.midX - frame.minX - 4) / cellWidth)))
        self.choices = Array(choices.dropFirst())
        self.choices.insert(choices[0], at: anchor)
        for (index, choice) in self.choices.enumerated() {
            let label = UILabel(); label.text = choice; label.textAlignment = .center
            label.font = .systemFont(ofSize: 25)
            label.frame = CGRect(x: 4 + CGFloat(index) * cellWidth, y: 4, width: cellWidth, height: bounds.height - 8)
            material.contentView.addSubview(label); labels.append(label)
        }
        select(anchor); isHidden = false
    }
    func track(_ point: CGPoint) {
        // The corridor down to the source row allows comfortable lateral sliding.
        guard point.y >= frame.minY - 14, point.y <= sourceRect.maxY + 12,
              point.x >= frame.minX - 8, point.x <= frame.maxX + 8 else { select(nil); return }
        let cellWidth = (bounds.width - 8) / CGFloat(choices.count)
        select(min(choices.count - 1, max(0, Int((point.x - frame.minX - 4) / cellWidth))))
    }
    private func select(_ index: Int?) {
        selectedIndex = index
        highlight.isHidden = index == nil
        if let index { highlight.frame = labels[index].frame }
        for (offset, label) in labels.enumerated() { label.textColor = offset == index ? .white : .label }
    }
}
