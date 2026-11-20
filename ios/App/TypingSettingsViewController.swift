import UIKit

final class TypingSettingsViewController: UITableViewController {
    private let load: () -> KeyboardPreferences
    private let save: (KeyboardPreferences) throws -> Void
    init(load: @escaping () -> KeyboardPreferences, save: @escaping (KeyboardPreferences) throws -> Void) {
        self.load = load; self.save = save
        super.init(style: .insetGrouped)
        title = "Typing Assistance"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 2 }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        "English corrections apply when you finish a word. Press Delete immediately to restore your spelling. Smart Spacing adds a space after English punctuation and selected English candidates. Chinese Pinyin also tolerates mistyped letters when offering candidates. All typing assistance works on this device."
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let preferences = load(), cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        let toggle = UISwitch(); toggle.tag = indexPath.row
        toggle.isOn = indexPath.row == 0 ? preferences.autoCorrectionEnabled : preferences.smartSpacingEnabled
        let label = indexPath.row == 0 ? "English Auto-Correction" : "Smart Spacing"
        toggle.accessibilityLabel = label
        toggle.accessibilityIdentifier = indexPath.row == 0 ? "typing.auto-correction" : "typing.smart-spacing"
        toggle.addTarget(self, action: #selector(changed(_:)), for: .valueChanged)
        var content = cell.defaultContentConfiguration(); content.text = label
        cell.contentConfiguration = content; cell.accessoryView = toggle; cell.selectionStyle = .none
        return cell
    }
    @objc private func changed(_ sender: UISwitch) {
        var preferences = load()
        if sender.tag == 0 { preferences.autoCorrectionEnabled = sender.isOn }
        else { preferences.smartSpacingEnabled = sender.isOn }
        do { try save(preferences) }
        catch {
            tableView.reloadData()
            let alert = UIAlertController(title: "Couldn’t Save Setting", message: "Please try again.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default)); present(alert, animated: true)
        }
    }
}
