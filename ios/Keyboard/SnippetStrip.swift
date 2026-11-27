import UIKit
#if KEYBOARD_TESTING
@testable import vvhisper
#endif

enum SnippetStripState: Equatable {
    case permission, loading, failure, empty, data([Snippet]), notice(String), information(String)
    var message: String? {
        switch self {
        case .permission: return "开启完全访问后才能读取 Snippet。"
        case .loading: return "正在读取 Snippet…"
        case .failure: return "暂时无法读取 Snippet，请重试。"
        case .empty: return "还没有 Snippet，请先在 vvhisper 中添加。"
        case .notice(let text), .information(let text): return text
        case .data: return nil
        }
    }
}

/// Only replaces the existing header. UICollectionView virtualizes an unbounded
/// number of entries; the back button never belongs to its scrolling content.
final class SnippetStrip: UIView, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    let back = UIButton(type: .system)
    let info = UIButton(type: .system)
    let retry = UIButton(type: .system)
    private let messageScroll = UIScrollView()
    private let message = UILabel()
    let collection: UICollectionView
    private(set) var state: SnippetStripState = .loading
    private var previousState: SnippetStripState?
    private let configuredCells = NSHashTable<SnippetCell>.weakObjects()
    var matching = false
    var onBack: (() -> Void)?
    var onRetry: (() -> Void)?
    var onSelect: ((Snippet) -> Void)?
    var records: [Snippet] { if case .data(let records) = state { return records }; return [] }

    override init(frame: CGRect) {
        let layout = UICollectionViewFlowLayout(); layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 6; layout.minimumInteritemSpacing = 0
        collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: frame)
        backgroundColor = UIColor.label.withAlphaComponent(0.001)
        accessibilityIdentifier = "keyboard.snippets"
        collection.backgroundColor = .clear; collection.dataSource = self; collection.delegate = self
        collection.showsHorizontalScrollIndicator = false; collection.alwaysBounceVertical = false
        collection.register(SnippetCell.self, forCellWithReuseIdentifier: "snippet")
        collection.delaysContentTouches = false; collection.canCancelContentTouches = true
        for effect in [collection.topEdgeEffect, collection.bottomEdgeEffect, collection.leftEdgeEffect, collection.rightEdgeEffect] { effect.isHidden = true }
        back.setImage(UIImage(systemName: "chevron.backward"), for: .normal); back.accessibilityLabel = "返回候选栏"
        back.accessibilityIdentifier = "keyboard.snippets.back"
        back.addTarget(self, action: #selector(goBack), for: .touchUpInside)
        info.setImage(UIImage(systemName: "info.circle"), for: .normal); info.accessibilityLabel = "Snippet 信息"
        info.addTarget(self, action: #selector(information), for: .touchUpInside)
        retry.setTitle("重试", for: .normal); retry.addAction(UIAction { [weak self] _ in self?.onRetry?() }, for: .touchUpInside)
        message.font = .preferredFont(forTextStyle: .footnote); message.adjustsFontForContentSizeCategory = true
        message.textColor = .secondaryLabel; message.numberOfLines = 1
        messageScroll.showsHorizontalScrollIndicator = false; messageScroll.addSubview(message)
        for effect in [messageScroll.topEdgeEffect, messageScroll.bottomEdgeEffect, messageScroll.leftEdgeEffect, messageScroll.rightEdgeEffect] { effect.isHidden = true }
        for view in [collection, messageScroll, back, info, retry] { addSubview(view) }
        show(.loading)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func show(_ state: SnippetStripState) {
        // UICollectionView may keep offscreen cells in its reuse pool. Wipe
        // their preview/activation state too, not just the current data array.
        for cell in configuredCells.allObjects { cell.clear() }
        self.state = state; previousState = nil
        message.text = state.message; message.accessibilityLabel = state.message
        collection.isHidden = state.message != nil; messageScroll.isHidden = state.message == nil
        if case .information = state { info.isHidden = true } else { info.isHidden = state.message == nil }
        if case .notice = state { retry.isHidden = false }
        else { retry.isHidden = state != .failure }
        collection.reloadData(); setNeedsLayout()
    }
    @objc private func information() {
        let previous = state
        show(.information(state == .permission ? SnippetCopy.permissionDetail : SnippetCopy.privacy + " " + SnippetCopy.permission))
        previousState = previous
        UIAccessibility.post(notification: .layoutChanged, argument: message)
    }
    @objc private func goBack() {
        if let previousState { show(previousState); UIAccessibility.post(notification: .layoutChanged, argument: info) }
        else { onBack?() }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        back.frame = CGRect(x: 0, y: 0, width: 44, height: bounds.height)
        info.frame = CGRect(x: bounds.width - 44, y: 0, width: 44, height: bounds.height)
        retry.frame = CGRect(x: bounds.width - 88, y: 0, width: 44, height: bounds.height)
        collection.frame = CGRect(x: 44, y: 0, width: max(0, bounds.width - 44), height: bounds.height)
        messageScroll.frame = CGRect(x: 44, y: 0, width: max(0, bounds.width - 44 - (info.isHidden ? 0 : 44) - (retry.isHidden ? 0 : 44)), height: bounds.height)
        let size = message.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: bounds.height))
        message.frame = CGRect(x: 0, y: 0, width: size.width + 8, height: bounds.height)
        messageScroll.contentSize = message.frame.size
        collection.collectionViewLayout.invalidateLayout()
    }
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { records.count }
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "snippet", for: indexPath) as! SnippetCell
        let record = records[indexPath.item]
        configuredCells.add(cell)
        cell.show(record, matching: matching)
        let id = record.id, revision = record.revision
        cell.onActivate = { [weak self] in
            guard let self, let current = self.records.first(where: { $0.id == id && $0.revision == revision }) else { return }
            self.onSelect?(current)
        }
        return cell
    }
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let record = records[indexPath.item]
        let text = "@@" + String(record.abbreviation.prefix(80)) + "  " + record.preview
        let width = (text as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: 13, weight: .semibold)]).width + 24
        return CGSize(width: min(max(44, width), max(44, collection.bounds.width - 8)), height: bounds.height)
    }
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard records.indices.contains(indexPath.item) else { return }
        collectionView.deselectItem(at: indexPath, animated: false); onSelect?(records[indexPath.item])
    }
}

private final class SnippetCell: UICollectionViewCell {
    private let capsule = UIView()
    private let label = UILabel()
    var onActivate: (() -> Void)?
    override init(frame: CGRect) {
        super.init(frame: frame)
        capsule.backgroundColor = .systemGray5; capsule.layer.cornerRadius = 16; capsule.clipsToBounds = true
        label.numberOfLines = 1; label.lineBreakMode = .byTruncatingTail; label.isAccessibilityElement = false
        contentView.addSubview(capsule); capsule.addSubview(label)
        isAccessibilityElement = true; accessibilityTraits = .button
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func show(_ record: Snippet, matching: Bool) {
        let text = NSMutableAttributedString(string: "@@" + record.abbreviation, attributes: [.font: UIFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: UIColor.label])
        text.append(NSAttributedString(string: "  " + record.preview, attributes: [.font: UIFont.systemFont(ofSize: 13), .foregroundColor: UIColor.secondaryLabel]))
        label.attributedText = text
        accessibilityLabel = (matching ? "展开缩写" : "填入 Snippet，缩写") + record.abbreviation
        accessibilityHint = matching ? "用保存的完整内容替换光标前的缩写。" : "将完整内容插入当前输入框。"
        accessibilityValue = nil
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        capsule.frame = CGRect(x: 0, y: (bounds.height - 32) / 2, width: bounds.width, height: 32)
        label.frame = capsule.bounds.insetBy(dx: 10, dy: 0)
    }
    override var isHighlighted: Bool { didSet { capsule.backgroundColor = isHighlighted ? .systemGray3 : .systemGray5 } }
    override func accessibilityActivate() -> Bool { onActivate?(); return onActivate != nil }
    func clear() { label.attributedText = nil; accessibilityLabel = nil; accessibilityHint = nil; onActivate = nil }
    override func prepareForReuse() { super.prepareForReuse(); clear() }
}
