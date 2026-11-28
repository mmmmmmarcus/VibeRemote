import UIKit

/// One continuous Soft lift silhouette, drawn inside the extension's existing bounds.
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
        let width = min(container.width - 4, min(82, max(62, key.width + 26)))
        let desiredHeight: CGFloat = 56
        let y = max(container.minY + 2, key.minY - desiredHeight - 7)
        let height = min(desiredHeight, max(32, key.minY - y - 2))
        let head = CGRect(x: min(max(key.midX - width / 2, container.minX + 2), container.maxX - width - 2),
                          y: y, width: width, height: height)
        frame = head.union(key)
        headFrame = head.offsetBy(dx: -frame.minX, dy: -frame.minY)
        let stem = key.offsetBy(dx: -frame.minX, dy: -frame.minY)
        let h = headFrame, r: CGFloat = 14, s = min(6, stem.height / 4)
        // Vertical tangents at both ends avoid the old horizontal shelf/pinch.
        // Compress the shoulder with the head when the top row has less room.
        let shoulderY = h.minY + h.height * (36 / 56)
        let neckY = max(shoulderY + 1, stem.minY + min(4, stem.height / 5))
        let bend = (neckY - shoulderY) * 0.52
        let path = UIBezierPath()
        path.move(to: CGPoint(x: h.minX + r, y: h.minY))
        path.addLine(to: CGPoint(x: h.maxX - r, y: h.minY))
        path.addQuadCurve(to: CGPoint(x: h.maxX, y: h.minY + r), controlPoint: CGPoint(x: h.maxX, y: h.minY))
        path.addLine(to: CGPoint(x: h.maxX, y: shoulderY))
        path.addCurve(to: CGPoint(x: stem.maxX, y: neckY),
                      controlPoint1: CGPoint(x: h.maxX, y: shoulderY + bend),
                      controlPoint2: CGPoint(x: stem.maxX, y: neckY - bend))
        path.addLine(to: CGPoint(x: stem.maxX, y: stem.maxY - s))
        path.addQuadCurve(to: CGPoint(x: stem.maxX - s, y: stem.maxY), controlPoint: CGPoint(x: stem.maxX, y: stem.maxY))
        path.addLine(to: CGPoint(x: stem.minX + s, y: stem.maxY))
        path.addQuadCurve(to: CGPoint(x: stem.minX, y: stem.maxY - s), controlPoint: CGPoint(x: stem.minX, y: stem.maxY))
        path.addLine(to: CGPoint(x: stem.minX, y: neckY))
        path.addCurve(to: CGPoint(x: h.minX, y: shoulderY),
                      controlPoint1: CGPoint(x: stem.minX, y: neckY - bend),
                      controlPoint2: CGPoint(x: h.minX, y: shoulderY + bend))
        path.addLine(to: CGPoint(x: h.minX, y: h.minY + r))
        path.addQuadCurve(to: CGPoint(x: h.minX + r, y: h.minY), controlPoint: CGPoint(x: h.minX, y: h.minY))
        path.close()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        shape.frame = bounds; shape.path = path.cgPath; layer.shadowPath = path.cgPath
        CATransaction.commit()
        label.text = text
        label.font = font.withSize(min(32, h.height - 4))
        label.frame = h.insetBy(dx: 2, dy: 0)
        isHidden = false
    }

    private func updateColors() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        shape.fillColor = Self.fill.resolvedColor(with: traitCollection).cgColor
        shape.strokeColor = UIColor.separator.resolvedColor(with: traitCollection).withAlphaComponent(0.2).cgColor
        shape.lineWidth = 0.5
        CATransaction.commit()
    }
}
