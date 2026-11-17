import UIKit
import SwiftUI
#if KEYBOARD_TESTING
@testable import vvhisper
#endif

final class KeyboardViewController: UIInputViewController {
#if KEYBOARD_TESTING
    // Unit-test controllers are not attached to a system keyboard host.
    var testingDocumentProxy: UITextDocumentProxy?
    var testingLandscape: Bool?
    var testingVoiceAvailable = false
    private(set) var testingVoiceCommands: [VoiceCommand] = []
    override var textDocumentProxy: UITextDocumentProxy { testingDocumentProxy ?? super.textDocumentProxy }
#endif
    private let rows = UIStackView()
    private let touchSurface = KeyboardTouchSurface()
    private let keyPreview = KeyPreviewView()
    private weak var previewKey: KeyControl?
    private let symbolAlternatives = SymbolAlternativesView()
    private weak var symbolKey: KeyControl?
    private var symbolDestination: KeyboardTextDestination?
    private let status = UILabel()
    private var keyboardHeight: NSLayoutConstraint!
    private var layoutWidth: CGFloat = 0
    private var layoutLandscape = false
    private var metrics = KeyboardMetrics(width: 466)
    private let candidateScroll = UIScrollView()
    private let candidateRow = UIStackView()
    private let candidateProvider = PinyinCandidates()
    private lazy var bilingualProvider = BilingualCandidates()
    private var visibleCandidates: [PinyinCandidates.Candidate] = []
    private var language = KeyboardLanguage.load()
    private var usesPinyin: Bool { language == .chinese && pinyinAvailable }
    private var mixedTypingEnabled = false
    private var compositionUsesMixedTyping = false
    private var languageTitle: String { language == .chinese && mixedTypingEnabled ? "中英" : language.keyTitle }
    private var chineseModeName: String { mixedTypingEnabled ? "Mixed Chinese and English" : "Chinese" }
    private lazy var tapFeedback = UIImpactFeedbackGenerator(style: .light, view: view)
    private var hapticStrength = 0.45
    private var lastPreferenceRefresh = Date.distantPast
    private var pinyinAvailable = true
    private var compositionCase = EnglishLetterCase.lowercase
    private var pinyinReady = false
    private var pinyin = PinyinEngine.Snapshot()
    private var typingPending = false
    private var deferredTaps: [String] = []
    private var typingGeneration = 0
    private var typingDocument: UUID?
    private var typingBefore: String?
    private var typingAfter: String?
    private var typingSelection: String?
    private var insertingTypedText = false
    private var launchLink: UIHostingController<VoiceLaunchLink>?
    private var hostOpenURL: OpenURLAction?
    private var activationRequest: VoiceActivationRequest?
    private var offersHostLaunch = false
    private var keyboardVisible = false
    private var shifted = true
    private var capsLock = false
    private var page = 0
    private var timer: Timer?
    private var command: VoiceCommand?
    private var dictationText: DictationTextSession?
    private var releaseTime: Date?
    private var errorUntil = Date.distantPast
    private var currentKey: KeyControl?
    private weak var dictationTargetKey: KeyControl?
    private var keys: [KeyControl] = []
    private var deleteDestination: KeyboardTextDestination?
    private var clearText: ClearTextSession?
    private var lastShift = Date.distantPast
    private var started = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        // The system owns the keyboard material and device's bottom safe area.
        // Content dimensions come from the iPhone / Duo variants in the design reference.
        keyboardHeight = view.heightAnchor.constraint(equalToConstant: metrics.contentHeight)
        keyboardHeight.priority = .init(999)
        keyboardHeight.isActive = true
        status.font = .systemFont(ofSize: 14)
        status.textAlignment = .center; status.textColor = .label; status.numberOfLines = 2
        status.accessibilityIdentifier = "keyboard.voice-status"
        status.isHidden = true
        candidateScroll.showsHorizontalScrollIndicator = false
        // Eight-point button padding preserves the existing 22-point text spacing.
        candidateRow.axis = .horizontal; candidateRow.spacing = 6; candidateRow.distribution = .fill
        candidateRow.translatesAutoresizingMaskIntoConstraints = false
        candidateScroll.addSubview(candidateRow)
        NSLayoutConstraint.activate([
            candidateRow.leadingAnchor.constraint(equalTo: candidateScroll.contentLayoutGuide.leadingAnchor, constant: 2),
            candidateRow.trailingAnchor.constraint(equalTo: candidateScroll.contentLayoutGuide.trailingAnchor, constant: -12),
            candidateRow.topAnchor.constraint(equalTo: candidateScroll.contentLayoutGuide.topAnchor),
            candidateRow.bottomAnchor.constraint(equalTo: candidateScroll.contentLayoutGuide.bottomAnchor),
            candidateRow.heightAnchor.constraint(equalTo: candidateScroll.frameLayoutGuide.heightAnchor)
        ])
        rows.axis = .vertical
        touchSurface.addSubview(rows)
        for item in [candidateScroll, touchSurface, status] { view.addSubview(item) }
        let link = UIHostingController(rootView: VoiceLaunchLink(
            resolve: { [weak self] in self?.hostOpenURL = $0 },
            activate: { [weak self] in self?.openHost(using: $0) }
        ))
        addChild(link); link.didMove(toParent: self)
        link.view.backgroundColor = .clear
        launchLink = link
        view.addSubview(link.view)
        view.addSubview(keyPreview)
        view.addSubview(symbolAlternatives)
        refreshKeyboardAppearance()
        shifted = false
        refreshKeyboardPreferences()
        buildKeys()
        renderCandidates()
        PinyinEngine.shared.perform(.prepare) { [weak self] result in
            guard let self else { return }
            self.pinyinReady = true
            if let error = result.error { self.pinyinAvailable = false; self.showError(error); self.buildKeys() }
            self.renderCandidates()
            self.drainTypingTaps()
        }
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        keyboardVisible = true
        refreshKeyboardAppearance()
        refreshKeyboardPreferences()
        tapFeedback.prepare()
        if timer == nil { timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in Task { @MainActor in self?.poll() } } }
        poll()
    }
    override func viewWillDisappear(_ animated: Bool) {
        hideKeyPreview()
        hideSymbolAlternatives()
        keyboardVisible = false
        clearText = nil; deleteDestination = nil
        // A touch cannot survive an app switch. Arming never resumes an old hold.
        cancelHold() // Preserve visible speech when the keyboard disappears.
        currentKey?.cancelPress(); currentKey = nil
        activationRequest = nil; offersHostLaunch = false
        resetComposition(); timer?.invalidate(); timer = nil; super.viewWillDisappear(animated)
    }
    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        refreshKeyboardAppearance()
        cancelSymbolsIfDestinationChanged()
        cancelDeletionIfDestinationChanged()
        if command != nil, dictationText?.isUpdating != true, !sameDestination { cancelHold(); showError("Text field changed. Dictation cancelled.") }
        if !insertingTypedText, typingDocument != nil, !sameTypingDestination { resetComposition() }
        if command == nil, !usesPinyin, page == 0, !capsLock {
            let context = textDocumentProxy.documentContextBeforeInput ?? ""
            let shouldShift = textDocumentProxy.autocapitalizationType != UITextAutocapitalizationType.none && (context.isEmpty || context.hasSuffix("\n") || context.hasSuffix(". ") || context.hasSuffix("! ") || context.hasSuffix("? "))
            if shifted != shouldShift { shifted = shouldShift; updateKeyLegends() }
        }
    }
    override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        cancelSymbolsIfDestinationChanged()
        cancelDeletionIfDestinationChanged()
        if command != nil, dictationText?.isUpdating != true, !sameDestination { cancelHold(); showError("Cursor moved. Dictation cancelled.") }
        if !insertingTypedText, typingDocument != nil, !sameTypingDestination { resetComposition() }
    }
    private var sameDestination: Bool {
        dictationText?.matches(textDocumentProxy) == true
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = view.bounds.width
        guard width > 0 else { return }
        var landscape = view.window?.windowScene?.effectiveGeometry.interfaceOrientation.isLandscape == true
#if KEYBOARD_TESTING
        landscape = testingLandscape ?? landscape
#endif
        if abs(width - layoutWidth) > 0.5 || landscape != layoutLandscape {
            layoutWidth = width; layoutLandscape = landscape
            metrics = KeyboardMetrics(width: width, landscape: landscape)
            keyboardHeight.constant = metrics.contentHeight
            buildKeys()
        }
        touchSurface.frame = CGRect(x: 0, y: metrics.candidateHeight, width: width,
                                    height: metrics.contentHeight - metrics.candidateHeight - metrics.bottomInset)
        rows.frame = CGRect(x: metrics.inset, y: 0, width: width - 2 * metrics.inset, height: touchSurface.bounds.height)
        candidateScroll.frame = CGRect(x: 0, y: 1, width: width, height: metrics.candidateHeight - 5)
        status.frame = CGRect(x: 12, y: 1, width: width - 24, height: 42)
        launchLink?.view.frame = status.frame
    }

    private func buildKeys() {
        hideKeyPreview()
        hideSymbolAlternatives()
        if command != nil { cancelHold() } // Rotation also invalidates a released hold awaiting polish.
        if currentKey?.isPressed == true {
            cancelHold() // A layout change ends the touch, preserving visible speech.
            currentKey?.cancelPress()
        }
        currentKey = nil
        keys.removeAll()
        touchSurface.controls.removeAll()
        for v in rows.arrangedSubviews { rows.removeArrangedSubview(v); v.removeFromSuperview() }
        rows.spacing = metrics.rowGap
        if metrics.split { buildSplitKeys(); updateHeader(); return }
        let topLetters = "qwertyuiop".map { String($0) }
        let middleLetters = "asdfghjkl".map { String($0) }
        let bottomLetters = "zxcvbnm".map { String($0) }
        let letters: [[String]] = [topLetters, middleLetters, ["shift"] + bottomLetters + ["delete"]]
        let numbers = [Array("1234567890").map(String.init), ["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""], ["#+=", ".", ",", "?", "!", "'", "delete"]]
        let symbols = [["[", "]", "{", "}", "#", "%", "^", "*", "+", "="], ["_", "\\", "|", "~", "<", ">", "€", "£", "¥", "•"], ["123", ".", ",", "?", "!", "'", "delete"]]
        let contents = page == 0 ? letters : page == 1 ? numbers : symbols
        func row() -> UIStackView {
            let row = UIStackView(); row.axis = .horizontal; row.spacing = metrics.keyGap
            row.heightAnchor.constraint(equalToConstant: metrics.keyHeight).isActive = true
            rows.addArrangedSubview(row)
            return row
        }
        for (index, values) in contents.enumerated() {
            let line = row()
            if index == 2 {
                line.spacing = metrics.sideGap
                let first = makeKey(values.first!), last = makeKey(values.last!)
                first.widthAnchor.constraint(equalToConstant: metrics.shiftWidth).isActive = true
                let middle = UIStackView(); middle.axis = .horizontal; middle.spacing = metrics.keyGap; middle.distribution = .fillEqually
                for value in values.dropFirst().dropLast() { middle.addArrangedSubview(makeKey(value)) }
                for item in [first, middle, last] { line.addArrangedSubview(item) }
                last.widthAnchor.constraint(equalTo: first.widthAnchor).isActive = true
            } else {
                line.distribution = .fillEqually
                if page == 0, index == 1 {
                    line.isLayoutMarginsRelativeArrangement = true
                    line.layoutMargins = UIEdgeInsets(top: 0, left: metrics.middleInset, bottom: 0, right: metrics.middleInset)
                }
                for value in values { line.addArrangedSubview(makeKey(value)) }
            }
        }
        let bottom = row()
        let mode = makeKey(page == 0 ? "123" : "ABC")
        mode.widthAnchor.constraint(equalToConstant: metrics.modeWidth).isActive = true
        bottom.addArrangedSubview(mode)
        if metrics.inlineAccessories {
            bottom.addArrangedSubview(makeLanguageKey())
            bottom.addArrangedSubview(makeSwitcher())
        }
        if textDocumentProxy.keyboardType == .emailAddress || textDocumentProxy.keyboardType == .URL {
            let at = makeKey(textDocumentProxy.keyboardType == .emailAddress ? "@" : "/")
            at.widthAnchor.constraint(equalToConstant: 32).isActive = true; bottom.addArrangedSubview(at)
        }
        bottom.addArrangedSubview(makeKey("space"))
        if metrics.inlineAccessories { bottom.addArrangedSubview(makeAccessoryReturn()) }
        else if metrics.belowAccessories {
            let accessories = UIStackView(); accessories.axis = .horizontal
            accessories.spacing = metrics.keyGap
            accessories.isLayoutMarginsRelativeArrangement = true
            let inset: CGFloat = metrics.arrangement == .innerPortrait ? 45.33 : 17
            accessories.layoutMargins = UIEdgeInsets(top: 0, left: inset, bottom: 0, right: inset)
            accessories.heightAnchor.constraint(equalToConstant: 50 - metrics.rowGap).isActive = true
            accessories.addArrangedSubview(makeLanguageKey())
            accessories.addArrangedSubview(makeSwitcher())
            accessories.addArrangedSubview(UIView())
            accessories.addArrangedSubview(makeAccessoryReturn())
            rows.addArrangedSubview(accessories)
        }
        updateHeader()
    }

    /// Duo's native inner-landscape layout duplicates G/V near the thumb boundary.
    private func buildSplitKeys() {
        let leftLetters = [["q", "w", "e", "r", "t"], ["a", "s", "d", "f", "g"], ["shift", "z", "x", "c", "v"]]
        let rightLetters = [["y", "u", "i", "o", "p"], ["g", "h", "j", "k", "l"], ["v", "b", "n", "m", "delete"]]
        let leftNumbers = [["1", "2", "3", "4", "5"], ["-", "/", ":", ";", "("], ["#+=", ".", ",", "?", "!"]]
        let rightNumbers = [["6", "7", "8", "9", "0"], [")", "$", "&", "@", "\""], [".", ",", "?", "'", "delete"]]
        let leftSymbols = [["[", "]", "{", "}", "#"], ["_", "\\", "|", "~", "<"], ["123", ".", ",", "?", "!"]]
        let rightSymbols = [["%", "^", "*", "+", "="], [">", "€", "£", "¥", "•"], [".", ",", "?", "'", "delete"]]
        let left = page == 0 ? leftLetters : page == 1 ? leftNumbers : leftSymbols
        let right = page == 0 ? rightLetters : page == 1 ? rightNumbers : rightSymbols
        let halfWidth: CGFloat = 303.667
        for index in 0..<4 {
            let row = UIStackView(); row.axis = .horizontal
            row.heightAnchor.constraint(equalToConstant: metrics.keyHeight).isActive = true
            rows.addArrangedSubview(row)
            for isRight in [false, true] {
                if isRight { row.addArrangedSubview(UIView()) }
                let half = UIStackView(); half.axis = .horizontal; half.spacing = metrics.keyGap
                half.widthAnchor.constraint(equalToConstant: halfWidth).isActive = true
                half.isLayoutMarginsRelativeArrangement = true
                half.layoutMargins = .zero
                half.insetsLayoutMarginsFromSafeArea = false
                half.preservesSuperviewLayoutMargins = false
                row.addArrangedSubview(half)
                if index < 3 {
                    let inset: CGFloat = index < 2 ? 28.667 : 0
                    let indentLeading = index == 0 ? isRight : !isRight
                    half.layoutMargins = UIEdgeInsets(top: 0, left: indentLeading ? inset : 0, bottom: 0, right: indentLeading ? 0 : inset)
                    let values = isRight ? right[index] : left[index]
                    half.distribution = index < 2 ? .fillEqually : .fill
                    var letter: KeyControl?
                    for (column, value) in values.enumerated() {
                        let key = makeKey(value); half.addArrangedSubview(key)
                        let wide = index == 2 && (isRight ? column == 4 : column == 0)
                        if index == 2 {
                            if wide { key.widthAnchor.constraint(equalToConstant: 64).isActive = true }
                            else if let letter { key.widthAnchor.constraint(equalTo: letter.widthAnchor).isActive = true }
                            else { letter = key }
                        }
                        if index == 2 && (isRight ? column == 3 : column == 0) { half.setCustomSpacing(22, after: key) }
                    }
                } else if isRight {
                    half.addArrangedSubview(makeKey("space"))
                    let enter = makeKey("return"); enter.widthAnchor.constraint(equalToConstant: metrics.returnWidth).isActive = true
                    half.addArrangedSubview(enter)
                } else {
                    let mode = makeKey(page == 0 ? "123" : "ABC"); mode.widthAnchor.constraint(equalToConstant: 46.667).isActive = true
                    half.addArrangedSubview(mode)
                    half.addArrangedSubview(makeLanguageKey())
                    let switcher = makeSwitcher()
                    half.addArrangedSubview(switcher)
                    half.addArrangedSubview(makeKey("space"))
                }
            }
        }
    }

    private func makeSwitcher() -> UIButton {
        // Like the native smiley key, this opens the system input-mode picker.
        // iOS owns the list, including its emoji keyboard; no private keyboard API.
        let button = KeyboardSwitcherButton(type: .custom)
        button.touchSurface = touchSurface
        touchSurface.controls.append(button)
        // Use the square glyph, not the tall Figma side-accessory artboard.
        let icon = UIImageView(image: UIImage(named: "KeyboardSwitcher")?.withRenderingMode(.alwaysTemplate))
        icon.contentMode = .scaleAspectFit
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.isUserInteractionEnabled = false
        button.addSubview(icon)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 42),
            icon.heightAnchor.constraint(equalToConstant: 42)
        ])
        button.tintColor = .label
        if metrics.inlineAccessories || metrics.split {
            button.backgroundColor = KeyboardMetrics.keyFill
            button.layer.cornerRadius = metrics.cornerRadius
            button.layer.cornerCurve = .continuous
        }
        button.accessibilityIdentifier = "keyboard.key.globe"
        button.accessibilityLabel = "Next keyboard"
        button.accessibilityHint = "Choose a keyboard, including Emoji."
        button.widthAnchor.constraint(equalToConstant: metrics.switcherWidth).isActive = true
        button.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        button.addAction(UIAction { [weak self] _ in
            self?.clearText = nil
            self?.currentKey?.cancelPress()
            self?.tapFeedback.prepare()
            self?.resetComposition()
        }, for: .touchDown)
        button.addAction(UIAction { [weak self] _ in self?.playTapFeedback() }, for: .touchUpInside)
        return button
    }

    private func makeAccessoryReturn() -> KeyControl {
        let key = makeKey("return")
        key.widthAnchor.constraint(equalToConstant: metrics.returnWidth).isActive = true
        return key
    }

    private func makeLanguageKey() -> KeyControl {
        let key = makeKey("language")
        key.widthAnchor.constraint(equalToConstant: metrics.switcherWidth).isActive = true
        return key
    }

    private func updateHeader() {
        let voiceVisible = command != nil || activationRequest != nil || Date() < errorUntil
        setRecordingAppearance(command?.phase == .recording, voiceVisible: voiceVisible)
        candidateScroll.isHidden = voiceVisible
        status.textColor = .label
        let ready = hasFullAccess && VoiceIPC.read("ready.json", as: VoiceReadiness.self)?.isFresh == true
        launchLink?.view.isHidden = ready || !voiceVisible || command != nil || activationRequest != nil || !offersHostLaunch
    }
    func setRecordingAppearance(_ recording: Bool, voiceVisible: Bool) {
        if recording { hideKeyPreview() }
        status.isHidden = recording || !voiceVisible
        for key in keys {
            key.label.isHidden = recording
            if key.value == "return" {
                key.icon.image = recording ? UIImage(systemName: "paperplane") : key.restingIcon
            }
        }
    }

    private func updateKeyLegends() {
        for key in keys {
            if page == 0, key.value.count == 1, key.value.first?.isASCII == true, key.value.first?.isLetter == true {
                let title = shifted ? key.value.uppercased() : key.value
                key.label.text = title; key.accessibilityLabel = title
            } else if key.value == "shift" {
                key.icon.image = UIImage(systemName: capsLock ? "capslock.fill" : shifted ? "shift.fill" : "shift")
            } else if key.value == "language" {
                updateLanguageKey(key)
            }
        }
    }

    private func updateLanguageKey(_ key: KeyControl) {
        key.label.text = languageTitle
        key.label.font = .systemFont(ofSize: languageTitle == "中英" ? 16 : 18)
        key.accessibilityLabel = language == .chinese ? chineseModeName : language.name
        key.accessibilityHint = "Switch to \(language == .chinese ? "English" : chineseModeName)"
    }

    private func makeKey(_ rawValue: String) -> KeyControl {
        let value = page > 0 ? KeyboardSymbols.key(rawValue, language: language) : rawValue
        let key = KeyControl()
        key.value = value
        key.touchSurface = touchSurface
        touchSurface.controls.append(key)
        keys.append(key)
        key.isDeleteKey = value == "delete"
        let ordinary = value.count == 1
        key.backgroundColor = KeyboardMetrics.keyFill
        key.layer.cornerRadius = metrics.cornerRadius; key.layer.cornerCurve = .continuous
        key.label.font = ordinary ? metrics.letterFont : .systemFont(ofSize: 18)
        key.label.textColor = .label
        key.labelOffset = ordinary ? -1.5 : -1
        var title = value
        if value == "language" { title = languageTitle }
        if ordinary && page == 0 { title = shifted ? value.uppercased() : value }
        if value == "space" { title = "" }
        if value == "shift" { key.icon.image = UIImage(systemName: capsLock ? "capslock.fill" : shifted ? "shift.fill" : "shift") }
        else if value == "delete" { key.icon.image = UIImage(systemName: "delete.left") }
        else if value == "return" {
            switch textDocumentProxy.returnKeyType {
            case .send: title = "send"
            case .search: title = "search"
            case .go: title = "go"
            case .done: title = "done"
            case .next: title = "next"
            default: title = "return"; key.icon.image = UIImage(systemName: "return")
            }
            if key.icon.image == nil { key.label.text = title }
        } else { key.label.text = title }
        key.accessibilityIdentifier = "keyboard.key.\(value)"
        key.accessibilityLabel = value == "space" ? "space" : title; key.accessibilityTraits = .keyboardKey
        if value == "language" { updateLanguageKey(key) }
        key.restingIcon = key.icon.image
        key.onPress = { [weak self, weak key] in
            guard let self, let key, self.keys.contains(where: { $0 === key }) else { return false }
            self.clearText = nil
            if let current = self.currentKey, current !== key {
                self.cancelHold()
                // A second thumb is normal typing: commit the pending tap in
                // press order, then consume the first finger's later release.
                if self.symbolKey === current { current.cancelPress() }
                else if current.allowsRolloverCommit { current.releasePress() }
                else { current.cancelPress() } // Never submit or change layouts from another finger's press.
            }
            // The preceding action may have invalidated this key's layout.
            guard self.keys.contains(where: { $0 === key }) else { return false }
            self.currentKey = key
            if key.isDeleteKey {
                self.cancelHold()
                self.deleteDestination = KeyboardTextDestination(self.textDocumentProxy)
            }
            self.tapFeedback.prepare()
            return true
        }
        key.onTap = { [weak self] in
            self?.playTapFeedback()
            self?.tap(value)
        }
        if key.isDeleteKey {
            key.accessibilityHint = "Hold to keep deleting. Hold and swipe left to clear the field."
            key.onDeleteRepeat = { [weak self] in self?.repeatDelete() }
            key.onClearAll = { [weak self] in self?.clearAllText() }
        } else if page == 0, ordinary, value.first?.isASCII == true, value.first?.isLetter == true {
            key.accessibilityHint = "Hold to dictate. Slide to Delete to cancel, or Return to send after polishing."
            key.onHold = { [weak self] in self?.beginHold() }
        } else if page > 0, ordinary, !KeyboardSymbols.alternatives(for: value).isEmpty {
            key.accessibilityHint = "Hold and slide to choose an alternative symbol."
            key.onHold = { [weak self, weak key] in
                guard let self, let key else { return }
                self.showSymbolAlternatives(for: key)
            }
            key.accessibilityCustomActions = KeyboardSymbols.alternatives(for: value).dropFirst().map { symbol in
                UIAccessibilityCustomAction(name: symbol) { [weak self] _ in self?.tap(symbol); return true }
            }
        }
        key.onGapHold = { [weak self] in
            // Before the threshold, a gap beside Delete can still be a guarded
            // delete tap. Once it becomes dictation, editing ownership ends.
            self?.deleteDestination = nil
            self?.beginHold()
        }
        key.onHoldMove = { [weak self, weak key] point in
            guard let self, let key else { return false }
            if self.symbolKey === key {
                self.symbolAlternatives.track(key.convert(point, to: self.view))
                return true
            }
            return self.moveDictationTouch(to: point, from: key)
        }
        key.onRelease = { [weak self, weak key] in
            if let self, let key, self.symbolKey === key {
                let choice = self.symbolDestination == KeyboardTextDestination(self.textDocumentProxy) ? self.symbolAlternatives.selectedSymbol : nil
                self.hideSymbolAlternatives()
                if let choice { self.playTapFeedback(); self.tap(choice) }
                return
            }
            self?.deleteDestination = nil
            self?.endHold()
            self?.clearDictationTarget()
        }
        key.onCancel = { [weak self, weak key] in
            if let self, let key, self.symbolKey === key { self.hideSymbolAlternatives() }
            self?.deleteDestination = nil
            self?.cancelHold(discard: true)
        }
        if ordinary {
            key.onPreviewChange = { [weak self, weak key] visible in
                guard let self, let key else { return }
                if visible { self.showKeyPreview(for: key) }
                else if self.previewKey === key { self.hideKeyPreview() }
            }
        }
        return key
    }

    private func showKeyPreview(for key: KeyControl) {
        guard command?.phase != .recording, key.bounds.width > 0, key.bounds.height > 0,
              view.bounds.width > 0, let text = key.label.text else { return }
        previewKey = key
        keyPreview.show(text, above: key.convert(key.bounds, to: view), within: view.bounds, font: key.label.font)
        view.bringSubviewToFront(keyPreview)
    }
    private func hideKeyPreview() {
        keyPreview.isHidden = true
        previewKey = nil
    }

    private func refreshKeyboardAppearance() {
        // Host fields (including Spotlight) can request a style independent of the app.
        let style: UIUserInterfaceStyle
        switch textDocumentProxy.keyboardAppearance {
        case .dark: style = .dark
        case .light: style = .light
        default: style = .unspecified
        }
        if overrideUserInterfaceStyle != style { overrideUserInterfaceStyle = style }
    }

    private func showSymbolAlternatives(for key: KeyControl) {
        cancelHold()
        hideKeyPreview()
        symbolKey = key; symbolDestination = KeyboardTextDestination(textDocumentProxy)
        symbolAlternatives.show(KeyboardSymbols.alternatives(for: key.value), above: key.convert(key.bounds, to: view), within: view.bounds)
        view.bringSubviewToFront(symbolAlternatives)
        playTapFeedback()
    }
    private func hideSymbolAlternatives() {
        symbolAlternatives.isHidden = true; symbolKey = nil; symbolDestination = nil
    }
    private func cancelSymbolsIfDestinationChanged() {
        guard let key = symbolKey, symbolDestination != KeyboardTextDestination(textDocumentProxy) else { return }
        key.cancelPress(); hideSymbolAlternatives()
    }

    private func cancelDeletionIfDestinationChanged() {
        guard !insertingTypedText, clearText?.isUpdating != true else { return }
        if let clearText, !clearText.matches(textDocumentProxy) { self.clearText = nil }
        if let deleteDestination, deleteDestination != KeyboardTextDestination(textDocumentProxy) {
            currentKey?.cancelPress()
        }
    }

    private func repeatDelete() {
        guard deleteDestination == KeyboardTextDestination(textDocumentProxy) else {
            currentKey?.cancelPress(); return
        }
        // Never queue repeat ticks behind an asynchronous Pinyin edit.
        guard !typingPending, !usesPinyin || pinyinReady else { return }
        playTapFeedback(); tap("delete")
    }

    private func clearAllText() {
        guard deleteDestination == KeyboardTextDestination(textDocumentProxy) else { return }
        resetComposition() // Invalidate outstanding candidate edits before clearing.
        deleteDestination = nil
        playTapFeedback()
        let session = ClearTextSession(proxy: textDocumentProxy)
        clearText = session
        continueClearing(session)
    }

    private func continueClearing(_ session: ClearTextSession) {
        guard clearText === session else { return }
        switch session.advance(in: textDocumentProxy) {
        case .pending:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in self?.continueClearing(session) }
        case .finished, .destinationChanged: clearText = nil
        case .unavailable:
            clearText = nil
            showError("This field couldn't be fully cleared.")
        }
    }
    private func playTapFeedback() {
        guard hapticStrength > 0 else { return }
        tapFeedback.impactOccurred(intensity: CGFloat(hapticStrength))
        tapFeedback.prepare()
    }

    private func refreshKeyboardPreferences() {
        applyKeyboardPreferences(.load())
        lastPreferenceRefresh = Date()
    }

    func applyKeyboardPreferences(_ preferences: KeyboardPreferences) {
        hapticStrength = preferences.hapticStrength
        guard mixedTypingEnabled != preferences.mixedTypingEnabled else { return }
        mixedTypingEnabled = preferences.mixedTypingEnabled
        // A preference refresh must not change the candidate Space will accept
        // in a word already being composed or invalidate queued keystrokes.
        if !typingPending && pinyin.input.isEmpty { compositionUsesMixedTyping = mixedTypingEnabled }
        updateKeyLegends()
    }

    private func tap(_ value: String) {
        clearText = nil
        if command != nil { cancelHold() }
        let waitingForPinyin = usesPinyin && !pinyinReady && (value != "language" || !deferredTaps.isEmpty)
        if typingPending || waitingForPinyin {
            if deferredTaps.count < 64 { deferredTaps.append(value) }
            return
        }
        switch value {
        case "language":
            // Preserve visible spelling and the order of taps queued after the switch.
            let remainingTaps = deferredTaps
            resetComposition()
            deferredTaps = remainingTaps
            language = language.next
            language.save()
            page = 0; shifted = false; capsLock = false
            buildKeys(); renderCandidates()
        case "shift":
            if !pinyin.input.isEmpty { commitSpelling() }
            if Date().timeIntervalSince(lastShift) < 0.35 { capsLock = true; shifted = true } else { capsLock = false; shifted.toggle() }
            lastShift = Date(); updateKeyLegends()
        case "123": page = 1; buildKeys()
        case "#+=": page = 2; buildKeys()
        case "ABC": page = 0; buildKeys()
        case "globe": resetComposition(); advanceToNextInputMode()
        case "delete":
            if !pinyin.input.isEmpty { sendTyping(.key(0xff08)) }
            else {
                insertingTypedText = true
                textDocumentProxy.deleteBackward()
                if deleteDestination != nil { deleteDestination = KeyboardTextDestination(textDocumentProxy) }
                insertingTypedText = false
            }
        case "space":
            if !pinyin.input.isEmpty {
                if let first = visibleCandidates.first { sendTyping(first.spaceAction) }
                else { commitSpelling() }
            }
            else { textDocumentProxy.insertText(" ") }
        case "return":
            // First Return accepts the spelling only; never submits an unfinished Pinyin word.
            if !pinyin.input.isEmpty { commitSpelling() }
            else { textDocumentProxy.insertText("\n") }
        default:
            if usesPinyin, (value.count == 1 && value.first!.isASCII && value.first!.isLetter || value == "'" && !pinyin.input.isEmpty) {
                if pinyin.input.isEmpty {
                    compositionCase = capsLock ? .uppercase : shifted ? .initialCapital : .lowercase
                    compositionUsesMixedTyping = mixedTypingEnabled
                }
                sendTyping(.key(Int32(value.lowercased().utf8.first!)))
                if shifted && !capsLock { shifted = false; updateKeyLegends() }
                return
            }
            if !pinyin.input.isEmpty {
                // Commit spelling before punctuation/numbers, preserving input order.
                deferredTaps.insert(value, at: 0); commitSpelling(); return
            }
            textDocumentProxy.insertText(page == 0 && shifted ? value.uppercased() : value)
            if shifted && !capsLock && page == 0 { shifted = false; updateKeyLegends() }
        }
    }
    private func commitSpelling() {
        sendTyping(.english(compositionCase.apply(to: pinyin.input)))
    }

    private var sameTypingDestination: Bool {
        typingDocument == textDocumentProxy.documentIdentifier &&
        typingBefore == textDocumentProxy.documentContextBeforeInput &&
        typingAfter == textDocumentProxy.documentContextAfterInput &&
        typingSelection == textDocumentProxy.selectedText
    }

    private func rememberTypingDestination() {
        typingDocument = textDocumentProxy.documentIdentifier
        typingBefore = textDocumentProxy.documentContextBeforeInput
        typingAfter = textDocumentProxy.documentContextAfterInput
        typingSelection = textDocumentProxy.selectedText
    }

    private func sendTyping(_ action: PinyinEngine.Action) {
        if typingDocument == nil { rememberTypingDestination() }
        let generation = typingGeneration
        typingPending = true
        candidateRow.isUserInteractionEnabled = false
        PinyinEngine.shared.perform(action) { [weak self] result in
            guard let self, generation == self.typingGeneration else { return }
            guard self.sameTypingDestination else { self.resetComposition(); return }
            self.typingPending = false
            self.pinyin = result
            if let error = result.error { self.showError(error) }
            self.insertingTypedText = true
            // Replace the marked spelling, never append a second copy of it.
            if !result.committed.isEmpty {
                self.textDocumentProxy.setMarkedText(result.committed, selectedRange: NSRange(location: result.committed.utf16.count, length: 0))
                self.textDocumentProxy.unmarkText()
            }
            if !result.input.isEmpty {
                let spelling = self.compositionCase.apply(to: result.preedit.isEmpty ? result.input : result.preedit)
                self.textDocumentProxy.setMarkedText(spelling, selectedRange: NSRange(location: spelling.utf16.count, length: 0))
            } else if result.committed.isEmpty {
                self.textDocumentProxy.setMarkedText("", selectedRange: NSRange(location: 0, length: 0))
                self.textDocumentProxy.unmarkText()
            }
            self.rememberTypingDestination()
            if self.deleteDestination != nil { self.deleteDestination = KeyboardTextDestination(self.textDocumentProxy) }
            self.insertingTypedText = false
            if result.input.isEmpty { self.typingDocument = nil }
            self.renderCandidates()
            self.drainTypingTaps()
        }
    }

    private func drainTypingTaps() {
        guard !typingPending, (!usesPinyin || pinyinReady), !deferredTaps.isEmpty else { return }
        let value = deferredTaps.removeFirst()
        tap(value)
        if !typingPending { drainTypingTaps() }
    }

    private func resetComposition() {
        // Only touch marked text in the document that owns this composition.
        if typingDocument == textDocumentProxy.documentIdentifier {
            insertingTypedText = true
            textDocumentProxy.unmarkText()
            insertingTypedText = false
        }
        typingGeneration += 1
        typingDocument = nil; typingPending = false
        deferredTaps.removeAll(); pinyin = PinyinEngine.Snapshot()
        compositionUsesMixedTyping = mixedTypingEnabled
        PinyinEngine.shared.perform(.clear) { _ in }
        renderCandidates()
    }

    private func renderCandidates() {
        if language != .chinese { visibleCandidates = [] }
        else if compositionUsesMixedTyping {
            visibleCandidates = bilingualProvider.choices(for: pinyin, letterCase: compositionCase)
        } else {
            visibleCandidates = candidateProvider.choices(for: pinyin, letterCase: compositionCase)
        }
        candidateRow.isUserInteractionEnabled = !typingPending
        for view in candidateRow.arrangedSubviews { candidateRow.removeArrangedSubview(view); view.removeFromSuperview() }
        updateHeader()
        candidateScroll.setContentOffset(.zero, animated: false)
        func button(_ title: String, id: String, isDefault: Bool = false, action: @escaping () -> Void) {
            let button = CandidateButton(title: title, identifier: id, isDefault: isDefault)
            button.addAction(UIAction { [weak self] _ in self?.tapFeedback.prepare() }, for: .touchDown)
            button.addAction(UIAction { [weak self] _ in
                self?.playTapFeedback()
                action()
            }, for: .touchUpInside)
            candidateRow.addArrangedSubview(button)
        }
        guard language == .chinese, !pinyin.input.isEmpty else { return }
        for (index, candidate) in visibleCandidates.enumerated() {
            button(candidate.text, id: candidate.identifier, isDefault: index == 0) { [weak self] in
                self?.sendTyping(candidate.action)
            }
        }
        if pinyin.page > 0 { button("‹", id: "candidate.previous") { [weak self] in self?.sendTyping(.previousPage) } }
        if !pinyin.isLastPage { button("›", id: "candidate.next") { [weak self] in self?.sendTyping(.nextPage) } }
        button("×", id: "candidate.cancel") { [weak self] in self?.sendTyping(.clear) }
    }

    private func clearDictationTarget() {
        dictationTargetKey?.dictationFeedback = nil
        dictationTargetKey = nil
    }

    private func moveDictationTouch(to point: CGPoint, from source: KeyControl) -> Bool {
        guard currentKey === source else { return false }
        let location = source.convert(point, to: view)
        guard view.bounds.insetBy(dx: -30, dy: -40).contains(location) else { return false }
        guard command?.phase == .recording else { return true }
        guard sameDestination else {
            cancelHold(); showError("Text field changed. Dictation cancelled."); return false
        }
        // Destructive/submit gestures use the actual keycaps, not the expanded
        // typing targets. Crossing a row gap must not accidentally cancel or send.
        guard let target = keys.first(where: {
            ($0.value == "delete" || $0.value == "return") && $0.convert($0.bounds, to: view).contains(location)
        }) else { return true }
        if target.value == "delete" {
            cancelHold(discard: true)
            target.dictationFeedback = .cancel
        } else {
            endHold(submitAfterPolish: true)
            target.dictationFeedback = .send
        }
        dictationTargetKey = target
        playTapFeedback()
        return true // Consume the originating letter's eventual release.
    }

    private var voiceAccessAllowed: Bool {
#if KEYBOARD_TESTING
        if testingVoiceAvailable { return true }
#endif
        return hasFullAccess
    }
    private var voiceReady: Bool {
#if KEYBOARD_TESTING
        if testingVoiceAvailable { return true }
#endif
        return VoiceIPC.read("ready.json", as: VoiceReadiness.self)?.isFresh == true
    }
    private func writeVoiceCommand(_ command: VoiceCommand) throws {
#if KEYBOARD_TESTING
        if testingVoiceAvailable { testingVoiceCommands.append(command); return }
#endif
        try VoiceIPC.write(command, to: "command.json")
    }

    private func beginHold() {
        guard !typingPending, pinyin.input.isEmpty, deferredTaps.isEmpty else {
            showError("Finish the current word before dictating."); return
        }
        guard command == nil else { showError("Please wait for your previous dictation."); return }
        guard voiceAccessAllowed else { showError("Enable Allow Full Access for vvhisper in Settings."); return }
        guard voiceReady else { openHost(); return }
        let command = VoiceCommand(id: UUID(), phase: .recording, updatedAt: Date())
        let text = DictationTextSession(id: command.id, proxy: textDocumentProxy)
        do {
            try writeVoiceCommand(command)
            clearDictationTarget()
            dictationText = text; self.command = command; started = true; releaseTime = nil
            errorUntil = .distantPast; offersHostLaunch = false
            status.text = nil; updateHeader(); playTapFeedback()
        }
        catch { showError("Cannot reach vvhisper. Check Full Access.") }
    }
    private func endHold(submitAfterPolish: Bool = false) {
        guard var command, command.phase == .recording, started else { return }
        command.phase = .finish; command.updatedAt = Date(); self.command = command; releaseTime = Date()
        dictationText?.finishRecording(submitAfterPolish: submitAfterPolish)
        try? writeVoiceCommand(command); status.text = "Polishing…"; updateHeader()
    }
    private func cancelHold(discard: Bool = false) {
        if var command { command.phase = .cancel; command.updatedAt = Date(); try? writeVoiceCommand(command) }
        command = nil; started = false; releaseTime = nil
        dictationText?.cancel(in: textDocumentProxy, discard: discard); dictationText = nil
        clearDictationTarget()
        updateHeader()
    }

    /// Returns true when the reply ends the session, so polling can remove its file.
    @discardableResult func receiveVoiceReply(_ reply: VoiceReply) -> Bool {
        guard command != nil, let dictationText else { return false }
        switch dictationText.receive(reply, in: textDocumentProxy) {
        case .finished, .failed:
            command = nil; self.dictationText = nil; started = false; releaseTime = nil
            if let error = reply.error { clearDictationTarget(); showError(error) }
            else { status.text = "Hold a letter key to speak" }
            updateHeader()
            return true
        case .destinationChanged:
            cancelHold(); showError("Text field changed. Dictation cancelled."); return true
        case .ignored, .partial: return false
        }
    }
    private func poll() {
        if Date().timeIntervalSince(lastPreferenceRefresh) >= 1 { refreshKeyboardPreferences() }
        defer { updateHeader() }
        if typingDocument != nil, !sameTypingDestination { resetComposition() }
        if let request = activationRequest {
            if VoiceIPC.read("ready.json", as: VoiceReadiness.self)?.isFresh == true {
                activationRequest = nil
                showError("Ready — hold a letter key to speak.")
            } else if !request.isFresh() {
                activationRequest = nil
                showError("Tap to open vvhisper.", offerHostLaunch: true)
            }
            return
        }
        if var command {
            guard sameDestination else { cancelHold(); showError("Text field changed. Dictation cancelled."); return }
            if command.phase == .recording { command.updatedAt = Date(); self.command = command; try? writeVoiceCommand(command) }
            if let reply = VoiceIPC.read("reply.json", as: VoiceReply.self), receiveVoiceReply(reply) {
                VoiceIPC.remove("reply.json")
                return
            }
            if let releaseTime, Date().timeIntervalSince(releaseTime) > 9 { cancelHold(); showError("Recognition timed out. Try again.") }
            else if !voiceReady { cancelHold(); showError("Voice session ended. Hold a letter key to get ready again.", offerHostLaunch: true) }
        } else if Date() > errorUntil {
            status.text = hasFullAccess && VoiceIPC.read("ready.json", as: VoiceReadiness.self)?.isFresh == true ? "Hold a letter key to speak" : "Open vvhisper"
        }
    }
    private func showError(_ message: String, offerHostLaunch: Bool = false) {
        offersHostLaunch = offerHostLaunch
        status.text = message; errorUntil = Date().addingTimeInterval(6); updateHeader()
    }
    private func openHost(using opener: OpenURLAction? = nil) {
        guard activationRequest == nil else { return }
        guard hasFullAccess else { showError("Enable Allow Full Access for vvhisper in Settings."); return }
        guard let openURL = opener ?? hostOpenURL else {
            showError("Tap to open vvhisper.", offerHostLaunch: true); return
        }
        guard keyboardVisible else { return }
        let request = VoiceActivationRequest()
        do { try VoiceIPC.write(request, to: "activation.json") }
        catch { showError("Cannot reach vvhisper. Check Full Access."); return }
        activationRequest = request
        showError("Preparing Voice Input…")
        // Use the same public SwiftUI environment as a tapped Link, now triggered
        // by the explicit hold. Acceptance alone does not mean the mic is ready.
        openURL(request.url) { [weak self] accepted in
            Task { @MainActor in
                guard let self, self.activationRequest?.id == request.id else { return }
                if !accepted {
                    self.activationRequest = nil
                    self.showError("Open vvhisper to prepare voice input.", offerHostLaunch: true)
                }
            }
        }
    }
}

final class KeyControl: UIControl {
    let label = UILabel()
    let icon = UIImageView()
    var restingIcon: UIImage?
    enum DictationFeedback { case cancel, send }
    var dictationFeedback: DictationFeedback? {
        didSet {
            backgroundColor = dictationFeedback == .cancel ? .systemRed : dictationFeedback == .send ? .systemBlue : KeyboardMetrics.keyFill
            icon.tintColor = dictationFeedback == nil ? .label : .white
            label.textColor = dictationFeedback == nil ? .label : .white
            accessibilityValue = dictationFeedback == .cancel ? "Dictation cancelled" : dictationFeedback == .send ? "Send after polishing" : nil
        }
    }
    var value = ""
    var allowsRolloverCommit: Bool { value.count == 1 || value == "space" || value == "shift" || isDeleteKey }
    weak var touchSurface: KeyboardTouchSurface?
    var onPress: (() -> Bool)?
    var onTap: (() -> Void)?
    var onHold: (() -> Void)?
    var onGapHold: (() -> Void)?
    var onPreviewChange: ((Bool) -> Void)?
    var onHoldMove: ((CGPoint) -> Bool)?
    var onRelease: (() -> Void)?
    var onCancel: (() -> Void)?
    var onDeleteRepeat: (() -> Void)?
    var onClearAll: (() -> Void)?
    var isDeleteKey = false
    private(set) var isPressed = false
    private(set) var isGapPress = false
    private var usesDeleteGesture: Bool { isDeleteKey && !(isGapPress && onGapHold != nil) }
    private var holdAction: (() -> Void)? { isGapPress ? onGapHold ?? onHold : onHold }
    var labelOffset: CGFloat = 0 { didSet { labelCenterY?.constant = labelOffset } }
    private var labelCenterY: NSLayoutConstraint?
    private var gate = HoldGate()
    private var deleteGesture = DeleteGesture()
    private var pressOrigin = CGPoint.zero
    private var pressGeneration = 0
    private var timer: Timer?
    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = false
        label.textAlignment = .center; label.isUserInteractionEnabled = false; icon.contentMode = .scaleAspectFit; icon.tintColor = .label
        for item in [label, icon] { item.translatesAutoresizingMaskIntoConstraints = false; addSubview(item) }
        labelCenterY = label.centerYAnchor.constraint(equalTo: centerYAnchor)
        NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: centerXAnchor), labelCenterY!, icon.centerXAnchor.constraint(equalTo: centerXAnchor), icon.centerYAnchor.constraint(equalTo: centerYAnchor), icon.widthAnchor.constraint(equalToConstant: 25), icon.heightAnchor.constraint(equalToConstant: 24)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard let touchSurface else { return super.point(inside: point, with: event) }
        return touchSurface.target(at: convert(point, to: touchSurface)) === self
    }
    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard press(at: ProcessInfo.processInfo.systemUptime, point: touch.location(in: self)) else { return false }
        guard usesDeleteGesture || holdAction != nil else { return true }
        let generation = pressGeneration
        timer = Timer.scheduledTimer(withTimeInterval: usesDeleteGesture ? 0.02 : HoldGate.threshold, repeats: usesDeleteGesture) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.pressGeneration == generation else { return }
                self.advancePress(to: ProcessInfo.processInfo.systemUptime)
            }
        }
        return true
    }
    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        movePress(to: touch.location(in: self), at: ProcessInfo.processInfo.systemUptime)
    }
    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        if let touch { _ = movePress(to: touch.location(in: self), at: ProcessInfo.processInfo.systemUptime) }
        releasePress()
    }
    override func cancelTracking(with event: UIEvent?) { cancelPress() }
    @discardableResult func press(at time: TimeInterval, point: CGPoint) -> Bool {
        stopTimer()
        isGapPress = bounds.width > 0 && bounds.height > 0 && !bounds.contains(point)
        guard onPress?() != false else { return false }
        pressOrigin = point; alpha = 0.55; isPressed = true
        if usesDeleteGesture { deleteGesture.press(at: time, point: point) }
        else { gate.press(at: time) }
        onPreviewChange?(true)
        return true
    }
    func advancePress(to time: TimeInterval) {
        guard isPressed else { return }
        if usesDeleteGesture {
            if deleteGesture.advance(to: time) == .delete { onDeleteRepeat?() }
        } else if let holdAction, gate.advance(to: time) {
            onPreviewChange?(false)
            holdAction()
        }
    }
    @discardableResult func movePress(to point: CGPoint, at time: TimeInterval) -> Bool {
        guard isPressed else { return false }
        if usesDeleteGesture {
            if abs(point.y - pressOrigin.y) > 40 || point.x > bounds.maxX + 30 {
                cancelPress(); return false
            }
            if deleteGesture.move(to: point, at: time) == .clearAll {
                stopTimer(); onClearAll?()
            }
        } else if gate.isHolding, let onHoldMove {
            if !onHoldMove(point) { cancelPress(); return false }
        } else if !bounds.insetBy(dx: -30, dy: -40).contains(point) {
            cancelPress(); return false
        }
        return true
    }
    func releasePress() {
        guard isPressed else { return }
        stopTimer(); alpha = 1; isPressed = false
        onPreviewChange?(false)
        if usesDeleteGesture {
            if deleteGesture.release() == .delete { onTap?() }
            onRelease?()
        } else {
            let wasHolding = gate.isHolding
            if gate.release() { onTap?() } else if wasHolding { onRelease?() }
        }
    }
    private func stopTimer() { timer?.invalidate(); timer = nil; pressGeneration += 1 }
    func cancelPress() {
        guard isPressed else { return }
        onPreviewChange?(false)
        stopTimer(); alpha = 1; isPressed = false; gate.cancel(); deleteGesture.cancel(); onCancel?()
    }
    override func accessibilityActivate() -> Bool { onTap?(); return true }
}

/// Provides the public URL-opening environment for a hold and a retry button.
private struct VoiceLaunchLink: View {
    @Environment(\.openURL) private var openURL
    var resolve: (OpenURLAction) -> Void
    var activate: (OpenURLAction) -> Void
    var body: some View {
        Button { activate(openURL) } label: {
            Text("Tap to open vvhisper").font(.system(size: 14)).foregroundStyle(.primary)
                .frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
        }
            .onAppear { resolve(openURL) }
            .accessibilityLabel("Open vvhisper")
            .accessibilityHint("If iOS does not open the app, open vvhisper from your Home Screen.")
    }
}
