import UIKit

/// Standard grouped settings keep status, setup and preferences separate from typing.
final class MainSettingsViewController: UITableViewController {
    private var preferences: KeyboardPreferences
    private let loadPreferences: () -> KeyboardPreferences
    private let savePreferences: (KeyboardPreferences) throws -> Void
    private let mixedTypingSwitch = UISwitch()
    private let sentencePunctuationSwitch = UISwitch()
    private let outputDefaults: UserDefaults
    private let hapticCell = HapticParameterCell(title: "Strength", identifier: "keyboard.haptic-strength", allowsOff: true)
    private let sharpnessCell = HapticParameterCell(title: "Sharpness", identifier: "keyboard.haptic-sharpness", allowsOff: false)
    private let feedback = KeyboardHaptics()
    private var lastHapticPreview: TimeInterval = 0
    private let timings: DictationTimingStore

    init(loadPreferences: @escaping () -> KeyboardPreferences = { .load() },
         savePreferences: @escaping (KeyboardPreferences) throws -> Void = { try $0.save() },
         outputDefaults: UserDefaults = VoiceConfiguration.defaults,
         timings: DictationTimingStore = .shared) {
        self.loadPreferences = loadPreferences; self.savePreferences = savePreferences
        self.timings = timings
        self.outputDefaults = outputDefaults
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
        sharpnessCell.update(preferences.hapticSharpness)
        feedback.configure(preferences)
        hapticCell.onPrepare = { [weak self] in self?.feedback.prepare() }
        hapticCell.onChange = { [weak self] strength in self?.setHaptics(strength: strength) }
        sharpnessCell.onPrepare = { [weak self] in self?.feedback.prepare() }
        sharpnessCell.onChange = { [weak self] sharpness in self?.setHaptics(sharpness: sharpness) }
        mixedTypingSwitch.isOn = preferences.mixedTypingEnabled
        mixedTypingSwitch.accessibilityLabel = "More English Suggestions"
        mixedTypingSwitch.accessibilityIdentifier = "keyboard.mixed-typing"
        mixedTypingSwitch.addTarget(self, action: #selector(setMixedTyping), for: .valueChanged)
        sentencePunctuationSwitch.isOn = DictationOutputSettings.load(outputDefaults).sentencePunctuation
        sentencePunctuationSwitch.accessibilityLabel = "Sentence Punctuation"
        sentencePunctuationSwitch.accessibilityIdentifier = "dictation.sentence-punctuation"
        sentencePunctuationSwitch.addTarget(self, action: #selector(setSentencePunctuation), for: .valueChanged)
        VoiceHost.shared.onChange = { [weak self] in self?.refreshVoiceStatus() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        preferences = loadPreferences()
        hapticCell.update(preferences.hapticStrength)
        sharpnessCell.update(preferences.hapticSharpness)
        feedback.configure(preferences); feedback.prepare()
        mixedTypingSwitch.isOn = preferences.mixedTypingEnabled
        sentencePunctuationSwitch.isOn = DictationOutputSettings.load(outputDefaults).sentencePunctuation
        tableView.reloadData()
    }
    override func viewWillDisappear(_ animated: Bool) {
        feedback.stop(); super.viewWillDisappear(animated)
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 5 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? 4 : section == 1 ? 4 : section == 2 ? 3 : section == 3 ? 1 : section == 4 ? 2 : 3
    }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        ["Voice Input", "Keyboard", "Haptics", "Experimental", "Dictation Timing"][section]
    }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch section {
        case 0: return "The microphone starts when you hold a letter key or Dictate, and stops when you release. Dictation works directly in the keyboard."
        case 1: return "Add vvhisper in Settings → General → Keyboard, then allow Full Access for dictation. Use the language key to switch typing languages."
        case 2: return "Strength controls force. Sharpness changes the tap from soft to crisp. Use − and + for 1% adjustments. Set Strength to Off for no haptics."
        case 4: return "Durations and outcomes of your last \(DictationTimingStore.limit) dictations, stored only on this device. No dictated text or keys are recorded."
        default: return "Chinese mode already suggests recognizable English words. Turn this on to also favor capitalized words and unfinished English spelling."
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == 2, indexPath.row < 2 { return indexPath.row == 0 ? hapticCell : sharpnessCell }
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
            content.text = "Polish Dictation"
            content.secondaryText = DictationPolishSettings.load().enabled ? "On" : "Off"
            content.image = UIImage(systemName: "text.badge.checkmark")
            cell.accessibilityIdentifier = "settings.polishing"
        case (0, 2):
            content = .subtitleCell()
            content.text = "Sentence Punctuation"
            content.secondaryText = "Ending punctuation for one short dictated sentence. Longer passages stay unchanged."
            content.secondaryTextProperties.numberOfLines = 0
            cell.accessoryType = .none; cell.accessoryView = sentencePunctuationSwitch
            cell.selectionStyle = .none
            cell.accessibilityIdentifier = "settings.sentence-punctuation"
        case (0, 3):
            content.text = "Sync and Transfer"
            content.image = UIImage(systemName: "icloud")
            cell.accessibilityIdentifier = "settings.sync-transfer"
        case (1, 0):
            content.text = "Try Keyboard"
            content.image = UIImage(systemName: "character.cursor.ibeam")
            cell.accessibilityIdentifier = "settings.try-keyboard"
        case (1, 2):
            content.text = "Typing Assistance"
            content.image = UIImage(systemName: "textformat.abc")
            cell.accessibilityIdentifier = "settings.typing-assistance"
        case (1, 3):
            content.text = "Snippet"
            content.image = UIImage(systemName: "text.bubble")
            cell.accessibilityIdentifier = "settings.snippets"
        case (2, 2):
            content.text = "Test Tap"; content.image = UIImage(systemName: "hand.tap")
            content.textProperties.color = .systemBlue; cell.accessoryType = .none
            cell.accessibilityIdentifier = "settings.test-haptic"
        case (4, 0):
            content = .subtitleCell()
            content.text = "Release to Text"
            content.secondaryText = DictationTimingSummary(timings.load()).text
            content.secondaryTextProperties.numberOfLines = 0
            content.secondaryTextProperties.color = .secondaryLabel
            content.image = UIImage(systemName: "stopwatch")
            cell.accessoryType = .none; cell.selectionStyle = .none
            cell.accessibilityIdentifier = "settings.dictation-timing"
        case (4, 1):
            content.text = "Copy Timing JSON"; content.image = UIImage(systemName: "doc.on.doc")
            content.textProperties.color = .systemBlue; cell.accessoryType = .none
            cell.accessibilityIdentifier = "settings.copy-dictation-timing"
        case (3, 0):
            content.text = "More English Suggestions"
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
        case (0, 3): navigationController?.pushViewController(ConfigurationTransferViewController(style: .insetGrouped), animated: true)
        case (0, 1): navigationController?.pushViewController(PolishSettingsViewController(), animated: true)
        case (1, 0): navigationController?.pushViewController(KeyboardTestViewController(), animated: true)
        case (1, 1): UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
        case (1, 2): navigationController?.pushViewController(TypingSettingsViewController(load: loadPreferences, save: savePreferences), animated: true)
        case (1, 3): navigationController?.pushViewController(SnippetListViewController(), animated: true)
        case (2, 2): feedback.tap()
        case (4, 1):
            UIPasteboard.general.string = timings.exportJSON()
            let alert = UIAlertController(title: "Timing Copied", message: "Durations and outcomes only, without dictated text or keys.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        default: break
        }
    }

    private func refreshVoiceStatus() {
        guard isViewLoaded else { return }
        tableView.reloadRows(at: [IndexPath(row: 0, section: 0)], with: .none)
    }
    @objc private func setSentencePunctuation() {
        DictationOutputSettings(sentencePunctuation: sentencePunctuationSwitch.isOn).save(outputDefaults)
    }
    @discardableResult func setHaptics(strength: Double? = nil, sharpness: Double? = nil) -> Bool {
        let previous = preferences
        if let strength { preferences.hapticStrength = KeyboardPreferences.normalizedStrength(strength) }
        if let sharpness { preferences.hapticSharpness = KeyboardPreferences.normalizedSharpness(sharpness) }
        guard previous != preferences else { return true }
        do { try savePreferences(preferences) }
        catch {
            preferences = previous; hapticCell.update(previous.hapticStrength); sharpnessCell.update(previous.hapticSharpness)
            let alert = UIAlertController(title: "Couldn’t Save Setting", message: "Please try again.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
            return false
        }
        hapticCell.update(preferences.hapticStrength); sharpnessCell.update(preferences.hapticSharpness)
        feedback.configure(preferences)
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastHapticPreview >= 0.07 { feedback.tap(); lastHapticPreview = now }
        feedback.prepare()
        return true
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

private final class HapticParameterCell: UITableViewCell {
    private let slider = UISlider()
    private let stepper = UIStepper()
    private let value = UILabel()
    private let allowsOff: Bool
    var onPrepare: (() -> Void)?
    var onChange: ((Double) -> Void)?

    init(title: String, identifier: String, allowsOff: Bool) {
        self.allowsOff = allowsOff
        super.init(style: .default, reuseIdentifier: nil)
        selectionStyle = .none
        let label = UILabel()
        label.text = title; label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        value.font = .preferredFont(forTextStyle: .body); value.adjustsFontForContentSizeCategory = true
        value.textColor = .secondaryLabel; value.textAlignment = .right
        value.setContentHuggingPriority(.required, for: .horizontal)
        let heading = UIStackView(arrangedSubviews: [label, value]); heading.axis = .horizontal; heading.spacing = 12
        slider.minimumValue = 0; slider.maximumValue = 1
        slider.accessibilityLabel = "Haptic \(title.lowercased())"
        slider.accessibilityIdentifier = identifier
        slider.addTarget(self, action: #selector(prepareFeedback), for: .touchDown)
        slider.addTarget(self, action: #selector(changed), for: .valueChanged)
        stepper.minimumValue = 0; stepper.maximumValue = 100; stepper.stepValue = 1
        stepper.accessibilityLabel = "Fine-adjust haptic \(title.lowercased())"
        stepper.accessibilityIdentifier = identifier + ".fine"
        stepper.addTarget(self, action: #selector(prepareFeedback), for: .touchDown)
        stepper.addTarget(self, action: #selector(stepped), for: .valueChanged)
        let controls = UIStackView(arrangedSubviews: [slider, stepper]); controls.spacing = 16; controls.alignment = .center
        let stack = UIStackView(arrangedSubviews: [heading, controls])
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
        stepper.value = (strength * 100).rounded()
        let text = strength == 0 && allowsOff ? "Off" : "\(Int((strength * 100).rounded()))%"
        value.text = text; slider.accessibilityValue = text; stepper.accessibilityValue = text
    }
    @objc private func prepareFeedback() { onPrepare?() }
    @objc private func changed() {
        let strength = KeyboardPreferences.normalizedStrength(Double(slider.value))
        update(strength); onChange?(strength)
    }
    @objc private func stepped() { let value = stepper.value / 100; update(value); onChange?(value) }
}
