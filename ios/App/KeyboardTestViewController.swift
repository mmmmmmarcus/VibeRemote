import UIKit

final class KeyboardTestViewController: UIViewController, UITextViewDelegate {
    private let editor = UITextView()
    private let placeholder = UILabel()
    private var focusedOnce = false

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Try Keyboard"
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = .systemGroupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Clear", style: .plain, target: self, action: #selector(clearText))
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "keyboard-test.clear"
        let instruction = UILabel()
        instruction.text = "Hold a letter key or a gap to dictate. Slide to Delete to cancel, or Return to send after polishing."
        instruction.font = .preferredFont(forTextStyle: .subheadline)
        instruction.adjustsFontForContentSizeCategory = true
        instruction.textColor = .secondaryLabel; instruction.numberOfLines = 0
        editor.delegate = self
        editor.font = .preferredFont(forTextStyle: .body); editor.adjustsFontForContentSizeCategory = true
        editor.backgroundColor = .secondarySystemGroupedBackground
        editor.layer.cornerRadius = 16; editor.layer.cornerCurve = .continuous
        editor.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        editor.alwaysBounceVertical = true
        editor.keyboardDismissMode = .interactive
        editor.accessibilityLabel = "Keyboard test field"
        editor.accessibilityIdentifier = "keyboard-test-field"
        placeholder.text = "Start typing…"; placeholder.textColor = .placeholderText
        placeholder.font = .preferredFont(forTextStyle: .body); placeholder.adjustsFontForContentSizeCategory = true
        placeholder.isUserInteractionEnabled = false
        editor.addSubview(placeholder); placeholder.translatesAutoresizingMaskIntoConstraints = false
        for item in [instruction, editor] { item.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(item) }
        NSLayoutConstraint.activate([
            instruction.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            instruction.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            instruction.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            editor.topAnchor.constraint(equalTo: instruction.bottomAnchor, constant: 16),
            editor.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            editor.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            editor.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -12),
            placeholder.topAnchor.constraint(equalTo: editor.topAnchor, constant: 16),
            placeholder.leadingAnchor.constraint(equalTo: editor.leadingAnchor, constant: 17)
        ])
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !focusedOnce { focusedOnce = true; editor.becomeFirstResponder() }
    }
    func textViewDidChange(_ textView: UITextView) { placeholder.isHidden = !textView.text.isEmpty }
    @objc private func clearText() {
        editor.text = ""; placeholder.isHidden = false; editor.becomeFirstResponder()
    }
}
