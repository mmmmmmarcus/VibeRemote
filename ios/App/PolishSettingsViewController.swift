import UIKit

final class PolishSettingsViewController: UITableViewController {
    private var settings = DictationPolishSettings.load()
    private let enabled = UISwitch()
    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad(); title = "Polish Dictation"
        navigationItem.largeTitleDisplayMode = .never
        enabled.isOn = settings.enabled
        enabled.accessibilityIdentifier = "polish.enabled"
        enabled.accessibilityLabel = "Polish Dictation"
        enabled.addTarget(self, action: #selector(toggle), for: .valueChanged)
    }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { ArkPolishKeychain.read() == nil ? 3 : 4 }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        "After recognition, Seed 2.0 Mini corrects grammar and phrasing while preserving meaning and languages. Only the transcript is sent, with thinking disabled.\n\nAdd a Volcengine Ark API key on this iPhone. It is stored separately from your speech-recognition key in Keychain; existing OpenRouter keys are not used. If setup is missing or polishing fails, keep the recognized text. Provider charges may apply."
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        switch indexPath.row {
        case 0:
            cell.textLabel?.text = "Polish Dictation"; cell.accessoryView = enabled; cell.selectionStyle = .none
        case 1:
            cell.textLabel?.text = "Volcengine Ark API Key"; cell.detailTextLabel?.text = ArkPolishKeychain.read() == nil ? "Not set" : "Saved"
            cell.accessibilityIdentifier = "polish.api-key"; cell.accessoryType = .disclosureIndicator
        case 2:
            cell.textLabel?.text = "Model"; cell.detailTextLabel?.text = "Seed 2.0 Mini"
            cell.accessibilityIdentifier = "polish.model"; cell.selectionStyle = .none
        default:
            cell.textLabel?.text = "Remove API Key"; cell.textLabel?.textColor = .systemRed
        }
        return cell
    }
    @objc private func toggle() { settings.enabled = enabled.isOn; settings.save() }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.row == 1 || indexPath.row == 3 else { return }
        if indexPath.row == 3 {
            let alert = UIAlertController(title: "Remove Volcengine Ark Key?", message: "Dictation will keep recognized text until you add another key.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: "Remove", style: .destructive) { [weak self] _ in
                do { try ArkPolishKeychain.remove(); self?.tableView.reloadData() } catch { self?.showSaveError() }
            })
            present(alert, animated: true); return
        }
        let alert = UIAlertController(title: "Volcengine Ark API Key", message: "Stored securely on this iPhone, separately from speech recognition.", preferredStyle: .alert)
        alert.addTextField { field in
            field.isSecureTextEntry = true; field.autocapitalizationType = .none; field.autocorrectionType = .no
            field.spellCheckingType = .no
            field.placeholder = "Ark API key"
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self, weak alert] _ in
            guard let self, let value = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
            defer { alert?.textFields?.first?.text = "" }
            do {
                try ArkPolishKeychain.save(value)
                self.tableView.reloadData()
            } catch { self.showSaveError() }
        })
        present(alert, animated: true)
    }
    private func showSaveError() {
        let alert = UIAlertController(title: "Couldn’t Save", message: "Please try again.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default)); present(alert, animated: true)
    }
}
