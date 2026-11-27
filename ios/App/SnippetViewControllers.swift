import UIKit

final class SnippetListViewController: UITableViewController {
    private let store: SnippetStore
    private(set) var records: [Snippet] = []
    private var loading = true
    private var failed = false
    private var notice: String?
    private var loadTask: Task<Void, Never>?

    init(store: SnippetStore = .shared) { self.store = store; super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Snippet"; navigationItem.largeTitleDisplayMode = .always
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "添加", style: .plain, target: self, action: #selector(add))
        navigationItem.rightBarButtonItem?.accessibilityLabel = "添加 Snippet"
        tableView.rowHeight = UITableView.automaticDimension; tableView.estimatedRowHeight = 76
        tableView.accessibilityIdentifier = "snippets.list"
        refresh()
    }
    func refresh() {
        loadTask?.cancel(); loading = true; failed = false; records = []; tableView.reloadData()
        let store = store
        loadTask = Task { [weak self] in
            let result = await Task.detached { Result { try store.load() } }.value
            guard !Task.isCancelled, let self else { return }
            self.loading = false
            switch result {
            case .success(let records): self.records = records
            case .failure: self.failed = true; self.records = []
            }
            self.tableView.reloadData()
        }
    }
    override func numberOfSections(in tableView: UITableView) -> Int { 1 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { max(1, records.count) }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        [notice, SnippetCopy.introduction].compactMap { $0 }.joined(separator: "\n\n")
    }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        SnippetCopy.privacy + "\n\n" + SnippetCopy.permission
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if !loading, !failed, records.isEmpty {
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            cell.selectionStyle = .none
            let title = UILabel(); title.text = "还没有 Snippet"; title.font = .preferredFont(forTextStyle: .headline)
            let body = UILabel(); body.text = "保存一段常用内容，再为它设置缩写。"; body.font = .preferredFont(forTextStyle: .body); body.textColor = .secondaryLabel
            for label in [title, body] { label.numberOfLines = 0; label.adjustsFontForContentSizeCategory = true }
            let button = UIButton(type: .system); button.setTitle("添加 Snippet", for: .normal)
            button.titleLabel?.font = .preferredFont(forTextStyle: .body); button.titleLabel?.adjustsFontForContentSizeCategory = true
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            button.addTarget(self, action: #selector(add), for: .touchUpInside)
            let stack = UIStackView(arrangedSubviews: [title, body, button]); stack.axis = .vertical; stack.spacing = 12
            stack.translatesAutoresizingMaskIntoConstraints = false; cell.contentView.addSubview(stack)
            let margins = cell.contentView.layoutMarginsGuide
            NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: margins.leadingAnchor), stack.trailingAnchor.constraint(equalTo: margins.trailingAnchor), stack.topAnchor.constraint(equalTo: margins.topAnchor, constant: 8), stack.bottomAnchor.constraint(equalTo: margins.bottomAnchor, constant: -8)])
            return cell
        }
        let cell = tableView.dequeueReusableCell(withIdentifier: "snippet") ?? UITableViewCell(style: .subtitle, reuseIdentifier: "snippet")
        var configuration = UIListContentConfiguration.subtitleCell()
        configuration.textProperties.font = .preferredFont(forTextStyle: .headline)
        configuration.textProperties.numberOfLines = 0
        configuration.secondaryTextProperties.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .systemFont(ofSize: 14))
        configuration.secondaryTextProperties.color = .secondaryLabel
        configuration.secondaryTextProperties.numberOfLines = 0
        configuration.directionalLayoutMargins.top = 17; configuration.directionalLayoutMargins.bottom = 17
        cell.accessoryType = .none
        if let record = records.indices.contains(indexPath.row) ? records[indexPath.row] : nil {
            configuration.text = "@@" + record.abbreviation; configuration.secondaryText = record.preview
            cell.accessoryType = .disclosureIndicator
            cell.accessibilityLabel = "编辑 Snippet，缩写" + record.abbreviation
        } else {
            configuration.text = loading ? "正在读取 Snippet…" : failed ? "暂时无法读取 Snippet，请重试。" : "还没有 Snippet"
            configuration.secondaryText = loading ? nil : failed ? "重试" : "保存一段常用内容，再为它设置缩写。\n\n添加 Snippet"
            cell.accessibilityLabel = [configuration.text, configuration.secondaryText].compactMap { $0 }.joined(separator: "，")
        }
        cell.contentConfiguration = configuration
        cell.isAccessibilityElement = true; cell.accessibilityTraits = .button
        cell.accessibilityValue = nil
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if loading { return }
        if failed { refresh(); return }
        edit(records.indices.contains(indexPath.row) ? records[indexPath.row] : nil)
    }
    @objc private func add() { edit(nil) }
    private func edit(_ record: Snippet?) {
        let editor = SnippetEditorViewController(store: store, original: record)
        editor.onComplete = { [weak self] message in
            self?.notice = message; self?.refresh()
            UIAccessibility.post(notification: .announcement, argument: message)
        }
        let navigation = UINavigationController(rootViewController: editor)
        navigation.modalPresentationStyle = .pageSheet
        present(navigation, animated: true)
        navigation.presentationController?.delegate = editor
    }
}

/// Only these two drafts live in memory. Navigation never writes them implicitly.
final class SnippetEditorViewController: UIViewController, UITextViewDelegate, UIAdaptivePresentationControllerDelegate {
    private let store: SnippetStore
    let original: Snippet?
    let abbreviation = UITextField()
    let content = UITextView()
    private let placeholder = UILabel()
    private let errorLabel = UILabel()
    private let scroll = UIScrollView()
    private var contentHeight: NSLayoutConstraint!
    private var saving = false
    private var mutation: Task<Void, Never>?
    var onComplete: ((String) -> Void)?
    var dirty: Bool { abbreviation.text != (original?.abbreviation ?? "") || content.text != (original?.content ?? "") }

    init(store: SnippetStore = .shared, original: Snippet? = nil) { self.store = store; self.original = original; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = original == nil ? "添加 Snippet" : "编辑 Snippet"
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = .systemGroupedBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "取消", style: .plain, target: self, action: #selector(cancel))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "保存", style: .done, target: self, action: #selector(save))
        navigationController?.isModalInPresentation = dirty
        scroll.translatesAutoresizingMaskIntoConstraints = false; scroll.keyboardDismissMode = .interactive
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor), scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor)
        ])
        let stack = UIStackView(); stack.axis = .vertical; stack.spacing = 20; stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -20)
        ])
        abbreviation.text = original?.abbreviation ?? ""; abbreviation.placeholder = "例如 gmail"
        abbreviation.keyboardType = .asciiCapable; abbreviation.autocorrectionType = .no; abbreviation.autocapitalizationType = .none
        abbreviation.textContentType = .none; abbreviation.spellCheckingType = .no
        abbreviation.font = .preferredFont(forTextStyle: .body); abbreviation.adjustsFontForContentSizeCategory = true
        abbreviation.accessibilityLabel = "缩写"; abbreviation.accessibilityIdentifier = "snippets.abbreviation"
        abbreviation.addTarget(self, action: #selector(changed), for: .editingChanged)
        let marker = label("@@", style: .body); marker.textColor = .secondaryLabel; marker.setContentHuggingPriority(.required, for: .horizontal)
        let abbreviationRow = UIStackView(arrangedSubviews: [marker, abbreviation]); abbreviationRow.spacing = 6
        abbreviationRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        content.text = original?.content ?? ""; content.delegate = self
        content.font = .preferredFont(forTextStyle: .body); content.adjustsFontForContentSizeCategory = true
        content.backgroundColor = .clear; content.isScrollEnabled = false; content.textContainerInset = .zero
        content.textContainer.lineFragmentPadding = 0; content.textContentType = .none
        content.accessibilityLabel = "内容"; content.accessibilityIdentifier = "snippets.content"
        contentHeight = content.heightAnchor.constraint(greaterThanOrEqualToConstant: 240); contentHeight.isActive = true
        placeholder.text = "输入要填入的完整内容"; placeholder.font = .preferredFont(forTextStyle: .body)
        placeholder.adjustsFontForContentSizeCategory = true; placeholder.textColor = .placeholderText
        placeholder.numberOfLines = 0; placeholder.isUserInteractionEnabled = false; placeholder.isAccessibilityElement = false
        content.addSubview(placeholder); placeholder.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([placeholder.leadingAnchor.constraint(equalTo: content.leadingAnchor), placeholder.trailingAnchor.constraint(equalTo: content.trailingAnchor), placeholder.topAnchor.constraint(equalTo: content.topAnchor)])
        let separator = UIView(); separator.backgroundColor = .separator
        separator.heightAnchor.constraint(equalToConstant: 1 / max(1, traitCollection.displayScale)).isActive = true
        let fields = UIStackView(arrangedSubviews: [label("缩写", style: .subheadline), abbreviationRow, separator, label("内容", style: .subheadline), content])
        fields.axis = .vertical; fields.spacing = 8; fields.isLayoutMarginsRelativeArrangement = true
        fields.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
        fields.backgroundColor = .secondarySystemGroupedBackground; fields.layer.cornerRadius = 12
        stack.addArrangedSubview(fields)
        errorLabel.font = .preferredFont(forTextStyle: .body); errorLabel.adjustsFontForContentSizeCategory = true
        errorLabel.textColor = .systemRed; errorLabel.numberOfLines = 0; errorLabel.isHidden = true
        errorLabel.accessibilityIdentifier = "snippets.error"; stack.addArrangedSubview(errorLabel)
        stack.addArrangedSubview(label("只用英文字母、数字或下划线，不区分大小写。这里只填缩写，不加 @@。", style: .footnote))
        stack.addArrangedSubview(label("可以保存邮箱、地址或常用回复等纯文本。", style: .footnote))
        if let original {
            stack.addArrangedSubview(label("输入 @@\(original.abbreviation) 后，点选候选内容才会展开；不点选就保留原样。", style: .footnote))
            let delete = UIButton(type: .system); delete.setTitle("删除 Snippet", for: .normal); delete.tintColor = .systemRed
            delete.backgroundColor = .secondarySystemGroupedBackground; delete.layer.cornerRadius = 12
            delete.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            delete.titleLabel?.font = .preferredFont(forTextStyle: .body); delete.titleLabel?.adjustsFontForContentSizeCategory = true
            delete.addTarget(self, action: #selector(confirmDelete), for: .touchUpInside); stack.addArrangedSubview(delete)
        }
        changed()
    }
    private func label(_ text: String, style: UIFont.TextStyle) -> UILabel {
        let label = UILabel(); label.text = text; label.font = .preferredFont(forTextStyle: style)
        label.adjustsFontForContentSizeCategory = true; label.numberOfLines = 0; label.textColor = .secondaryLabel
        return label
    }
    @objc private func changed() {
        placeholder.isHidden = !content.text.isEmpty
        navigationController?.isModalInPresentation = dirty || saving
    }
    func textViewDidChange(_ textView: UITextView) { changed() }
    func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) { cancel() }
    func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool { !dirty && !saving }
    @objc func cancel() {
        guard !saving else { return }
        guard dirty else { dismiss(animated: true); return }
        let alert = UIAlertController(title: "放弃未保存的修改？", message: nil, preferredStyle: .alert)
        let keep = UIAlertAction(title: "继续编辑", style: .cancel)
        alert.addAction(keep); alert.preferredAction = keep
        alert.addAction(UIAlertAction(title: "放弃修改", style: .destructive) { [weak self] _ in self?.dismiss(animated: true) })
        present(alert, animated: true)
    }
    private func setSaving(_ value: Bool) {
        saving = value; navigationItem.rightBarButtonItem?.isEnabled = !value; navigationItem.leftBarButtonItem?.isEnabled = !value
        // Do not resign the editor or reload it: failures preserve text and caret.
        abbreviation.isUserInteractionEnabled = !value; content.isUserInteractionEnabled = !value
        changed()
    }
    private func showError(_ text: String, field: SnippetError? = nil) {
        errorLabel.text = text; errorLabel.isHidden = false
        abbreviation.accessibilityHint = field != nil && field?.isContentError == false ? text : nil
        content.accessibilityHint = field?.isContentError == true ? text : nil
        UIAccessibility.post(notification: .announcement, argument: text)
    }
    @objc func save() {
        guard !saving else { return }
        setSaving(true)
        let abbreviation = abbreviation.text ?? "", content = content.text ?? "", store = store, original = original
        mutation = Task { [weak self] in
            let result = await Task.detached { Result { try store.save(abbreviation: abbreviation, content: content, replacing: original) } }.value
            guard let self else { return }
            self.setSaving(false)
            switch result {
            case .success: self.finish("已保存。")
            case .failure(let error):
                let field = error as? SnippetError
                let validation = field.map { [.abbreviationRequired, .callMarker, .invalidAbbreviation, .duplicate, .contentRequired].contains($0) } == true
                self.showError(validation ? field!.message : "未能保存，请重试。", field: validation ? field : nil)
            }
        }
    }
    @objc private func confirmDelete() {
        guard !saving, let original else { return }
        let alert = UIAlertController(title: "删除这个 Snippet？", message: "缩写「\(original.abbreviation)」和保存的内容将被删除，已经填入其他 App 的文字不会删除。", preferredStyle: .alert)
        let cancel = UIAlertAction(title: "取消", style: .cancel); alert.addAction(cancel); alert.preferredAction = cancel
        alert.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in self?.deleteConfirmed() })
        present(alert, animated: true)
    }
    func deleteConfirmed() {
        guard !saving, let original else { return }; setSaving(true)
        let store = store
        mutation = Task { [weak self] in
            let result = await Task.detached { Result { try store.delete(original) } }.value
            guard let self else { return }; self.setSaving(false)
            switch result {
            case .success: self.finish("已删除。")
            case .failure: self.showError("未能删除，请重试。")
            }
        }
    }
    private func finish(_ message: String) {
        let completion = onComplete
        dismiss(animated: true) { completion?(message) }
    }
}
