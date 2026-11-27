import UIKit
#if KEYBOARD_TESTING
@testable import vvhisper
#endif

/// One ranked list in a horizontal strip or a vertically scrolling, wrapping
/// browser. Collection cells stay bounded while Rime supplies more on demand.
final class CandidatePanel: UIView, UICollectionViewDataSource, UICollectionViewDelegate, UIGestureRecognizerDelegate {
    private let layout = CandidateLayout()
    private lazy var collection = CandidateCollectionView(frame: .zero, collectionViewLayout: layout)
    private let expand = UIButton(type: .system)
    private lazy var pull = UIPanGestureRecognizer(target: self, action: #selector(pulledCandidates(_:)))
    private var transition: UIViewPropertyAnimator?
    private var transitionSnapshot: UIView?
    private let expandWidth: CGFloat = 56
    /// Width of the alpha fade at the collapsed strip's trailing edge, just
    /// before the chevron (2026-11-26). Words fade to transparent, showing the
    /// system keyboard glass, rather than being hard-cut to a sliver.
    static let trailingFadeWidth: CGFloat = 24
    private let trailingFade = CAGradientLayer()
    private var candidates: [PinyinCandidates.Candidate] = []
    private var hasMore = false
    private var loading = false
    private var pending = false
    private var generation = 0
    private(set) var isExpanded = false
    var headerHeight: CGFloat = 42
    var onSelect: ((PinyinCandidates.Candidate) -> Void)?
    var onMore: (() -> Void)?
    var onExpansionChange: (() -> Void)?
    var onPress: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        // No fill, blur or radius of its own (designer 2026-11-27): the system
        // keyboard glass shows straight through, continuous with the keys.
        // Remote keyboard hosting must still receive touches in the strip gaps
        // and the padding around the chevron, so keep an imperceptible paint.
        backgroundColor = UIColor.label.withAlphaComponent(0.001)
        isOpaque = false
        accessibilityIdentifier = "keyboard.candidates"
        collection.backgroundColor = .clear
        // No scroll-edge blur over the words at the strip's edges.
        for effect in [collection.topEdgeEffect, collection.bottomEdgeEffect, collection.leftEdgeEffect, collection.rightEdgeEffect] { effect.isHidden = true }
        // Alpha-only mask (black = visible, clear = hidden): masked words fade
        // to transparent over the system glass in light and dark alike.
        trailingFade.startPoint = CGPoint(x: 0, y: 0.5)
        trailingFade.endPoint = CGPoint(x: 1, y: 0.5)
        trailingFade.colors = [UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor]
        collection.onLayout = { [weak self] in self?.updateTrailingFade() }
        collection.dataSource = self; collection.delegate = self
        collection.showsHorizontalScrollIndicator = false
        collection.showsVerticalScrollIndicator = false
        collection.delaysContentTouches = false
        collection.canCancelContentTouches = true
        collection.register(CandidateCell.self, forCellWithReuseIdentifier: "candidate")
        collection.accessibilityIdentifier = "keyboard.candidates.list"
        addSubview(collection); addSubview(expand)
        pull.maximumNumberOfTouches = 1
        pull.delegate = self
        addGestureRecognizer(pull)
        expand.tintColor = .label
        expand.accessibilityIdentifier = "candidate.expand"
        expand.accessibilityHint = "You can also swipe down on the candidate strip."
        expand.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.setExpanded(!self.isExpanded, animated: true)
        }, for: .touchUpInside)
        updateExpansionControl()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ choices: [PinyinCandidates.Candidate], hasMore: Bool, appending: Bool = false) {
        let oldCount = candidates.count
        if !appending { generation &+= 1 }
        candidates = choices; self.hasMore = hasMore; loading = false
        if choices.isEmpty {
            // UICollectionView can retain hidden cells until its next visible
            // layout. Drop their old words immediately when composition ends.
            for cell in collection.subviews.compactMap({ $0 as? CandidateCell }) { cell.clear() }
        }
        layout.widths = choices.map { choice in
            ceil((choice.text as NSString).size(withAttributes: [.font: CandidateButton.font]).width) + 16
        }
        setNeedsLayout(); layoutIfNeeded()
        let offset = appending ? collection.contentOffset : .zero
        layout.invalidateLayout()
        if appending, choices.count >= oldCount {
            // Keep a finger-down candidate alive while another batch arrives.
            UIView.performWithoutAnimation {
                collection.insertItems(at: (oldCount..<choices.count).map { IndexPath(item: $0, section: 0) })
            }
        } else { collection.reloadData() }
        collection.layoutIfNeeded()
        collection.setContentOffset(offset, animated: false)
        if choices.isEmpty { setExpanded(false) }
        setNeedsLayout()
    }

    func setPending(_ value: Bool) {
        pending = value
        collection.isUserInteractionEnabled = !value
        expand.isEnabled = !value
    }

    func setExpanded(_ expanded: Bool, animated: Bool = false) {
        let expanded = expanded && !candidates.isEmpty
        guard isExpanded != expanded else { return }
        finishTransition()
        layoutIfNeeded()
        let snapshot = animated ? collection.snapshotView(afterScreenUpdates: false) : nil
        snapshot?.frame = collection.frame
        snapshot?.isUserInteractionEnabled = false
        snapshot?.accessibilityElementsHidden = true
        isExpanded = expanded
        layout.expanded = expanded
        updateExpansionControl()
        onExpansionChange?()
        UIView.performWithoutAnimation {
            self.superview?.layoutIfNeeded()
            self.setNeedsLayout(); self.layoutIfNeeded()
            self.layout.invalidateLayout()
            self.collection.reloadData()
            self.collection.setContentOffset(.zero, animated: false)
            self.collection.layoutIfNeeded()
        }
        guard animated else { return }
        let reduced = UIAccessibility.isReduceMotionEnabled
        if let snapshot { insertSubview(snapshot, belowSubview: expand); transitionSnapshot = snapshot }
        collection.alpha = 0
        collection.transform = reduced ? .identity : CGAffineTransform(translationX: 0, y: expanded ? -10 : 6)
        let animator = UIViewPropertyAnimator(duration: reduced ? 0.12 : 0.22, curve: .easeOut) {
            self.collection.alpha = 1; self.collection.transform = .identity
            snapshot?.alpha = 0
        }
        animator.addCompletion { [weak self, weak animator] _ in
            guard let self, self.transition === animator else { return }
            self.finishTransition()
        }
        transition = animator
        animator.startAnimation()
    }

    private func finishTransition() {
        transition?.stopAnimation(true); transition = nil
        transitionSnapshot?.removeFromSuperview(); transitionSnapshot = nil
        collection.alpha = 1; collection.transform = .identity
    }

    override var isHidden: Bool {
        didSet { if isHidden { finishTransition() } }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { finishTransition() }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        !isExpanded && !pending && !candidates.isEmpty && touch.location(in: self).y <= max(44, headerHeight)
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === pull, !isExpanded, !pending, !candidates.isEmpty else { return false }
        let velocity = pull.velocity(in: self)
        return velocity.y > 0 && velocity.y > abs(velocity.x) * 1.2
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // The collection keeps horizontal scrolling. A downward pan cancels
        // the candidate button's touch before opening, so it never selects a word.
        (gestureRecognizer === pull && otherGestureRecognizer === collection.panGestureRecognizer)
            || (otherGestureRecognizer === pull && gestureRecognizer === collection.panGestureRecognizer)
    }

    @objc private func pulledCandidates(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .began { setExpanded(true, animated: true) }
    }

    private func updateExpansionControl() {
        expand.setImage(UIImage(systemName: isExpanded ? "chevron.up" : "chevron.down",
                                withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)), for: .normal)
        expand.accessibilityLabel = isExpanded ? "Collapse candidates" : "Show all candidates"
        expand.accessibilityValue = isExpanded ? "Expanded" : "Collapsed"
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        expand.frame = CGRect(x: max(0, bounds.width - expandWidth), y: 0, width: expandWidth, height: min(bounds.height, max(44, headerHeight)))
        let transform = collection.transform
        collection.transform = .identity
        collection.frame = CGRect(x: 0, y: 0, width: max(0, bounds.width - expandWidth), height: bounds.height)
        collection.transform = transform
        layout.rowHeight = max(38, headerHeight)
        collection.alwaysBounceHorizontal = !isExpanded
        collection.alwaysBounceVertical = isExpanded
        layout.invalidateLayout()
        updateTrailingFade()
    }

    /// Fades only while collapsed words continue past the visible trailing
    /// edge; at the end of the list (or when everything fits) nothing fades.
    private func updateTrailingFade() {
        let bounds = collection.bounds
        let fade = Self.trailingFadeWidth
        let overflows = collection.contentSize.width - bounds.maxX > 0.5
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard !isExpanded, overflows, bounds.width > fade else {
            if collection.layer.mask != nil { collection.layer.mask = nil }
            return
        }
        // The mask lives in the scroll view's bounds space, so it follows the offset.
        trailingFade.frame = bounds
        trailingFade.locations = [0, NSNumber(value: Double((bounds.width - fade) / bounds.width)), 1]
        if collection.layer.mask !== trailingFade { collection.layer.mask = trailingFade }
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { candidates.count }
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "candidate", for: indexPath) as! CandidateCell
        let candidate = candidates[indexPath.item]
        let generation = generation
        cell.configure(candidate, isDefault: indexPath.item == 0, onPress: { [weak self] in self?.onPress?() }) { [weak self] in
            guard let self, !self.pending, generation == self.generation,
                  self.candidates.contains(where: { $0.identifier == candidate.identifier && $0.text == candidate.text }) else { return }
            self.onSelect?(candidate)
        }
        return cell
    }
    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard indexPath.item >= candidates.count - 4 else { return }
        requestMore()
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let remaining = isExpanded ? scrollView.contentSize.height - scrollView.bounds.height - scrollView.contentOffset.y
            : scrollView.contentSize.width - scrollView.bounds.width - scrollView.contentOffset.x
        updateTrailingFade()
        if remaining < 100 { requestMore() }
    }
    private func requestMore() {
        guard hasMore, !loading, !pending, !isHidden else { return }
        loading = true
        // Avoid reloading the collection during its own layout/display callbacks.
        DispatchQueue.main.async { [weak self] in self?.onMore?() }
    }
}

private final class CandidateCollectionView: UICollectionView {
    var onLayout: (() -> Void)?
    override func layoutSubviews() { super.layoutSubviews(); onLayout?() }
    override func touchesShouldCancel(in view: UIView) -> Bool {
        view is CandidateButton || super.touchesShouldCancel(in: view)
    }
}

private final class CandidateCell: UICollectionViewCell {
    private var button: CandidateButton?
    func clear() { button?.removeFromSuperview(); button = nil }
    override func prepareForReuse() { super.prepareForReuse(); clear() }
    func configure(_ candidate: PinyinCandidates.Candidate, isDefault: Bool, onPress: @escaping () -> Void, select: @escaping () -> Void) {
        button?.removeFromSuperview()
        let button = CandidateButton(title: candidate.text, identifier: candidate.identifier, isDefault: isDefault)
        button.addAction(UIAction { _ in onPress() }, for: .touchDown)
        button.addAction(UIAction { _ in select() }, for: .touchUpInside)
        contentView.addSubview(button); self.button = button
        button.frame = contentView.bounds; button.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    }
}

/// Variable-width, left-aligned rows. Never stretch short words into equal cells.
final class CandidateLayout: UICollectionViewLayout {
    var widths: [CGFloat] = []
    var expanded = false
    var rowHeight: CGFloat = 42
    private var attributes: [UICollectionViewLayoutAttributes] = []
    private var size = CGSize.zero
    override func prepare() {
        super.prepare()
        guard let collectionView else { return }
        let available = max(1, collectionView.bounds.width - 4)
        var x: CGFloat = 2, y: CGFloat = 0
        attributes = widths.enumerated().map { index, naturalWidth in
            let width = expanded ? min(naturalWidth, available) : naturalWidth
            if expanded, x > 2, x + width > collectionView.bounds.width - 2 { x = 2; y += rowHeight }
            let item = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: index, section: 0))
            item.frame = CGRect(x: x, y: y, width: width, height: rowHeight)
            x += width + 6
            return item
        }
        size = expanded ? CGSize(width: collectionView.bounds.width, height: widths.isEmpty ? 0 : y + rowHeight)
            : CGSize(width: max(0, x - 4), height: rowHeight)
    }
    override var collectionViewContentSize: CGSize { size }
    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        attributes.filter { $0.frame.intersects(rect) }
    }
    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        attributes.indices.contains(indexPath.item) ? attributes[indexPath.item] : nil
    }
    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        newBounds.size != collectionView?.bounds.size
    }
}
