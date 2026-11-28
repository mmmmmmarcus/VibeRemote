import UIKit

/// The remote host asks this view for its desired height when allowsSelfSizing
/// is enabled. Keep that answer separate from a temporarily constrained frame:
/// measuring the host's current 216pt grant must not become the next request.
final class KeyboardInputView: UIInputView {
    private(set) var requestedHeight = KeyboardMetrics(width: 466).contentHeight

    override init(frame: CGRect, inputViewStyle: UIInputView.Style) {
        super.init(frame: frame, inputViewStyle: inputViewStyle)
        allowsSelfSizing = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func requestHeight(_ height: CGFloat) {
        guard height.isFinite, height > 0, height != requestedHeight else { return }
        requestedHeight = height
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: requestedHeight)
    }

    // Apple's documented UIInputView self-sizing entry point. Preserve UIKit's
    // width negotiation; only the natural height belongs to the keyboard.
    // This is an advisory measurement, not a required constraint or frame write.
    override func systemLayoutSizeFitting(_ targetSize: CGSize) -> CGSize {
        var size = super.systemLayoutSizeFitting(targetSize)
        size.height = requestedHeight
        return size
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // A new host must remeasure even if the requested full/mini height did
        // not change. Never derive the request from bounds or window safe areas.
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }
}
