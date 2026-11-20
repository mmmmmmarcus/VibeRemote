import UIKit
#if KEYBOARD_TESTING
@testable import vvhisper
#endif

/// Editing has a dedicated surface; ordinary keys no longer compete with swipes.
final class GesturePill: UIView {
    var onBegin: (() -> Void)?
    var onAction: ((KeyboardEditSwipe) -> Void)?
    private let cap = UIView()
    private let icon = UIImageView(image: UIImage(systemName: "arrow.up.and.down.and.arrow.left.and.right"))
    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "keyboard.gesture-pill"
        isAccessibilityElement = true; accessibilityLabel = "Editing gestures"
        accessibilityHint = "Swipe left to delete a word, right to restore, down for a new line, up to the end of the text."
        cap.backgroundColor = .tertiarySystemFill; cap.layer.cornerRadius = 16
        cap.isUserInteractionEnabled = false; addSubview(cap)
        icon.tintColor = .secondaryLabel; icon.contentMode = .scaleAspectFit; cap.addSubview(icon)
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(pan(_:))))
        accessibilityCustomActions = [("Delete word", KeyboardEditSwipe.deleteWord), ("Restore word", .restoreWord),
                                      ("New line", .lineBreak), ("End of text", .endOfText)].map { title, action in
            UIAccessibilityCustomAction(name: title) { [weak self] _ in
                self?.onBegin?(); self?.onAction?(action); return true
            }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        cap.frame = bounds.insetBy(dx: 4, dy: max(0, (bounds.height - 32) / 2))
        icon.frame = CGRect(x: (cap.bounds.width - 18) / 2, y: (cap.bounds.height - 18) / 2, width: 18, height: 18)
    }
    @objc private func pan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began: onBegin?(); cap.alpha = 0.55
        case .ended:
            cap.alpha = 1
            if let action = KeyboardEditSwipe.action(for: gesture.translation(in: self)) { onAction?(action) }
        case .cancelled, .failed: cap.alpha = 1
        default: break
        }
    }
}
