import UIKit

/// Standard grouped settings keep status, setup and preferences separate from typing.
final class MainSettingsViewController: UITableViewController {
    private var preferences: KeyboardPreferences
    private let loadPreferences: () -> KeyboardPreferences
    private let savePreferences: (KeyboardPreferences) throws -> Void
    private let mixedTypingSwitch = UISwitch()
    private let hapticCell = HapticStrengthCell()
    private lazy var feedback = UIImpactFeedbackGenerator(style: .light, view: view)

    init(loadPreferences: @escaping () -> KeyboardPreferences = { .load() },
         savePreferences: @escaping (KeyboardPreferences) throws -> Void = { try $0.save() }) {
        self.loadPreferences = loadPreferences; self.savePreferences = savePreferences
        preferences = loadPreferences()
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "vvhisper"
        navigationItem.largeTitleDisplayMode = .always
        navigationItem.backButtonDisplayMode = .minimal
        tableView.accessibilityIdentifier = "settings"
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 60
        hapticCell.update(preferences.hapticStrength)
        hapticCell.onPrepare = { [weak self] in self?.feedback.prepare() }
        hapticCell.onChange = { [weak self] strength in self?.setHapticStrength(strength) }
        mixedTypingSwitch.isOn = preferences.mixedTypingEnabled
        mixedTypingSwitch.accessibilityLabel = "Mixed Chinese & English"
        mixedTypingSwitch.accessibilityIdentifier = "keyboard.mixed-typing"
        mixedTypingSwitch.addTarget(self, action: #selector(setMixedTyping), for: .valueChanged)
        VoiceHost.shared.onChange = { [weak self] in self?.refreshVoiceStatus() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        preferences = loadPreferences()
        hapticCell.update(preferences.hapticStrength)
        mixedTypingSwitch.isOn = preferences.mixedTypingEnabled
        tableView.reloadData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 4 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? 3 : section >= 2 ? 1 : 2
    }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        ["Voice Input", "Keyboard", "Haptics", "Experimental"][section]
    }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch section {
        case 0: return "Voice input starts automatically and turns off \(preferences.voiceSessionTitle) after microphone activation, including during dictation. Only speech during a dictation hold is sent for transcription."
        case 1: return "Add vvhisper in Settings → General → Keyboard, then allow Full Access for dictation. Use the language key to switch typing languages."
        case 2: return "Adjust the feel of each tap. Set the strength to Off for no haptics."
        default: return "Offer Chinese and English candidates together in Chinese mode. You can still switch to English with the language key."
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == 2 { return hapticCell }
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = UIListContentConfiguration.valueCell()
        content.imageProperties.maximumSize = CGSize(width: 24, height: 24)
        content.imageProperties.tintColor = .systemBlue
        cell.accessoryType = .disclosureIndicator
        switch (indexPath.section, indexPath.row) {
        case (0, 0):
            content = .subtitleCell()
            content.text = VoiceHost.shared.enabled ? "Ready to dictate" : VoiceHost.shared.enabling ? "Getting ready…" : "Voice Input"
            content.secondaryText = VoiceHost.shared.enabled ? "Hold a letter key to speak. Release to finish." : VoiceHost.shared.status
            content.secondaryTextProperties.numberOfLines = 0
            content.secondaryTextProperties.color = .secondaryLabel
            content.image = UIImage(systemName: VoiceHost.shared.enabled ? "waveform.circle.fill" : "waveform.circle")
            content.imageProperties.tintColor = VoiceHost.shared.enabled ? .systemGreen : .systemBlue
            content.imageProperties.maximumSize = CGSize(width: 32, height: 32)
            cell.accessoryType = .none
            cell.selectionStyle = .none
            cell.accessibilityIdentifier = "voice-status"
        case (0, 1):
            content.text = "Seed API Key"
            content.secondaryText = SeedKeychain.read() == nil ? "Not set" : "Saved"
            content.image = UIImage(systemName: "key.fill")
            cell.accessibilityIdentifier = "settings.api-key"
        case (0, 2):
            content.text = "Keep Dictation Ready"
            content.secondaryText = preferences.voiceSessionTitle
            content.image = UIImage(systemName: "timer")
            cell.accessibilityIdentifier = "settings.voice-duration"
        case (1, 0):
            content.text = "Try Keyboard"
            content.image = UIImage(systemName: "character.cursor.ibeam")
            cell.accessibilityIdentifier = "settings.try-keyboard"
        case (3, 0):
            content.text = "Mixed Chinese & English"
            content.image = UIImage(systemName: "character.bubble")
            cell.accessoryType = .none
            cell.accessoryView = mixedTypingSwitch
            cell.selectionStyle = .none
            cell.accessibilityIdentifier = "settings.mixed-typing"
        default:
            content.text = "Keyboard Settings"
            content.image = UIImage(systemName: "keyboard")
            cell.accessibilityIdentifier = "settings.keyboard-settings"
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch (indexPath.section, indexPath.row) {
        case (0, 1): navigationController?.pushViewController(SeedKeyViewController(), animated: true)
        case (0, 2):
            let picker = VoiceDurationViewController(minutes: preferences.voiceSessionMinutes) { [weak self] minutes in
                self?.setVoiceSessionMinutes(minutes) == true
            }
            navigationController?.pushViewController(picker, animated: true)
        case (1, 0): navigationController?.pushViewController(KeyboardTestViewController(), animated: true)
        case (1, 1): UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
        default: break
        }
    }

    private func refreshVoiceStatus() {
        guard isViewLoaded else { return }
        tableView.reloadRows(at: [IndexPath(row: 0, section: 0)], with: .none)
    }
    @discardableResult func setVoiceSessionMinutes(_ minutes: Int) -> Bool {
        var updated = preferences
        updated.voiceSessionMinutes = KeyboardPreferences.normalizedSessionMinutes(minutes)
        do { try savePreferences(updated) }
        catch { return false }
        preferences = updated
        VoiceHost.shared.updateSessionDuration(minutes: updated.voiceSessionMinutes)
        tableView.reloadSections(IndexSet(integer: 0), with: .none)
        return true
    }
    private func setHapticStrength(_ strength: Double) {
        guard strength != preferences.hapticStrength else { return }
        let previous = preferences
        preferences.hapticStrength = strength
        do { try savePreferences(preferences) }
        catch {
            preferences = previous; hapticCell.update(previous.hapticStrength)
            let alert = UIAlertController(title: "Couldn’t Save Setting", message: "Please try again.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
            return
        }
        if strength > 0 { feedback.impactOccurred(intensity: CGFloat(strength)) }
        feedback.prepare()
    }

    @objc private func setMixedTyping() {
        let previous = preferences
        preferences.mixedTypingEnabled = mixedTypingSwitch.isOn
        do { try savePreferences(preferences) }
        catch {
            preferences = previous
            mixedTypingSwitch.isOn = previous.mixedTypingEnabled
            let alert = UIAlertController(title: "Couldn’t Save Setting", message: "Please try again.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        }
    }
}

private final class VoiceDurationViewController: UITableViewController {
    private var minutes: Int
    private let save: (Int) -> Bool
    init(minutes: Int, save: @escaping (Int) -> Bool) {
        self.minutes = minutes; self.save = save
        super.init(style: .insetGrouped)
        title = "Keep Dictation Ready"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { KeyboardPreferences.voiceSessionChoices.count }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        "Measured from microphone activation. Changing this also updates the current session. Once it expires, hold a letter key to prepare voice input again."
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let value = KeyboardPreferences.voiceSessionChoices[indexPath.row]
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        content.text = KeyboardPreferences(voiceSessionMinutes: value).voiceSessionTitle
        cell.contentConfiguration = content
        cell.accessoryType = value == minutes ? .checkmark : .none
        cell.accessibilityIdentifier = "voice-duration.\(value)"
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let value = KeyboardPreferences.voiceSessionChoices[indexPath.row]
        guard save(value) else {
            let alert = UIAlertController(title: "Couldn’t Save Setting", message: "Please try again.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default)); present(alert, animated: true)
            return
        }
        minutes = value; tableView.reloadData()
    }
}

private final class HapticStrengthCell: UITableViewCell {
    private let slider = UISlider()
    private let value = UILabel()
    var onPrepare: (() -> Void)?
    var onChange: ((Double) -> Void)?

    init() {
        super.init(style: .default, reuseIdentifier: nil)
        selectionStyle = .none
        let label = UILabel()
        label.text = "Strength"; label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        value.font = .preferredFont(forTextStyle: .body); value.adjustsFontForContentSizeCategory = true
        value.textColor = .secondaryLabel; value.textAlignment = .right
        value.setContentHuggingPriority(.required, for: .horizontal)
        let heading = UIStackView(arrangedSubviews: [label, value]); heading.axis = .horizontal; heading.spacing = 12
        slider.minimumValue = 0; slider.maximumValue = 1
        slider.accessibilityLabel = "Haptic strength"
        slider.accessibilityIdentifier = "keyboard.haptic-strength"
        slider.addTarget(self, action: #selector(prepareFeedback), for: .touchDown)
        slider.addTarget(self, action: #selector(changed), for: .valueChanged)
        let stack = UIStackView(arrangedSubviews: [heading, slider])
        stack.axis = .vertical; stack.spacing = 8; stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        let guide = contentView.layoutMarginsGuide
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: guide.leadingAnchor), stack.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: guide.topAnchor, constant: 6), stack.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -6),
            slider.heightAnchor.constraint(greaterThanOrEqualToConstant: 36)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(_ strength: Double) {
        slider.value = Float(strength)
        let text = strength == 0 ? "Off" : "\(Int((strength * 100).rounded()))%"
        value.text = text; slider.accessibilityValue = text
    }
    @objc private func prepareFeedback() { onPrepare?() }
    @objc private func changed() {
        let strength = KeyboardPreferences.normalizedStrength(Double(slider.value))
        update(strength); onChange?(strength)
    }
}
