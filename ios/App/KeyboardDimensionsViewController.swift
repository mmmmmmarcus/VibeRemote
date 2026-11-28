import UIKit

/// Host-only controls; exporting is an explicit Files picker, never a network or clipboard action.
final class KeyboardDimensionsViewController: UITableViewController, UIDocumentPickerDelegate {
    private let store: KeyboardDimensionStore
    private var state: KeyboardDimensionStore.State?
    private var failure = false
    private var busy = false
    private let enabledSwitch = UISwitch()
    private var exportSession: KeyboardDimensionStore.ExportSession?

    init(store: KeyboardDimensionStore = .shared) {
        self.store = store
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = KeyboardDimensionCopy.title
        tableView.accessibilityIdentifier = "settings.keyboard-dimensions"
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 60
        enabledSwitch.accessibilityIdentifier = "dimensions.enabled"
        enabledSwitch.accessibilityLabel = "收集键盘尺寸"
        enabledSwitch.addTarget(self, action: #selector(toggleCollection), for: .valueChanged)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: UIApplication.didBecomeActiveNotification, object: nil)
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refresh()
    }
    @objc private func refresh() { perform { try $0.recover() } }
    private func perform(_ operation: @escaping @Sendable (KeyboardDimensionStore) throws -> Void) {
        guard !busy else { return }
        busy = true; tableView.reloadData()
        let store = store
        Task {
            let result = await Task.detached(priority: .utility) { () -> Result<KeyboardDimensionStore.State, Error> in
                Result { try operation(store); return try store.load() }
            }.value
            busy = false
            switch result {
            case .success(let value): state = value; failure = false
            case .failure(let error):
                if case KeyboardDimensionError.exportInProgress = error {
                    let alert = UIAlertController(title: "请先结束导出", message: "请完成或取消正在进行的文件导出，再清除尺寸诊断。", preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "好", style: .default)); present(alert, animated: true)
                } else { state = nil; failure = true }
            }
            tableView.reloadData()
        }
    }
    @objc private func toggleCollection() {
        let enabled = enabledSwitch.isOn
        perform { try $0.setEnabled(enabled) }
    }
    override func numberOfSections(in tableView: UITableView) -> Int { 2 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { section == 0 ? 2 : 3 }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == 0 ? KeyboardDimensionCopy.privacy : KeyboardDimensionCopy.permission + "\n导出仅在你选择文件位置后进行；导出的副本由你管理。清除会同时关闭收集。"
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = UIListContentConfiguration.subtitleCell()
        content.textProperties.numberOfLines = 0
        content.secondaryTextProperties.numberOfLines = 0
        cell.selectionStyle = .none
        switch (indexPath.section, indexPath.row) {
        case (0, 0):
            content.text = "收集键盘尺寸"
            enabledSwitch.isOn = state?.enabled == true
            enabledSwitch.isEnabled = !busy && state != nil
            cell.accessoryView = enabledSwitch
        case (0, 1):
            content.text = failure ? "不可用" : busy ? "正在读取…" : state?.enabled == true ? "已开启，等待键盘布局" : "已关闭"
            content.secondaryText = failure ? KeyboardDimensionCopy.unavailable : "已保存 \(state?.samples.count ?? 0) / \(KeyboardDimensionStore.limit) 组。\n没有新样本时，请确认「允许完全访问」并重新打开键盘；本页不代表已获得该权限。"
            cell.accessibilityIdentifier = "dimensions.status"
        case (1, 0):
            content.text = "导出尺寸 JSON…"
            cell.accessibilityIdentifier = "dimensions.export"
        case (1, 1):
            content.text = "清除并关闭"
            content.textProperties.color = .systemRed
            cell.accessibilityIdentifier = "dimensions.clear"
        default:
            content.text = "刷新"
            cell.accessibilityIdentifier = "dimensions.refresh"
        }
        if indexPath.section == 1 {
            let available = !busy && (indexPath.row != 0 || state?.samples.isEmpty == false)
            cell.isUserInteractionEnabled = available
            if indexPath.row != 1 { content.textProperties.color = available ? .systemBlue : .tertiaryLabel }
            cell.selectionStyle = available ? .default : .none
        }
        cell.contentConfiguration = content
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == 1, !busy else { return }
        switch indexPath.row {
        case 0: export()
        case 1:
            let alert = UIAlertController(title: "清除尺寸诊断？", message: "删除本机样本并关闭收集。已导出的文件不受影响。", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "取消", style: .cancel))
            alert.addAction(UIAlertAction(title: "清除并关闭", style: .destructive) { [weak self] _ in self?.perform { try $0.clear() } })
            present(alert, animated: true)
        default: refresh()
        }
    }
    private func export() {
        guard state?.samples.isEmpty == false else { return }
        busy = true; tableView.reloadData()
        let store = store
        Task {
            let result = await Task.detached(priority: .utility) {
                Result { try store.beginExport() }
            }.value
            busy = false; tableView.reloadData()
            switch result {
            case .success(let session):
                exportSession = session
                let picker = UIDocumentPickerViewController(forExporting: [session.file], asCopy: true)
                picker.delegate = self
                present(picker, animated: true)
            case .failure:
                let alert = UIAlertController(title: "未能导出", message: KeyboardDimensionCopy.unavailable, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "好", style: .default)); present(alert, animated: true)
            }
        }
    }
    private func removeExport() {
        guard let session = exportSession else { return }
        exportSession = nil
        Task.detached(priority: .utility) { try? session.finish() }
    }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { removeExport() }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { removeExport() }
}
