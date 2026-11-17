import UIKit

final class SeedKeyViewController: UITableViewController {
    private let field = UITextField()
    private var errorMessage: String?

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Seed API Key"
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Save", style: .prominent, target: self, action: #selector(saveKey))
        navigationItem.rightBarButtonItem?.isEnabled = false
        field.placeholder = SeedKeychain.read() == nil ? "API key" : "Enter a new API key"
        field.font = .preferredFont(forTextStyle: .body); field.adjustsFontForContentSizeCategory = true
        field.isSecureTextEntry = true; field.autocorrectionType = .no; field.autocapitalizationType = .none
        field.accessibilityIdentifier = "seed-api-key"
        field.addTarget(self, action: #selector(keyChanged), for: .editingChanged)
        tableView.keyboardDismissMode = .interactive
    }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 1 }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        errorMessage ?? "Your key is stored securely on this iPhone and used only for speech recognition."
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell()
        cell.selectionStyle = .none
        cell.contentView.addSubview(field); field.translatesAutoresizingMaskIntoConstraints = false
        let guide = cell.contentView.layoutMarginsGuide
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: guide.leadingAnchor), field.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            field.topAnchor.constraint(equalTo: guide.topAnchor), field.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
            field.heightAnchor.constraint(greaterThanOrEqualToConstant: 32)
        ])
        return cell
    }
    @objc private func keyChanged() {
        navigationItem.rightBarButtonItem?.isEnabled = !(field.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }
    @objc private func saveKey() {
        guard let key = field.text?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return }
        do {
            try SeedKeychain.save(key)
            field.text = ""; view.endEditing(true)
            VoiceHost.shared.enable()
            navigationController?.popViewController(animated: true)
        } catch {
            errorMessage = "Couldn’t save your key. Please try again."
            tableView.reloadData()
        }
    }
}
