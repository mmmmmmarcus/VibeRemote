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
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 2 }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        "Correct grammar and phrasing while preserving your meaning and languages. If polishing fails, the recognized text is kept."
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        switch indexPath.row {
        case 0:
            cell.textLabel?.text = "Polish Dictation"; cell.accessoryView = enabled; cell.selectionStyle = .none
        default:
            cell.textLabel?.text = "Model"; cell.detailTextLabel?.text = "Seed 2.0 Mini"
            cell.accessibilityIdentifier = "polish.model"; cell.selectionStyle = .none
        }
        return cell
    }
    @objc private func toggle() { settings.enabled = enabled.isOn; settings.save() }
}
