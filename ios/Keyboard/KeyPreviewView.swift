import UIKit

/// One raised character balloon, drawn inside the extension's existing bounds.
/// It never participates in hit testing or changes key/candidate geometry.
final class KeyPreviewView: UIView {
    let label = UILabel()
    private let shape = CAShapeLayer()
    private(set) var headFrame = CGRect.zero
    static let fill = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.36, alpha: 1) : .white }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        accessibilityIdentifier = "keyboard.key-preview"
        isHidden = true
        layer.addSublayer(shape)
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.2; layer.shadowRadius = 4
        layer.shadowOffset = CGSize(width: 0, height: 2)
        label.textAlignment = .center; label.textColor = .label
        addSubview(label)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: KeyPreviewView, _: UITraitCollection) in
            view.updateColors()
        }
        updateColors()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ text: String, above key: CGRect, within container: CGRect, font: UIFont) {
        updateColors()
        let width = min(82, max(58, key.width + 22))
        let desiredHeight = min(58, max(46, key.height + 8))
        let y = max(container.minY + 2, key.minY - desiredHeight - 7)
        let height = min(desiredHeight, max(32, key.minY - y - 2))
        let head = CGRect(x: min(max(key.midX - width / 2, container.minX + 2), container.maxX - width - 2),
                          y: y, width: width, height: height)
        frame = head.union(key)
        headFrame = head.offsetBy(dx: -frame.minX, dy: -frame.minY)
        let stem = key.offsetBy(dx: -frame.minX, dy: -frame.minY)
        let h = headFrame, r: CGFloat = 10, s: CGFloat = 7
        let path = UIBezierPath()
        path.move(to: CGPoint(x: h.minX + r, y: h.minY))
        path.addLine(to: CGPoint(x: h.maxX - r, y: h.minY))
        path.addQuadCurve(to: CGPoint(x: h.maxX, y: h.minY + r), controlPoint: CGPoint(x: h.maxX, y: h.minY))
        path.addLine(to: CGPoint(x: h.maxX, y: h.maxY - r))
        path.addQuadCurve(to: CGPoint(x: h.maxX - r, y: h.maxY), controlPoint: CGPoint(x: h.maxX, y: h.maxY))
        path.addCurve(to: CGPoint(x: stem.maxX, y: stem.minY + s),
                      controlPoint1: CGPoint(x: h.maxX - r, y: h.maxY + 4), controlPoint2: CGPoint(x: stem.maxX, y: stem.minY))
        path.addLine(to: CGPoint(x: stem.maxX, y: stem.maxY - s))
        path.addQuadCurve(to: CGPoint(x: stem.maxX - s, y: stem.maxY), controlPoint: CGPoint(x: stem.maxX, y: stem.maxY))
        path.addLine(to: CGPoint(x: stem.minX + s, y: stem.maxY))
        path.addQuadCurve(to: CGPoint(x: stem.minX, y: stem.maxY - s), controlPoint: CGPoint(x: stem.minX, y: stem.maxY))
        path.addLine(to: CGPoint(x: stem.minX, y: stem.minY + s))
        path.addCurve(to: CGPoint(x: h.minX + r, y: h.maxY),
                      controlPoint1: CGPoint(x: stem.minX, y: stem.minY), controlPoint2: CGPoint(x: h.minX + r, y: h.maxY + 4))
        path.addQuadCurve(to: CGPoint(x: h.minX, y: h.maxY - r), controlPoint: CGPoint(x: h.minX, y: h.maxY))
        path.addLine(to: CGPoint(x: h.minX, y: h.minY + r))
        path.addQuadCurve(to: CGPoint(x: h.minX + r, y: h.minY), controlPoint: CGPoint(x: h.minX, y: h.minY))
        path.close()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        shape.frame = bounds; shape.path = path.cgPath; layer.shadowPath = path.cgPath
        CATransaction.commit()
        label.text = text
        label.font = font.withSize(min(38, max(30, font.pointSize + 8)))
        label.frame = h.insetBy(dx: 2, dy: 0)
        isHidden = false
    }

    private func updateColors() {
        shape.fillColor = Self.fill.resolvedColor(with: traitCollection).cgColor
        shape.strokeColor = UIColor.separator.resolvedColor(with: traitCollection).withAlphaComponent(0.2).cgColor
        shape.lineWidth = 0.5
    }
}
