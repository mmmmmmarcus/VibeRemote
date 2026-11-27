import UIKit
#if KEYBOARD_TESTING
@testable import vvhisper
#endif

/// A local, scrolling emoji keyboard; it never switches the system input mode.
@MainActor final class EmojiPanel: UIView, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    var onPress: (() -> Void)?
    var onSelect: ((String) -> Void)?
    var onClose: (() -> Void)?
    private let grid: UICollectionView
    private let categoryScroll = EmojiCategoryScrollView()
    private let categories = UIStackView()
    private let back = UIButton(type: .system)
    private let bottomFade = CAGradientLayer()
    private var showingEmoticons = false
    private var tone = 0
    private var category = EmojiCatalog.categories.first ?? ""
    private var visible: [KeyboardEmoji] = []
    private var pressed: String?
    private var categoryButtons: [UIButton] = []
    private var gridSize: CGSize?
    #if KEYBOARD_TESTING
    private(set) var testingGridInvalidations = 0
    #endif
    private static let symbols = ["face.smiling", "hand.wave", "leaf", "fork.knife", "airplane", "soccerball", "lightbulb", "number", "flag"]

    override init(frame: CGRect) {
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 2; layout.minimumLineSpacing = 4
        layout.sectionInset = UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        grid = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: frame)
        accessibilityIdentifier = "keyboard.emoji-panel"
        backgroundColor = .clear
        categories.axis = .horizontal; categories.spacing = 3
        categoryScroll.showsHorizontalScrollIndicator = false
        categoryScroll.accessibilityIdentifier = "emoji.categories"
        categoryScroll.canCancelContentTouches = true
        categoryScroll.addSubview(categories)
        for (index, name) in EmojiCatalog.categories.enumerated() {
            let button = UIButton(type: .system)
            button.setImage(UIImage(systemName: Self.symbols[min(index, Self.symbols.count - 1)]), for: .normal)
            button.tintColor = .label; button.layer.cornerRadius = 10
            button.accessibilityLabel = name; button.accessibilityIdentifier = "emoji.category.\(index)"
            button.addAction(UIAction { [weak self] _ in self?.category = name; self?.reload() }, for: .touchUpInside)
            button.widthAnchor.constraint(equalToConstant: 44).isActive = true
            categories.addArrangedSubview(button); categoryButtons.append(button)
        }
        grid.backgroundColor = .clear; grid.alwaysBounceVertical = true
        grid.dataSource = self; grid.delegate = self
        grid.register(EmojiCell.self, forCellWithReuseIdentifier: "emoji")
        grid.accessibilityIdentifier = "keyboard.emoji-grid"
        back.setImage(UIImage(systemName: "chevron.backward"), for: .normal); back.tintColor = .label
        back.backgroundColor = .tertiarySystemFill; back.layer.cornerRadius = 18
        grid.contentInset.bottom = 20
        bottomFade.colors = [UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor]
        bottomFade.startPoint = CGPoint(x: 0.5, y: 0); bottomFade.endPoint = CGPoint(x: 0.5, y: 1)
        grid.layer.mask = bottomFade
        back.accessibilityLabel = "Back to letters"; back.accessibilityIdentifier = "emoji.close"
        back.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .touchUpInside)
        for item in [back, categoryScroll, grid] { addSubview(item) }
        reload()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func reload() {
        pressed = nil
        visible = EmojiCatalog.base.filter { $0.category == category }.map { EmojiCatalog.applying(tone: tone, to: $0) }
        showingEmoticons = false
        for (index, button) in categoryButtons.enumerated() {
            let selected = EmojiCatalog.categories[index] == category
            button.backgroundColor = selected ? .tertiarySystemFill : .clear
            button.accessibilityTraits = selected ? [.button, .selected] : [.button]
        }
        grid.reloadData(); grid.setContentOffset(.zero, animated: false)
    }
    func showEmoticons() {
        pressed = nil
        visible = ["^_^", "(^_^)", "(≧▽≦)", "(•‿•)", "(＾▽＾)", "(⌒▽⌒)", "(づ｡◕‿‿◕｡)づ", "(ง •̀_•́)ง", "¯\\_(ツ)_/¯", "(╯°□°)╯︵ ┻━┻", "(T_T)", "(；ω；)", "(・_・;)", "(¬_¬)", "(￣▽￣)", "(｡♥‿♥｡)", "(✿◠‿◠)", "( ˘ ³˘)♥", "(・・?)", "(－_－) zzZ"].map {
            KeyboardEmoji(glyph: $0, name: $0, category: "Emoticons")
        }
        showingEmoticons = true
        for button in categoryButtons { button.backgroundColor = .clear; button.accessibilityTraits = .button }
        grid.reloadData(); grid.setContentOffset(.zero, animated: false)
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        back.frame = CGRect(x: 4, y: 6, width: 44, height: 36)
        categoryScroll.frame = CGRect(x: 56, y: 2, width: max(0, bounds.width - 60), height: 44)
        categories.frame = CGRect(x: 0, y: 0, width: max(categoryScroll.bounds.width, CGFloat(categoryButtons.count) * 47 - 3), height: 44)
        categories.distribution = .equalSpacing; categoryScroll.contentSize = categories.bounds.size
        grid.frame = CGRect(x: 0, y: 48, width: bounds.width, height: max(0, bounds.height - 48))
        updateFade()
        if gridSize != grid.bounds.size {
            gridSize = grid.bounds.size
            grid.collectionViewLayout.invalidateLayout()
            #if KEYBOARD_TESTING
            testingGridInvalidations += 1
            #endif
        }
    }
    private func updateFade() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        bottomFade.frame = grid.bounds
        bottomFade.locations = [0, NSNumber(value: Double(max(0, 1 - 22 / max(1, grid.bounds.height)))), 1]
        CATransaction.commit()
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) { if scrollView === grid { updateFade() } }
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { visible.count }
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "emoji", for: indexPath) as! EmojiCell
        let item = visible[indexPath.item]
        cell.label.text = item.glyph; cell.label.font = .systemFont(ofSize: item.category == "Emoticons" ? 18 : 32); cell.accessibilityLabel = item.name
        cell.onActivate = { [weak self] in self?.onPress?(); self?.onSelect?(item.glyph) }
        cell.accessibilityIdentifier = "emoji.item.\(item.glyph)"; return cell
    }
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let available = max(1, collectionView.bounds.width - 16)
        let count = max(1, Int(available / (showingEmoticons ? 150 : 48)))
        return CGSize(width: max(1, floor((available - CGFloat(count - 1) * 2) / CGFloat(count))), height: 46)
    }
    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard visible.indices.contains(indexPath.item) else { return nil }
        let item = visible[indexPath.item]
        let base = EmojiCatalog.base.first { EmojiCatalog.identity($0.glyph) == EmojiCatalog.identity(item.glyph) } ?? item
        let choices = (0...5).map { EmojiCatalog.applying(tone: $0, to: base) }
        guard Set(choices.map(\.glyph)).count > 1 else { return nil }
        pressed = nil; onPress?()
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(children: choices.enumerated().map { index, choice in
                UIAction(title: choice.glyph) { [weak self] _ in
                    self?.tone = index; self?.onSelect?(choice.glyph); self?.reload()
                }
            })
        }
    }
    func collectionView(_ collectionView: UICollectionView, didHighlightItemAt indexPath: IndexPath) {
        guard visible.indices.contains(indexPath.item) else { pressed = nil; return }
        pressed = visible[indexPath.item].glyph; onPress?()
    }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { pressed = nil }
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard visible.indices.contains(indexPath.item) else { pressed = nil; return }
        let glyph = visible[indexPath.item].glyph
        guard pressed == glyph else { return }; pressed = nil; onSelect?(glyph)
    }
}

/// Let a drag that starts on a category button become native scrolling. UIKit
/// cancels the button's tracking, so releasing after a drag cannot select it.
@MainActor final class EmojiCategoryScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool { view is UIControl || super.touchesShouldCancel(in: view) }
}

@MainActor private final class EmojiCell: UICollectionViewCell {
    let label = UILabel()
    var onActivate: (() -> Void)?
    override func accessibilityActivate() -> Bool { onActivate?(); return true }
    override init(frame: CGRect) {
        super.init(frame: frame)
        label.textAlignment = .center; label.font = .systemFont(ofSize: 32)
        label.isUserInteractionEnabled = false; contentView.addSubview(label)
        isAccessibilityElement = true; accessibilityTraits = .keyboardKey
        layer.cornerRadius = 9
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() { super.layoutSubviews(); label.frame = contentView.bounds }
    override var isHighlighted: Bool { didSet { backgroundColor = isHighlighted ? .tertiarySystemFill : .clear } }
}
