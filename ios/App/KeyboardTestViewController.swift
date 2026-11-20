import UIKit

final class KeyboardTestViewController: UIViewController, UITextViewDelegate {
    private let editor = UITextView()
    private let placeholder = UILabel()
    private var focusedOnce = false
    #if DEBUG
    private var verificationTimer: Timer?
    #endif

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Try Keyboard"
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = .systemGroupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Clear", style: .plain, target: self, action: #selector(clearText))
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "keyboard-test.clear"
        let instruction = UILabel()
        instruction.text = "Hold a letter key or a gap to dictate. Slide to Delete to cancel, Return to send, or release over Language to translate."
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
        if !focusedOnce {
            focusedOnce = true
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--verify-cursor") { beginCursorVerification() }
            if ProcessInfo.processInfo.arguments.contains("--verify-haptics") { beginHapticVerification() }
            if ProcessInfo.processInfo.arguments.contains("--verify-dictation") { beginDictationVerification() }
            #endif
            editor.becomeFirstResponder()
        }
    }
    #if DEBUG
    private func beginDictationVerification() {
        let request = DictationDeviceVerification.Request(
            emptyStart: ProcessInfo.processInfo.arguments.contains("--verify-dictation-empty"),
            chinese: ProcessInfo.processInfo.arguments.contains("--verify-dictation-chinese"))
        editor.text = request.prefix; placeholder.isHidden = true
        editor.selectedRange = NSRange(location: request.prefix.utf16.count, length: 0)
        VoiceIPC.remove("dictation-check-result.json")
        try? VoiceIPC.write(request, to: "dictation-check-request.json")
        var markedWhilePending = false
        var completedAt: Date?
        verificationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let result = VoiceIPC.read("dictation-check-result.json", as: DictationDeviceVerification.Result.self)
                let finished = result?.id == request.id
                if !finished { markedWhilePending = markedWhilePending || self.editor.markedTextRange != nil }
                if finished, completedAt == nil { completedAt = Date() }
                guard completedAt.map({ Date().timeIntervalSince($0) >= 0.5 }) == true || !request.isFresh else { return }
                let report = DictationDeviceVerification.Report(completed: finished && result?.completed == true,
                    markedWhilePending: markedWhilePending, markedAfterCompletion: self.editor.markedTextRange != nil,
                    finalTextMatches: self.editor.text == request.final, elapsed: result?.elapsed ?? 12, state: result?.state ?? [:])
                let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                try? JSONEncoder().encode(report).write(to: directory.appendingPathComponent("dictation-device-check.json"), options: .atomic)
                self.verificationTimer?.invalidate(); self.verificationTimer = nil
                VoiceIPC.remove("dictation-check-request.json"); VoiceIPC.remove("dictation-check-result.json")
                self.navigationItem.prompt = report.passed ? "Dictation check passed" : "Dictation check needs attention"
            }
        }
    }
    private func beginHapticVerification() {
        let request = HapticDeviceVerification.Request(id: UUID(), createdAt: Date(),
            observeTouches: ProcessInfo.processInfo.arguments.contains("--observe-haptic-touches"))
        editor.text = request.fixture; placeholder.isHidden = true
        editor.selectedRange = NSRange(location: request.fixture.utf16.count, length: 0)
        VoiceIPC.remove("haptic-check-result.json")
        try? VoiceIPC.write(request, to: "haptic-check-request.json")
        verificationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let report = VoiceIPC.read("haptic-check-result.json", as: HapticDeviceVerification.Report.self)
                let finished = report?.id == request.id
                guard finished || !request.isFresh else { return }
                if finished, let report {
                    let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    try? JSONEncoder().encode(report).write(to: directory.appendingPathComponent("haptic-device-check.json"), options: .atomic)
                }
                self.verificationTimer?.invalidate(); self.verificationTimer = nil
                VoiceIPC.remove("haptic-check-request.json"); VoiceIPC.remove("haptic-check-result.json")
                self.navigationItem.prompt = finished && report?.passed == true ? "Haptic check passed" : "Haptic check needs attention"
            }
        }
    }
    private func beginCursorVerification() {
        let request = CursorDeviceVerification.Request(id: UUID(), createdAt: Date(),
            legacyAcknowledgement: ProcessInfo.processInfo.arguments.contains("--legacy-cursor-check"))
        editor.text = request.fixture; placeholder.isHidden = true
        editor.selectedRange = NSRange(location: request.fixture.utf16.count, length: 0)
        VoiceIPC.remove("cursor-check-result.json")
        try? VoiceIPC.write(request, to: "cursor-check-request.json")
        verificationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let result = VoiceIPC.read("cursor-check-result.json", as: CursorDeviceVerification.Result.self)
                let finished = result?.id == request.id
                guard finished || !request.isFresh else { return }
                let report = CursorDeviceVerification.Report(id: request.id, heldAfterPause: finished && result?.heldAfterPause == true,
                    released: finished && result?.released == true, textUnchanged: self.editor.text == request.fixture,
                    expectedCaret: request.fixture.utf16.count - 3, actualCaret: self.editor.selectedRange.location, timedOut: !finished,
                    events: finished ? result?.events ?? [] : [], customHapticPlayed: result?.customHapticPlayed,
                    hapticErrorCode: result?.hapticErrorCode)
                let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                try? JSONEncoder().encode(report).write(to: directory.appendingPathComponent("cursor-device-check.json"), options: .atomic)
                self.verificationTimer?.invalidate(); self.verificationTimer = nil
                VoiceIPC.remove("cursor-check-request.json"); VoiceIPC.remove("cursor-check-result.json")
                self.navigationItem.prompt = report.passed ? "Cursor check passed" : "Cursor check needs attention"
            }
        }
    }
    #endif
    func textViewDidChange(_ textView: UITextView) { placeholder.isHidden = !textView.text.isEmpty }
    @objc private func clearText() {
        editor.text = ""; placeholder.isHidden = false; editor.becomeFirstResponder()
    }
}
