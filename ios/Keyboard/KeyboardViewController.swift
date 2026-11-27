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
    var testingTablet: Bool?
    var testingVoiceAvailable = false
    /// Unit tests: nil behaves as Full Access granted.
    var testingFullAccess: Bool?
    private(set) var testingVoiceCommands: [VoiceCommand] = []
    private(set) var testingTapFeedbackCount = 0
    override var textDocumentProxy: UITextDocumentProxy { testingDocumentProxy ?? super.textDocumentProxy }
#endif
    private let webCapture = WebAudioCapture()
    private lazy var voiceSession = KeyboardVoiceSession(capture: webCapture, recents: dictationRecents, timings: dictationTimings)
    #if KEYBOARD_TESTING
    var dictationRecents = DictationRecentStore(fileURL: nil)
    private let dictationTimings = DictationTimingStore(fileURL: nil)
    #else
    var dictationRecents = DictationRecentStore.shared
    private let dictationTimings = DictationTimingStore.shared
    #endif
    private var rows = UIStackView()
    private var modeSourceRows: UIStackView?
    private let touchSurface = KeyboardTouchSurface()
    private let keyPreview = KeyPreviewView()
    private weak var previewKey: KeyControl?
    private let symbolAlternatives = SymbolAlternativesView()
    private weak var symbolKey: KeyControl?
    private var symbolDestination: KeyboardTextDestination?
    private let status = UILabel()
    private(set) var quietKeys = QuietKeys()
    private var keyboardHeight: NSLayoutConstraint!
    private var layoutWidth: CGFloat = 0
    private var layoutHeight: CGFloat = 0
    private var layoutLandscape = false
    private var tabletLayout: Bool {
        #if KEYBOARD_TESTING
        if let testingTablet { return testingTablet }
        #endif
        return traitCollection.userInterfaceIdiom == .pad
    }
    private var metrics = KeyboardMetrics(width: 466)
    private let candidatePanel = CandidatePanel()
    private let emojiPanel = EmojiPanel()
    private(set) var showingEmoji = false
    private var emojiPressDestination: KeyboardTextDestination?
    private var candidateListGeneration = 0
    private var candidateFetchPending = false
    private var nextCandidateOffset = 0
    private var hasMoreCandidates = false
    private let doubleSpace = DoubleSpacePeriod()
    private var endCursor: CursorDragSession?
    private var endCursorSteps = 0
    private let helperScroll = ClipPillStrip()
    let snippetStrip = SnippetStrip()
    var snippetStore = SnippetStore.shared
    private(set) var snippetsOpen = false
    private let snippetRaw = SnippetRawInput()
    private var snippetMatch: (record: Snippet, token: String, destination: SnippetDestination, generation: Int)?
    private var snippetTask: Task<Void, Never>?
    private var snippetExpansion: SnippetExpansion?
    private var snippetEpoch = UUID()
    private var snippetDocumentID: UUID?
    private var snippetAccess: Bool?
    private var snippetContextRevision = 0
    private var snippetReadGeneration = -1
    private var snippetOperation: UUID?
    private var snippetMatchRead: UUID?
    private var snippetBusy: Bool { snippetOperation != nil }
    #if KEYBOARD_TESTING
    var testingSnippetRead: (() async -> Result<[Snippet], Error>)?
    var testingSnippetBusy: Bool { snippetBusy }
    #endif
    private var snippetComposing = false
    private var snippetLastTap = Date.distantPast
    var copiedCodes = CopiedCodeMonitor()
    #if KEYBOARD_TESTING
    var clipboardHistory = ClipboardHistory(fileURL: nil)
    #else
    var clipboardHistory = ClipboardHistory()
    #endif
    private var pasteGeneration = 0
    private(set) var isMiniMode = false
    private var pendingMiniMode: Bool?
    private var modeChordActive = false
    private var modeChordTaps: [String] = []
    private var modeChordDestination: KeyboardTextDestination?
    private var modeTransition: KeyboardModeTransition?
    private var preparingModeTransition = false
    private var modeChordFromMini = false
    var isModeAnimating: Bool { modeTransition != nil }
    var modeTransitionProgress: CGFloat? { modeTransition?.progress }
    #if KEYBOARD_TESTING
    var testingReduceMotion: Bool?
    #endif
    private var reduceModeMotion: Bool {
        #if KEYBOARD_TESTING
        if let testingReduceMotion { return testingReduceMotion }
        #endif
        return UIAccessibility.isReduceMotionEnabled
    }
    private weak var cursorKey: KeyControl?
    private var cursorPressDestination: KeyboardTextDestination?
    private var cursorDrag: CursorDragSession?
    #if DEBUG
    private var lastCursorCheck: UUID?
    private var lastDictationCheck: UUID?
    private var dictationCheck: (request: DictationDeviceVerification.Request, started: Date, phase: Int)?
    private var cursorCheckEvents: [String] = []
    private var lastHapticCheck: UUID?
    private let hapticCheck = HapticDeviceVerification.Burst()
    private var cursorCheck: (request: CursorDeviceVerification.Request, key: KeyControl, point: CGPoint, started: TimeInterval, phase: Int, held: Bool)?
    #endif
    struct PasteRequest {
        let generation: Int
        let destination: KeyboardTextDestination
        let codeOnly: Bool
    }
    private lazy var bilingualProvider = BilingualCandidates()
    private var visibleCandidates: [PinyinCandidates.Candidate] = []
    private var language = KeyboardLanguage.load()
    // UIKit owns long-press recognition and the enabled-keyboard menu. Its
    // short-tap advance is replaced by our existing Chinese/English action.
    private var handlingLocalLanguageTap = false
    override func advanceToNextInputMode() {
        if handlingLocalLanguageTap { return }
        super.advanceToNextInputMode()
    }
    private var usesPinyin: Bool { language == .chinese && pinyinAvailable }
    private var mixedTypingEnabled = false
    private var compositionUsesMixedTyping = false
    private var compositionAutoCorrection = true
    private var chineseModeName: String { mixedTypingEnabled ? "Mixed Chinese and English" : "Chinese" }
    private let tapFeedback = KeyboardHaptics()
    private let wordEdits = WordEditingSession()
    private let typingAssistance = TypingAssistance()
    private var autoCorrectionEnabled = true
    private var smartSpacingEnabled = true
    private var editingSwipeDestination: KeyboardTextDestination?
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
    private var documentDetached = false
    private var shifted = true
    private var capsLock = false
    private var page = 0
    private var timer: Timer?
    private var levelTimer: Timer?
    private var command: VoiceCommand?
    private var dictationText: DictationTextSession?
    private var releaseTime: Date?
    private var errorUntil = Date.distantPast
    private var currentKey: KeyControl?
    private weak var dictationTargetKey: KeyControl?
    private var keys: [KeyControl] = []
    private var deleteDestination: KeyboardTextDestination?
    private var deleteExpansion: DeleteKeyExpansion?
    private var clearText: ClearTextSession?
    private var lastShift = Date.distantPast
    private var started = false

    override func viewDidLoad() {
        super.viewDidLoad()
        isMiniMode = KeyboardLayoutMode.load() == .mini
        metrics = KeyboardMetrics(width: 466, mini: isMiniMode, tablet: tabletLayout)
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true
        let modeGesture = KeyboardModeGesture(target: nil, action: nil)
        modeGesture.onPair = { [weak self] points in self?.beginModeChord(at: points) }
        modeGesture.onChange = { [weak self] separationChange in self?.updateModeChord(separationChange) }
        modeGesture.onFinish = { [weak self] direction, taps, velocity in self?.finishModeChord(direction: direction, replayTaps: taps, velocity: velocity) }
        view.addGestureRecognizer(modeGesture)
        view.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Mini keyboard") { [weak self] _ in self?.setMiniMode(true); return true },
            UIAccessibilityCustomAction(name: "Full keyboard") { [weak self] _ in self?.setMiniMode(false); return true }
        ]
        // The system owns the keyboard material and device's bottom safe area.
        // Content dimensions come from the iPhone / Duo variants in the design reference.
        keyboardHeight = view.heightAnchor.constraint(equalToConstant: metrics.contentHeight)
        keyboardHeight.priority = .init(999)
        keyboardHeight.isActive = true
        // Opt into UIInputView's public self-sizing contract. A host can still
        // impose a smaller required height, so layout must use its actual bounds.
        inputView?.allowsSelfSizing = true
        requestKeyboardHeight(metrics.contentHeight)
        status.font = .systemFont(ofSize: 14)
        status.textAlignment = .center; status.textColor = .label; status.numberOfLines = 2
        status.accessibilityIdentifier = "keyboard.voice-status"
        status.isHidden = true
        candidatePanel.onPress = { [weak self] in self?.tapFeedback.prepare() }
        candidatePanel.onSelect = { [weak self] candidate in
            guard let self, !self.typingPending else { return }
            if self.language == .english {
                self.insertingTypedText = true
                let accepted = candidate.identifier.hasPrefix("candidate.emoji.")
                    ? self.typingAssistance.acceptEmoji(candidate.text, in: self.textDocumentProxy)
                    : self.typingAssistance.accept(candidate.text, in: self.textDocumentProxy, spacing: self.smartSpacingEnabled)
                self.insertingTypedText = false
                if accepted { self.playTapFeedback() }
                self.renderCandidates(); return
            }
            guard self.sameTypingDestination else { return }
            self.playTapFeedback()
            self.candidatePanel.setExpanded(false)
            self.sendTyping(self.smartSpacingEnabled ? candidate.spaceAction : candidate.action)
        }
        candidatePanel.onMore = { [weak self] in self?.loadMoreCandidates() }
        candidatePanel.onExpansionChange = { [weak self] in
            guard let self else { return }
            self.currentKey?.cancelPress(); self.hideKeyPreview(); self.hideSymbolAlternatives()
            self.updateHeader(); self.view.setNeedsLayout()
        }
        rows.axis = .vertical
        touchSurface.addSubview(rows)
        for item in [helperScroll, touchSurface, candidatePanel, snippetStrip, status] { view.addSubview(item) }
        emojiPanel.isHidden = true; view.addSubview(emojiPanel)
        emojiPanel.onClose = { [weak self] in self?.playTapFeedback(); self?.setEmojiVisible(false) }
        emojiPanel.onPress = { [weak self] in
            guard let self else { return }
            self.emojiPressDestination = KeyboardTextDestination(self.textDocumentProxy)
        }
        emojiPanel.onSelect = { [weak self] text in
            guard let self, self.showingEmoji,
                  self.emojiPressDestination == KeyboardTextDestination(self.textDocumentProxy) else { return }
            self.emojiPressDestination = nil; self.typingAssistance.clear(); self.wordEdits.clear()
            self.insertingTypedText = true; self.textDocumentProxy.insertText(text); self.insertingTypedText = false
            self.playTapFeedback()
        }
        configureInputHelpers()
        snippetStrip.isHidden = true
        snippetStrip.onBack = { [weak self] in self?.closeSnippets() }
        snippetStrip.onRetry = { [weak self] in self?.openSnippets() }
        snippetStrip.onSelect = { [weak self] record in self?.selectSnippet(record) }
        NotificationCenter.default.addObserver(self, selector: #selector(clearSnippetSession), name: .NSExtensionHostWillResignActive, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshCopiedCodes), name: UIPasteboard.changedNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshCopiedCodes), name: UIPasteboard.removedNotification, object: nil)
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
        documentDetached = false
        let savedMiniMode = KeyboardLayoutMode.load() == .mini
        if isMiniMode != savedMiniMode { setMiniMode(savedMiniMode, animated: false) }
        keyboardVisible = true
        #if !KEYBOARD_TESTING
        if hasFullAccess { webCapture.attach(to: view) }
        #endif
        refreshCopiedCodes()
        refreshKeyboardAppearance()
        refreshKeyboardPreferences()
        tapFeedback.prepare()
        if timer == nil { timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in Task { @MainActor in self?.poll() } } }
        poll()
    }
    override func viewWillDisappear(_ animated: Bool) {
        clearSnippetSession()
        hideDeleteExpansion(animated: false)
        // The remote document may already be gone, including its nominally nonnull UUID.
        // Teardown must only discard local state, never message the detached proxy.
        documentDetached = true
        endCursor = nil; doubleSpace.reset()
        tapFeedback.stop(); wordEdits.clear(); typingAssistance.clear(); editingSwipeDestination = nil
        stopModeAnimation()
        hideKeyPreview()
        hideSymbolAlternatives()
        pasteGeneration += 1; pendingMiniMode = nil
        finishModeChord(direction: nil, replayTaps: false)
        keyboardVisible = false
        clearText = nil; deleteDestination = nil
        // A touch cannot survive an app switch. Arming never resumes an old hold.
        cancelHold() // Preserve visible speech when the keyboard disappears.
        voiceSession.cancel(); webCapture.detach()
        currentKey?.cancelPress(); currentKey = nil
        activationRequest = nil; offersHostLaunch = false
        resetComposition(); timer?.invalidate(); timer = nil; super.viewWillDisappear(animated)
    }
    override func textWillChange(_ textInput: UITextInput?) {
        super.textWillChange(textInput)
        snippetWillChange(textInput)
    }
    override func selectionWillChange(_ textInput: UITextInput?) {
        super.selectionWillChange(textInput)
        snippetWillChange(textInput, selection: true)
    }
    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        snippetDocumentChanged(textInput)
        guard !documentDetached, KeyboardDocumentIdentity.read(textDocumentProxy) != nil else { return }
        refreshKeyboardAppearance()
        for key in keys where key.value == "return" { updateReturnKey(key) }
        if !insertingTypedText { pasteGeneration += 1 }
        if !insertingTypedText { wordEdits.observe(textDocumentProxy) }
        if !insertingTypedText { typingAssistance.observe(textDocumentProxy); if language == .english { renderCandidates() } }
        cancelSymbolsIfDestinationChanged()
        cancelDeletionIfDestinationChanged()
        cancelCursorIfDestinationChanged()
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
        snippetDocumentChanged(textInput, selection: true)
        guard !documentDetached, KeyboardDocumentIdentity.read(textDocumentProxy) != nil else { return }
        if !insertingTypedText { pasteGeneration += 1 }
        if !insertingTypedText { wordEdits.observe(textDocumentProxy) }
        if !insertingTypedText { typingAssistance.observe(textDocumentProxy); if language == .english { renderCandidates() } }
        cancelSymbolsIfDestinationChanged()
        cancelDeletionIfDestinationChanged()
        cancelCursorIfDestinationChanged()
        if command != nil, dictationText?.isUpdating != true, !sameDestination { cancelHold(); showError("Cursor moved. Dictation cancelled.") }
        if !insertingTypedText, typingDocument != nil, !sameTypingDestination { resetComposition() }
    }
    private var sameDestination: Bool {
        dictationText?.matches(textDocumentProxy) == true
    }
    private func requestKeyboardHeight(_ height: CGFloat) {
        keyboardHeight.constant = height
        let size = CGSize(width: 0, height: height)
        if preferredContentSize != size {
            preferredContentSize = size
            view.invalidateIntrinsicContentSize()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = view.bounds.width
        guard width > 0 else { return }
        emojiPanel.frame = view.bounds
        var landscape = view.window?.windowScene?.effectiveGeometry.interfaceOrientation.isLandscape == true
#if KEYBOARD_TESTING
        landscape = testingLandscape ?? landscape
#endif
        if abs(width - layoutWidth) > 0.5 || landscape != layoutLandscape {
            layoutWidth = width; layoutLandscape = landscape
            stopModeAnimation()
            metrics = KeyboardMetrics(width: width, landscape: landscape, mini: isMiniMode, tablet: tabletLayout)
            requestKeyboardHeight(metrics.contentHeight)
            buildKeys()
        }
        if abs(view.bounds.height - layoutHeight) > 0.5 {
            layoutHeight = view.bounds.height
            if !preparingModeTransition && !isModeAnimating {
                hideDeleteExpansion(animated: false); hideKeyPreview(); hideSymbolAlternatives()
                currentKey?.cancelPress(); currentKey = nil
                if command != nil { cancelHold() }
            }
        }
        // Transition snapshots intentionally use the full-height canvas until
        // completion. Ordinary layout always fits the granted extension frame,
        // including height-only changes with an unchanged width/orientation.
        let vertical = KeyboardMetrics.VerticalLayout(metrics: metrics,
            availableHeight: preparingModeTransition || isModeAnimating ? metrics.contentHeight : view.bounds.height)
        rows.spacing = vertical.rowGap
        for row in rows.arrangedSubviews {
            for constraint in row.constraints where constraint.firstAttribute == .height && constraint.secondItem == nil {
                constraint.constant = vertical.keyHeight
            }
        }
        let previewTransforms = modeContentViews.map(\.transform)
        for content in modeContentViews { content.transform = .identity }
        touchSurface.frame = CGRect(x: 0, y: vertical.candidateHeight + vertical.topInset, width: width,
                                    height: vertical.rowsHeight)
        rows.frame = CGRect(x: metrics.inset, y: 0, width: width - 2 * metrics.inset, height: touchSurface.bounds.height)
        let headerHeight = min(44, max(0, metrics.candidateHeight - 1))
        candidatePanel.headerHeight = headerHeight
        let expanded = candidatePanel.isExpanded && !candidatePanel.isHidden
        let panelHeight = expanded ? vertical.candidateHeight + 3 * (vertical.keyHeight + vertical.rowGap) - vertical.rowGap / 2 - 1 : headerHeight
        candidatePanel.frame = CGRect(x: 0, y: 1, width: width, height: panelHeight)
        snippetStrip.frame = CGRect(x: 0, y: 1, width: width, height: headerHeight)
        helperScroll.frame = CGRect(x: 0, y: 1, width: width, height: min(ClipPillStrip.stripHeight, headerHeight))
        for (index, row) in rows.arrangedSubviews.enumerated() {
            row.alpha = expanded && index < 3 ? 0 : 1
            row.accessibilityElementsHidden = expanded && index < 3
        }
        let miniSide = metrics.inset + metrics.miniFunctionWidth + metrics.keyGap
        status.frame = isMiniMode ? CGRect(x: miniSide, y: vertical.topInset, width: width - 2 * metrics.inset - 3 * metrics.miniFunctionWidth - 3 * metrics.keyGap, height: vertical.keyHeight) : CGRect(x: 12, y: 1, width: width - 24, height: 42)
        launchLink?.view.frame = status.frame
        for (content, transform) in zip(modeContentViews, previewTransforms) { content.transform = transform }
    }

    func setMiniMode(_ enabled: Bool, animated: Bool = true) {
        if showingEmoji { setEmojiVisible(false) }
        if typingPending || !deferredTaps.isEmpty { pendingMiniMode = enabled; return }
        if enabled, !pinyin.input.isEmpty {
            pendingMiniMode = enabled
            sendTyping(visibleCandidates.first?.action ?? .english(compositionCase.apply(to: pinyin.input)))
            return
        }
        pendingMiniMode = nil
        stopModeAnimation()
        guard isMiniMode != enabled else { return }
        if animated, view.window != nil {
            prepareModeTransition(toMini: enabled)
            modeTransition?.settle(toMini: enabled)
            playTapFeedback()
        } else { applyMode(enabled); (enabled ? KeyboardLayoutMode.mini : .full).save() }
    }
    private var modeContentViews: [UIView] { [touchSurface, candidatePanel, helperScroll, snippetStrip, status] }
    private func applyMode(_ mini: Bool, page targetPage: Int = 0, resizeHost: Bool = true) {
        pasteGeneration += 1; clearText = nil; deleteDestination = nil
        isMiniMode = mini; page = targetPage
        metrics = KeyboardMetrics(width: layoutWidth > 0 ? layoutWidth : 466, landscape: layoutLandscape, mini: mini, tablet: tabletLayout)
        if resizeHost { requestKeyboardHeight(metrics.contentHeight) }
        preparingModeTransition = true; buildKeys()
        // Snapshot preparation must lay out the full destination even while the
        // host still has the source (possibly mini) height.
        preparingModeTransition = !resizeHost
        view.setNeedsLayout(); view.superview?.layoutIfNeeded(); view.layoutIfNeeded(); rows.layoutIfNeeded()
        preparingModeTransition = false
    }
    private func modeAppearance() -> KeyboardModeAppearance {
        var items: [KeyboardModeAppearance.Item] = [], used = Set<String>()
        for (index, key) in keys.enumerated() {
            let shared = key.value == "space" ? "dictate" : ["123", "ABC"].contains(key.value) ? "expand" : key.value
            let id = ["dictate", "expand", "delete", "return"].contains(shared) && used.insert(shared).inserted ? shared : "key.\(index)"
            let snapshot = ModeKeyFace(key: key)
            items.append(.init(id: id, view: snapshot, frame: key.convert(key.bounds, to: view)))
        }
        for (index, control) in touchSurface.controls.enumerated() where !(control is KeyControl) {
            if let snapshot = control.snapshotView(afterScreenUpdates: true) {
                items.append(.init(id: "accessory.\(index)", view: snapshot, frame: control.convert(control.bounds, to: view)))
            }
        }
        for (index, content) in [candidatePanel, helperScroll].enumerated() where !content.isHidden {
            if let snapshot = content.snapshotView(afterScreenUpdates: true) { items.append(.init(id: "header.\(index)", view: snapshot, frame: content.frame)) }
        }
        return KeyboardModeAppearance(height: metrics.contentHeight, items: items)
    }
    private func prepareModeTransition(toMini mini: Bool) {
        guard modeTransition == nil else { return }
        let fromMini = isMiniMode, originalPage = page
        view.layoutIfNeeded(); rows.layoutIfNeeded()
        let source = modeAppearance()
        // Keep the touched views in their original hierarchy until both fingers
        // finish; removing them here makes UIKit cancel the interactive pinch.
        modeSourceRows = rows
        rows = UIStackView(); rows.axis = .vertical
        touchSurface.addSubview(rows)
        applyMode(mini, resizeHost: false)
        let target = modeAppearance()
        let transition = KeyboardModeTransition(fromMini: fromMini, originalPage: originalPage,
            full: fromMini ? target : source, mini: fromMini ? source : target, reduced: reduceModeMotion,
            onHeight: { [weak self] height in
                guard let self else { return }
                self.requestKeyboardHeight(height)
                self.view.superview?.layoutIfNeeded()
            }, onCompletion: { [weak self] mini in self?.finishModeTransition(mini) })
        modeTransition = transition
        for content in modeContentViews { content.alpha = 0.001 }
        view.addSubview(transition.overlay)
        transition.render(fromMini ? 1 : 0)
    }
    private func finishModeTransition(_ mini: Bool) {
        guard let transition = modeTransition else { return }
        modeTransition = nil; transition.stop()
        modeSourceRows?.removeFromSuperview(); modeSourceRows = nil
        applyMode(mini, page: mini == transition.fromMini ? transition.originalPage : 0)
        for content in modeContentViews { content.alpha = 1; content.isUserInteractionEnabled = true }
        (mini ? KeyboardLayoutMode.mini : .full).save()
    }
    private func stopModeAnimation() {
        guard let transition = modeTransition else { return }
        modeTransition = nil; transition.stop()
        modeSourceRows?.removeFromSuperview(); modeSourceRows = nil
        // Dismissal/rotation/new input abandon the incomplete gesture, not the saved mode.
        applyMode(transition.fromMini, page: transition.originalPage)
        for content in modeContentViews { content.alpha = 1; content.isUserInteractionEnabled = true }
    }
    func updateModeChord(_ separationChange: CGFloat) {
        guard modeChordActive, separationChange.isFinite else { return }
        let amount = modeChordFromMini ? separationChange : -separationChange
        guard modeTransition != nil || amount > 3 else { return }
        guard !typingPending, deferredTaps.isEmpty, pinyin.input.isEmpty else { return }
        if modeTransition == nil { prepareModeTransition(toMini: !modeChordFromMini) }
        let travel = min(1, max(0, amount / 80))
        modeTransition?.render(modeChordFromMini ? 1-travel : travel)
    }

    func beginModeChord(at points: [CGPoint]) {
        guard !modeChordActive else { return }
        wordEdits.clear(); editingSwipeDestination = nil
        stopModeAnimation()
        modeChordActive = true; modeChordFromMini = isMiniMode; pasteGeneration += 1
        modeChordDestination = KeyboardTextDestination(textDocumentProxy)
        modeChordTaps = []
        let wasEditingSwipe = currentKey?.isEditingSwipe == true
        if let currentKey, currentKey.isPressed {
            if currentKey.hasPendingChordTap { modeChordTaps.append(currentKey.value) }
        } else if let point = points.first,
                  let first = touchSurface.target(at: view.convert(point, to: touchSurface)) as? KeyControl,
                  first.allowsRolloverCommit {
            // Simultaneous touches can reach the recognizer before UIControl.
            first.onPressFeedback?()
            modeChordTaps.append(first.value)
        }
        if !wasEditingSwipe, let point = points.last,
           let next = touchSurface.target(at: view.convert(point, to: touchSurface)) as? KeyControl,
           next.allowsRolloverCommit {
            // The recognizer consumes this new finger before its key can track.
            // Give feedback now; replaying text on release must stay silent.
            next.onPressFeedback?()
            modeChordTaps.append(next.value)
        }
        cancelHold() // A mode gesture preserves the visible transcript and cancels submission.
        clearText = nil; deleteDestination = nil
        for key in keys { key.cancelPress() }
        currentKey = nil; hideKeyPreview(); hideSymbolAlternatives()
    }
    func finishModeChord(direction: KeyboardModePinch.Direction?, replayTaps: Bool, velocity: CGFloat = 0) {
        guard modeChordActive else { return }
        let values = modeChordTaps
        let matches = !documentDetached && modeChordDestination == KeyboardTextDestination(textDocumentProxy)
        modeChordActive = false; modeChordTaps = []; modeChordDestination = nil
        if modeTransition != nil, replayTaps, matches, direction == nil {
            // Tiny two-thumb drift is still typing, even if it briefly previewed
            // the mode timeline. Restore the source before replaying its letters.
            stopModeAnimation()
            for value in values { tap(value) }
            return
        }
        if let transition = modeTransition {
            let allowed = direction == (modeChordFromMini ? .outward : .inward)
            let travelled = modeChordFromMini ? 1-transition.progress : transition.progress
            let directedVelocity = modeChordFromMini ? velocity : -velocity
            let commit = matches && allowed && travelled + directedVelocity * 0.10 / 80 >= 0.28
            transition.settle(toMini: commit ? !modeChordFromMini : modeChordFromMini)
            if commit { playTapFeedback() }
        } else if let direction, matches { setMiniMode(direction == .inward) }
        else if replayTaps, matches { for value in values { tap(value) } }
    }

    private func buildKeys() {
        hideDeleteExpansion(animated: false)
        stopQuietKeys(animated: false)
        candidatePanel.setExpanded(false)
        wordEdits.clear(); editingSwipeDestination = nil
        if !preparingModeTransition { finishModeChord(direction: nil, replayTaps: false) }
        hideKeyPreview()
        hideSymbolAlternatives()
        if command != nil { cancelHold() } // Rotation also invalidates a released hold awaiting polish.
        if currentKey?.isPressed == true {
            #if DEBUG
            if cursorCheck != nil { cursorCheckEvents.append("layoutChanged") }
            #endif
            cancelHold() // A layout change ends the touch, preserving visible speech.
            currentKey?.cancelPress()
        }
        currentKey = nil
        keys.removeAll()
        touchSurface.controls.removeAll()
        for v in rows.arrangedSubviews { rows.removeArrangedSubview(v); v.removeFromSuperview() }
        rows.spacing = metrics.rowGap
        if isMiniMode {
            let line = UIStackView(); line.axis = .horizontal; line.spacing = metrics.keyGap
            line.heightAnchor.constraint(equalToConstant: metrics.keyHeight).isActive = true
            for value in ["expand", "dictate", "delete", "return"] {
                let key = makeKey(value)
                if value != "dictate" { key.widthAnchor.constraint(equalToConstant: metrics.miniFunctionWidth).isActive = true }
                line.addArrangedSubview(key)
            }
            rows.addArrangedSubview(line)
            updateHeader(); return
        }
        if metrics.tablet { buildTabletKeys(); updateHeader(); return }
        if metrics.split { buildSplitKeys(); updateHeader(); return }
        let topLetters = "qwertyuiop".map { String($0) }
        let middleLetters = "asdfghjkl".map { String($0) }
        let bottomLetters = "zxcvbnm".map { String($0) }
        let letters: [[String]] = [topLetters, middleLetters, ["shift"] + bottomLetters + ["delete"]]
        let paletteLanguage: KeyboardLanguage = [.emailAddress, .URL, .asciiCapable].contains(textDocumentProxy.keyboardType ?? .default) ? .english : language
        let contents = page == 0 ? letters : KeyboardSymbols.rows(page: page, language: paletteLanguage)
        func row() -> UIStackView {
            let row = UIStackView(); row.axis = .horizontal; row.spacing = metrics.keyGap
            row.heightAnchor.constraint(equalToConstant: metrics.keyHeight).isActive = true
            rows.addArrangedSubview(row)
            return row
        }
        for (index, values) in contents.enumerated() where !isMiniMode {
            let line = row()
            if index == 2 {
                line.spacing = metrics.sideGap
                let first = makeKey(values.first!, literal: page > 0), last = makeKey(values.last!, literal: page > 0)
                first.widthAnchor.constraint(equalToConstant: metrics.shiftWidth).isActive = true
                let middle = UIStackView(); middle.axis = .horizontal; middle.spacing = metrics.keyGap; middle.distribution = .fillEqually
                for value in values.dropFirst().dropLast() { middle.addArrangedSubview(makeKey(value, literal: page > 0)) }
                for item in [first, middle, last] { line.addArrangedSubview(item) }
                last.widthAnchor.constraint(equalTo: first.widthAnchor).isActive = true
            } else {
                line.distribution = .fillEqually
                if page == 0, index == 1 {
                    line.isLayoutMarginsRelativeArrangement = true
                    line.layoutMargins = UIEdgeInsets(top: 0, left: metrics.middleInset, bottom: 0, right: metrics.middleInset)
                }
                for value in values { line.addArrangedSubview(makeKey(value, literal: page > 0)) }
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
        updateHeader()
    }

    /// iPad uses a continuous, hardware-style five-row layout. Narrow floating
    /// and multitasking windows use the phone geometry instead of squashing this.
    private func buildTabletKeys() {
        let punctuation: (String) -> String = { KeyboardSymbols.key($0, language: self.language) }
        let alphabet: [[String]] = [Array("1234567890").map(String.init) + ["-", "=", "delete"],
                        ["tab"] + Array("qwertyuiop").map(String.init) + ["[", "]", "\\"],
                        ["shift"] + Array("asdfghjkl").map(String.init) + [";", "'", "return"],
                        ["shift"] + Array("zxcvbnm").map(String.init) + [",", ".", "/", "shift"]]
        let symbols: [[String]] = [Array("1234567890").map(String.init) + ["-", "=", "delete"],
                       ["tab", "@", "#", "$", "%", "&", "*", "(", ")", "[", "]", "{", "}", "\\"],
                       ["#+=", "_", "+", "~", "`", "|", "<", ">", "€", "£", "¥", "\"", "return"],
                       ["ABC", ".", ",", "?", "!", ":", ";", "'", "\"", "/", "•", "ABC"]]
        for values in page == 0 ? alphabet : symbols {
            let line = UIStackView(); line.axis = .horizontal; line.spacing = metrics.keyGap
            line.heightAnchor.constraint(equalToConstant: metrics.keyHeight).isActive = true
            rows.addArrangedSubview(line)
            var anchor: KeyControl?
            for raw in values {
                let value = raw.count == 1 && raw.first?.isLetter != true ? punctuation(raw) : raw
                let key = makeKey(value); line.addArrangedSubview(key)
                if ["shift", "tab", "delete", "return", "ABC", "#+="].contains(raw) {
                    key.widthAnchor.constraint(equalToConstant: raw == "return" ? 100 : 64).isActive = true
                } else if let anchor { key.widthAnchor.constraint(equalTo: anchor.widthAnchor).isActive = true }
                else { anchor = key }
            }
        }
        let bottom = UIStackView(); bottom.axis = .horizontal; bottom.spacing = metrics.keyGap
        bottom.heightAnchor.constraint(equalToConstant: metrics.keyHeight).isActive = true; rows.addArrangedSubview(bottom)
        for value in [page == 0 ? "123" : "ABC", "language", "emoji", "dictate", "space", "left", "right"] {
            let key = makeKey(value); bottom.addArrangedSubview(key)
            if value != "space" { key.widthAnchor.constraint(equalToConstant: 60).isActive = true }
        }
    }

    /// Duo's native inner-landscape layout duplicates G/V near the thumb boundary.
    private func buildSplitKeys() {
        let leftLetters = [["q", "w", "e", "r", "t"], ["a", "s", "d", "f", "g"], ["shift", "z", "x", "c", "v"]]
        let rightLetters = [["y", "u", "i", "o", "p"], ["g", "h", "j", "k", "l"], ["v", "b", "n", "m", "delete"]]
        let leftNumbers = [["1", "2", "3", "4", "5"], ["-", "/", ":", ";", "("], ["#+=", ".", ",", "?", "!"]]
        let rightNumbers = [["6", "7", "8", "9", "0"], [")", "$", "&", "@", "\""], [".", ",", "?", "'", "delete"]]
        let leftSymbols = [["[", "]", "{", "}", "#"], ["_", "\\", "|", "~", "<"], ["123", ".", ",", "?", "!"]]
        let rightSymbols = [["%", "^", "*", "+", "="], [">", "€", "£", "¥", "•"], [".", ",", "?", "'", "delete"]]
        var left = page == 0 ? leftLetters : page == 1 ? leftNumbers : leftSymbols
        var right = page == 0 ? rightLetters : page == 1 ? rightNumbers : rightSymbols
        if page > 0, language == .chinese, ![.emailAddress, .URL, .asciiCapable].contains(textDocumentProxy.keyboardType ?? .default) {
            let palette = KeyboardSymbols.rows(page: page, language: .chinese)
            left = palette.map { Array($0.prefix($0.count / 2)) }
            right = palette.map { Array($0.suffix($0.count / 2)) }
        }
        let halfWidth: CGFloat = 303.667
        for index in (isMiniMode ? 3 : 0)..<4 {
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
                        let key = makeKey(value, literal: page > 0); half.addArrangedSubview(key)
                        let wide = index == 2 && (isRight ? column == values.count - 1 : column == 0)
                        if index == 2 {
                            if wide { key.widthAnchor.constraint(equalToConstant: 64).isActive = true }
                            else if let letter { key.widthAnchor.constraint(equalTo: letter.widthAnchor).isActive = true }
                            else { letter = key }
                        }
                        if index == 2 && (isRight ? column == values.count - 2 : column == 0) { half.setCustomSpacing(22, after: key) }
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
        // Emoji stays inside our extension; Language holds own the system picker.
        let button = KeyboardSwitcherButton(type: .custom)
        button.touchSurface = touchSurface
        button.quietFeedback.frame = button.bounds
        button.quietFeedback.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        button.addSubview(button.quietFeedback)
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
        button.accessibilityLabel = "Emoji"
        button.accessibilityHint = "Open emoji. Hold Language to switch keyboards."
        button.widthAnchor.constraint(equalToConstant: metrics.switcherWidth).isActive = true
        button.addAction(UIAction { [weak self] _ in
            self?.clearText = nil
            self?.currentKey?.cancelPress()
            self?.tapFeedback.prepare()
        }, for: .touchDown)
        button.addAction(UIAction { [weak self] _ in self?.playTapFeedback(); self?.tap("emoji") }, for: .touchUpInside)
        return button
    }

    private func setEmojiVisible(_ visible: Bool) {
        currentKey?.cancelPress(); cancelHold(); hideKeyPreview(); hideSymbolAlternatives()
        showingEmoji = visible; emojiPressDestination = nil
        emojiPanel.isHidden = !visible; touchSurface.isHidden = visible
        if visible { view.bringSubviewToFront(emojiPanel) }
        updateHeader(); view.setNeedsLayout()
    }

    private func makeAccessoryReturn() -> KeyControl {
        let key = makeKey("return")
        key.widthAnchor.constraint(equalToConstant: metrics.returnWidth).isActive = true
        return key
    }

    private func makeLanguageKey() -> KeyControl {
        let key = makeKey("language")
        key.widthAnchor.constraint(equalToConstant: metrics.languageWidth).isActive = true
        return key
    }

    private func updateHeader() {
        let voiceVisible = command != nil || activationRequest != nil || Date() < errorUntil
        setRecordingAppearance(command?.phase == .recording, voiceVisible: voiceVisible)
        let showSnippets = (snippetsOpen || snippetMatch != nil) && !showingEmoji && !isMiniMode && !voiceVisible && cursorKey == nil
        snippetStrip.isHidden = !showSnippets
        candidatePanel.isHidden = showSnippets || showingEmoji || isMiniMode || voiceVisible || visibleCandidates.isEmpty
        if candidatePanel.isHidden { candidatePanel.setExpanded(false) }
        let hidePills = showingEmoji || isMiniMode || cursorKey != nil || voiceVisible || candidatePanel.isExpanded
        helperScroll.isHidden = showSnippets || hidePills || page == 0 || !candidatePanel.isHidden
        refreshCopiedCodeIndicator()
        view.setNeedsLayout()
        status.textColor = .label
        let ready = hasFullAccess && voiceReady
        launchLink?.view.isHidden = ready || !voiceVisible || command != nil || activationRequest != nil || !offersHostLaunch
    }
    func setRecordingAppearance(_ recording: Bool, voiceVisible: Bool) {
        if recording { hideKeyPreview() }
        status.isHidden = showingEmoji || isMiniMode || recording || command != nil || !voiceVisible
        for button in touchSurface.controls.compactMap({ $0 as? KeyboardSwitcherButton }) { button.setDictating(recording) }
        for key in keys {
            if recording { key.alpha = 1 }
            key.label.isHidden = cursorDrag != nil
            key.setLegendHidden(recording)
            key.quietFeedback.setRecording(recording, dimBase: key.value.count == 1 || ["space", "dictate", "shift", "emoji"].contains(key.value), mini: key.value == "dictate")
            if key.value == "space" {
                key.icon.image = cursorKey === key && cursorDrag != nil ? UIImage(systemName: "arrow.left.and.right") : key.restingIcon
            }
            if key.value == "return" {
                key.icon.image = recording ? UIImage(systemName: textDocumentProxy.returnKeyType == .send ? "paperplane" : "checkmark") : key.restingIcon
            } else if key.value == "dictate" {
                key.icon.image = key.restingIcon
                key.icon.isHidden = recording || (voiceVisible && command == nil)
                key.label.isHidden = false
                key.label.text = voiceVisible && !recording && command == nil ? status.text : nil
                key.label.font = .systemFont(ofSize: 14)
                key.label.numberOfLines = 2
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
        // Localize to the selected typing mode, not the host app or device locale.
        let locale = Locale(identifier: language == .chinese ? "zh-Hans-CN" : "en-US")
        let symbol = language == .chinese ? "character.book.closed.zh" : "character.book.closed"
        key.label.text = nil
        key.icon.image = UIImage(systemName: symbol, withConfiguration: UIImage.Configuration(locale: locale))
        key.restingIcon = key.icon.image
        key.accessibilityLabel = language == .chinese ? chineseModeName : language.name
        key.accessibilityHint = "Tap to switch to \(language == .chinese ? "English" : chineseModeName). Hold for other keyboards."
    }

    private func updateReturnKey(_ key: KeyControl) {
        let type = textDocumentProxy.returnKeyType ?? .default
        let title: String
        switch type {
        case .send: title = "send"
        case .search, .google, .yahoo: title = "search"
        case .go: title = "go"
        case .done: title = "done"
        case .next: title = "next"
        case .join: title = "join"
        case .route: title = "route"
        case .continue: title = "continue"
        case .emergencyCall: title = "emergency call"
        default: title = "return"
        }
        key.isPrimaryAction = title != "return"
        key.label.text = isMiniMode || !key.isPrimaryAction ? nil : title
        key.restingIcon = isMiniMode || !key.isPrimaryAction ? UIImage(systemName: type == .send ? "paperplane" : "return") : nil
        key.icon.image = command?.phase == .recording ? UIImage(systemName: type == .send ? "paperplane" : "checkmark") : key.restingIcon
        key.accessibilityLabel = title
    }

    private func makeKey(_ rawValue: String, literal: Bool = false) -> KeyControl {
        let asciiField = textDocumentProxy.keyboardType == .emailAddress || textDocumentProxy.keyboardType == .URL || textDocumentProxy.keyboardType == .asciiCapable
        let value = !literal && page > 0 && !asciiField ? KeyboardSymbols.key(rawValue, language: language) : rawValue
        let key = KeyControl()
        key.value = value
        key.touchSurface = touchSurface
        touchSurface.controls.append(key)
        keys.append(key)
        key.isDeleteKey = value == "delete"
        let ordinary = value.count == 1
        key.isEnabled = !value.isEmpty
        key.backgroundColor = KeyboardMetrics.keyFill
        key.layer.cornerRadius = metrics.cornerRadius; key.layer.cornerCurve = .continuous
        key.label.font = ordinary ? metrics.letterFont : .systemFont(ofSize: 18)
        key.label.textColor = .label
        key.labelOffset = ordinary ? -1.5 : -1
        var title = value
        if ordinary && page == 0 { title = shifted ? value.uppercased() : value }
        if value == "space" { title = "" }
        if value == "tab" { key.icon.image = UIImage(systemName: "arrow.right.to.line"); title = "Tab" }
        else if value == "left" || value == "right" { key.icon.image = UIImage(systemName: "arrow.\(value)") }
        else if value == "dictate" { key.icon.image = UIImage(systemName: "mic.fill") }
        else if value == "kaomoji" { title = "^_^" }
        else if value == "emoji" { key.icon.image = UIImage(systemName: "face.smiling"); title = "Emoji" }
        else if value == "shift" { key.icon.image = UIImage(systemName: capsLock ? "capslock.fill" : shifted ? "shift.fill" : "shift") }
        else if value == "expand" { key.icon.image = UIImage(systemName: "arrow.up.left.and.arrow.down.right"); title = "Full keyboard" }
        else if value == "delete" { key.icon.image = UIImage(systemName: "delete.left"); if isMiniMode { title = "Delete word" } }
        else if value == "return" {
            updateReturnKey(key)
            title = key.accessibilityLabel ?? "return"
        } else { key.label.text = title }
        key.accessibilityIdentifier = "keyboard.key.\(value)"
        key.accessibilityLabel = value == "space" ? "space" : title; key.accessibilityTraits = .keyboardKey
        if value == "language" { updateLanguageKey(key) }
        if value == "space" || value == "dictate" {
            key.accessibilityCustomActions = [UIAccessibilityCustomAction(name: value == "dictate" ? "Full keyboard" : "Mini keyboard") { [weak self] _ in
                self?.setMiniMode(value != "dictate"); return true
            }]
        }
        if value != "return" { key.restingIcon = key.icon.image }
        key.onPress = { [weak self, weak key] in
            guard let self, let key, self.keys.contains(where: { $0 === key }) else { return false }
            guard !self.modeChordActive else { return false }
            if self.modeTransition != nil { return false }
            self.pasteGeneration += 1
            self.hideDeleteExpansion(animated: false)
            self.clearText = nil
            // A released hold may still be awaiting refinement/polish. Relinquish
            // its marked range before this finger can edit, not on key release.
            if self.command?.phase == .finish { self.cancelHold() }
            if let current = self.currentKey, current !== key {
                self.cancelHold()
                // A second thumb is normal typing: commit the pending tap in
                // press order, then consume the first finger's later release.
                if self.symbolKey === current { current.cancelPress() }
                else if current.allowsRolloverCommit { current.releasePress() }
                else { current.cancelPress() } // Never submit or change layouts from another finger's press.
            }
            // The preceding action may have invalidated this key's layout.
            guard self.keys.contains(where: { $0 === key }), self.modeTransition == nil else { return false }
            self.currentKey = key
            self.endCursor = nil
            self.editingSwipeDestination = KeyboardTextDestination(self.textDocumentProxy)
            if key.isDeleteKey {
                self.cancelHold()
                self.deleteDestination = KeyboardTextDestination(self.textDocumentProxy)
                if !key.isGapPress { self.prepareDeleteExpansion(for: key) }
            } else if key.value == "space", !key.isGapPress {
                self.cancelHold() // A cursor touch must not race a late dictation replacement.
            }
            self.cursorPressDestination = key.value == "space" && !key.isGapPress ? KeyboardTextDestination(self.textDocumentProxy) : nil
            self.tapFeedback.prepare()
            return true
        }
        key.onTap = { [weak self] in
            if value == "dictate" {
                if self?.command?.phase == .recording { self?.endHold() } else { self?.beginHold() }
                return
            }
            self?.tap(value)
        }
        if value != "dictate" { key.onPressFeedback = { [weak self] in self?.playTapFeedback() } }
        if value == "language" {
            key.onSystemKeyboard = { [weak self] sender, event in
                guard let self else { return }
                self.handlingLocalLanguageTap = !sender.systemKeyboardHoldReached
                self.handleInputModeList(from: sender, with: event)
                self.handlingLocalLanguageTap = false
            }
            key.onHold = { [weak key] in key?.beginSystemKeyboardSelection() }
            key.accessibilityCustomActions = [UIAccessibilityCustomAction(name: "Next keyboard") { [weak self] _ in
                self?.advanceToNextInputMode(); return true
            }]
        } else if value == "return" {
            key.accessibilityHint = "Hold to insert a line break without sending."
            key.onHold = { [weak self] in
                guard let self, !self.documentDetached, self.editingSwipeDestination == KeyboardTextDestination(self.textDocumentProxy) else { return }
                self.tap(KeyboardEditSwipe.lineBreak.rawValue)
            }
            key.accessibilityCustomActions = [UIAccessibilityCustomAction(name: "Insert line break") { [weak self] _ in
                self?.tap(KeyboardEditSwipe.lineBreak.rawValue); return true
            }]
        } else if value == "space" {
            key.accessibilityHint = "Hold, then drag to move the cursor."
            key.onHold = { [weak self, weak key] in
                guard let self, let key else { return }
                self.beginCursorDrag(from: key)
            }
        } else if key.isDeleteKey {
            key.accessibilityHint = "Hold to keep deleting. Slide left to the broom to clear the field."
            key.onDeleteHold = { [weak self] origin in
                guard let self else { return }
                self.deleteExpansion?.show(in: self.view, originX: origin.x)
            }
            key.onDeleteMove = { [weak self] point in self?.deleteExpansion?.track(point) }
            key.onDeleteEnd = { [weak self] animated in self?.hideDeleteExpansion(animated: animated) }
            key.onDeleteRepeat = { [weak self] in self?.repeatDelete() }
            key.onClearAll = { [weak self] in
                guard let self else { return }
                if self.clearAllText() { self.deleteExpansion?.confirmClear() }
            }
        } else if value == "dictate" || (page == 0 && ordinary && value.first?.isASCII == true && value.first?.isLetter == true) {
            key.accessibilityHint = "Hold to dictate. Slide to Delete to cancel, Return to send, or release over Language to translate."
            key.onHold = { [weak self] in self?.beginHold() }
            if value == "dictate" {
                key.label.widthAnchor.constraint(lessThanOrEqualTo: key.widthAnchor, constant: -8).isActive = true
                key.accessibilityLabel = "Dictate"
                key.accessibilityHint = "Hold to speak. Slide to Delete to cancel, Return to send, or release over Language to translate. Pinch out for the full keyboard. Double-tap with VoiceOver to start or finish."
            }
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
            if ["language", "return"].contains(key.value), !key.isGapPress { return true }
            if key.value == "space", !key.isGapPress {
                guard self.cursorKey === key else { return false }
                return self.cursorDrag?.move(to: point, in: self.textDocumentProxy) ?? true
            }
            if self.symbolKey === key {
                self.symbolAlternatives.track(key.convert(point, to: self.view))
                return true
            }
            return self.moveDictationTouch(to: point, from: key)
        }
        key.onRelease = { [weak self, weak key] in
            if let self, let key, key.value == "space", !key.isGapPress {
                self.endCursorDrag(); return
            }
            if let self, let key, self.symbolKey === key {
                let choice = self.symbolDestination == KeyboardTextDestination(self.textDocumentProxy) ? self.symbolAlternatives.selectedSymbol : nil
                self.hideSymbolAlternatives()
                if let choice { self.playTapFeedback(); self.tap(choice) }
                return
            }
            self?.deleteDestination = nil
            self?.endHold(translate: self?.dictationTargetKey?.dictationFeedback == .translate)
            self?.clearDictationTarget()
        }
        key.onCancel = { [weak self, weak key] in
            if let self, let key, key.value == "space", !key.isGapPress { self.endCursorDrag() }
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

    private func beginCursorDrag(from key: KeyControl) {
        typingAssistance.clear(); renderCandidates()
        wordEdits.clear()
        #if DEBUG
        if cursorCheck != nil { cursorCheckEvents.append("holdReached") }
        #endif
        guard CursorDragSession.matchesPress(cursorPressDestination, in: textDocumentProxy) else { key.cancelPress(); return }
        pasteGeneration += 1; clearText = nil; deleteDestination = nil
        cancelHold() // Preserve any visible dictated text, invalidating its pending polish/send.
        cursorKey = key
        cursorPressDestination = KeyboardTextDestination(textDocumentProxy)
        prepareCursorDrag()
    }
    private func prepareCursorDrag() {
        guard let key = cursorKey, key.isPressed, cursorDrag == nil else { return }
        guard !typingPending, deferredTaps.isEmpty else { return }
        if !pinyin.input.isEmpty {
            sendTyping(visibleCandidates.first?.action ?? .english(compositionCase.apply(to: pinyin.input)))
            return
        }
        cursorDrag = CursorDragSession(proxy: textDocumentProxy, point: key.pressPoint)
        #if DEBUG
        if cursorCheck != nil { cursorCheckEvents.append("cursorActivated") }
        if cursorCheck?.request.legacyAcknowledgement == true {
            cursorDrag?.enableLegacyVerification(in: textDocumentProxy)
        }
        #endif
        hideKeyPreview(); playTapFeedback(); updateHeader()
    }
    private func endCursorDrag() {
        cursorKey = nil; cursorDrag = nil; cursorPressDestination = nil
        updateHeader()
    }
    private func cancelCursorIfDestinationChanged() {
        guard !insertingTypedText, cursorDrag?.isUpdating != true,
              let key = currentKey, key.isPressed, key.value == "space", !key.isGapPress else { return }
        let matches = cursorDrag?.advance(in: textDocumentProxy) ?? CursorDragSession.matchesPress(cursorPressDestination, in: textDocumentProxy)
        if !matches {
            #if DEBUG
            if cursorCheck != nil { cursorCheckEvents.append("destinationChanged") }
            #endif
            key.cancelPress()
        }
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
        if isMiniMode, currentKey?.isDeleteKey == true {
            _ = miniDeleteDestinationIsValid()
            return
        }
        if let clearText, !clearText.matches(textDocumentProxy) { self.clearText = nil }
        if let deleteDestination, deleteDestination != KeyboardTextDestination(textDocumentProxy) {
            currentKey?.cancelPress()
        }
    }

    private func repeatDelete() {
        if isMiniMode {
            guard miniDeleteDestinationIsValid(), !typingPending else { return }
            playTapFeedback(); tap("delete"); return
        }
        guard deleteDestination == KeyboardTextDestination(textDocumentProxy) else {
            currentKey?.cancelPress(); return
        }
        // Never queue repeat ticks behind an asynchronous Pinyin edit.
        guard !typingPending, !usesPinyin || pinyinReady else { return }
        playTapFeedback(); tap("delete")
    }

    private func prepareDeleteExpansion(for key: KeyControl) {
        key.deleteClearTargetX = nil
        let cap = key.convert(key.bounds, to: view)
        let neighbor = keys.filter { other in
            guard other !== key, other.isEnabled, !other.isHidden else { return false }
            let box = other.convert(other.bounds, to: view)
            return box.width > 0 && abs(box.midY - cap.midY) < 1 && box.maxX <= cap.minX && cap.minX - box.maxX < 40
        }.max { $0.convert($0.bounds, to: view).maxX < $1.convert($1.bounds, to: view).maxX }
        guard let neighbor else { return }
        let expansion = DeleteKeyExpansion(source: key, neighbor: neighbor, container: view)
        guard view.bounds.insetBy(dx: -0.5, dy: -0.5).contains(expansion.geometry.frame) else { return }
        deleteExpansion = expansion
        key.deleteClearTargetX = expansion.geometry.clearTargetX
    }

    private func hideDeleteExpansion(animated: Bool) {
        deleteExpansion?.dismiss(animated: animated)
        deleteExpansion = nil
    }

    private func miniDeleteDestinationIsValid() -> Bool {
        let current = KeyboardTextDestination(textDocumentProxy)
        let valid = wordEdits.hasTrackedContext ? wordEdits.observe(textDocumentProxy) : deleteDestination == current
        if valid { deleteDestination = current }
        else if !wordEdits.hasPendingEdit { currentKey?.cancelPress() }
        return valid
    }

    private func clearAllText() -> Bool {
        guard deleteDestination == KeyboardTextDestination(textDocumentProxy) else { return false }
        resetComposition() // Invalidate outstanding candidate edits before clearing.
        deleteDestination = nil
        playTapFeedback()
        let session = ClearTextSession(proxy: textDocumentProxy)
        clearText = session
        continueClearing(session)
        return true
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
        #if KEYBOARD_TESTING
        testingTapFeedbackCount += 1
        #endif
        tapFeedback.tap()
    }

    private func playHoldFeedback() {
        #if KEYBOARD_TESTING
        testingTapFeedbackCount += 1
        #endif
        tapFeedback.tap(confirmation: true)
    }

    private func refreshKeyboardPreferences() {
        applyKeyboardPreferences(.load())
        lastPreferenceRefresh = Date()
    }

    func applyKeyboardPreferences(_ preferences: KeyboardPreferences) {
        tapFeedback.configure(preferences)
        if autoCorrectionEnabled != preferences.autoCorrectionEnabled || smartSpacingEnabled != preferences.smartSpacingEnabled {
            typingAssistance.clear()
            autoCorrectionEnabled = preferences.autoCorrectionEnabled
            smartSpacingEnabled = preferences.smartSpacingEnabled
            if pinyin.input.isEmpty && !typingPending { compositionAutoCorrection = autoCorrectionEnabled; renderCandidates() }
        }
        guard mixedTypingEnabled != preferences.mixedTypingEnabled else { return }
        mixedTypingEnabled = preferences.mixedTypingEnabled
        // A preference refresh must not change the candidate Space will accept
        // in a word already being composed or invalidate queued keystrokes.
        if !typingPending && pinyin.input.isEmpty { compositionUsesMixedTyping = mixedTypingEnabled }
        updateKeyLegends()
    }

    private func tap(_ value: String) {
        // A key invalidates an in-flight tap even before its store read returns.
        if snippetBusy { cancelSnippetTask() }
        if snippetExpansion != nil {
            snippetEpoch = UUID(); cancelSnippetTask()
            snippetExpansion?.cancel(); snippetExpansion = nil; snippetOperation = nil
            snippetMatch = nil; snippetRaw.clear(); snippetReadGeneration = -1
            snippetStrip.show(.loading)
        }
        endCursor = nil
        if value != "space" { doubleSpace.reset() }
        let miniDelete = isMiniMode && value == "delete"
        let editing = miniDelete ? KeyboardEditSwipe.deleteWord : KeyboardEditSwipe(rawValue: value)
        if editing == nil { wordEdits.clear() }
        pasteGeneration += 1
        clearText = nil
        if command != nil { cancelHold() }
        let waitingForPinyin = usesPinyin && !pinyinReady && (value != "language" || !deferredTaps.isEmpty)
        if typingPending || waitingForPinyin {
            if deferredTaps.count < 64 {
                deferredTaps.append(value)
                // Cancel only speculative multi-error work, never the ordered
                // Rime edit or its callback. Space still uses the displayed path.
                if value == "delete" || value.utf8.count == 1 && value.first?.isLetter == true {
                    PinyinEngine.shared.cancelCorrectionSearch()
                }
            }
            return
        }
        if handleSnippetLiteral(value) { return }
        if !["123", "#+=", "ABC", "shift"].contains(value) {
            snippetRaw.clear(); snippetMatch = nil; snippetReadGeneration = -1
        }
        if let editing {
            typingAssistance.clear()
            if !pinyin.input.isEmpty {
                deferredTaps.insert(value, at: 0)
                sendTyping(visibleCandidates.first?.action ?? .english(compositionCase.apply(to: pinyin.input)))
                return
            }
            insertingTypedText = true
            let changed: Bool
            switch editing {
            case .deleteWord:
                if miniDelete, textDocumentProxy.selectedText?.isEmpty == false { textDocumentProxy.deleteBackward(); changed = true }
                else { changed = wordEdits.deleteWord(in: textDocumentProxy) }
            case .restoreWord: changed = wordEdits.restoreWord(in: textDocumentProxy)
            case .endOfText:
                wordEdits.clear()
                endCursor = CursorDragSession(proxy: textDocumentProxy, point: .zero); endCursorSteps = 0
                changed = endCursor?.advanceToEnd(in: textDocumentProxy) == true
            case .lineBreak:
                wordEdits.clear()
                // Unicode LINE SEPARATOR, not the Return/Send operation ("\n").
                textDocumentProxy.insertText("\u{2028}"); changed = true
            }
            insertingTypedText = false
            if miniDelete { deleteDestination = KeyboardTextDestination(textDocumentProxy) }
            if changed && !miniDelete {
                if editing == .lineBreak { playHoldFeedback() } else { playTapFeedback() }
            }
            updateHeader(); return
        }
        switch value {
        case "kaomoji", "emoji":
            if !pinyin.input.isEmpty {
                deferredTaps.insert(value, at: 0)
                sendTyping(visibleCandidates.first?.action ?? .english(compositionCase.apply(to: pinyin.input)))
                return
            }
            typingAssistance.clear(); setEmojiVisible(true)
            if value == "kaomoji" { emojiPanel.showEmoticons() }
        case "expand": setMiniMode(false)
        case "language":
            typingAssistance.clear()
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
        case "123": setMiniMode(false); page = 1; buildKeys()
        case "#+=": page = 2; buildKeys()
        case "ABC": page = 0; buildKeys()
        case "globe": resetComposition(); advanceToNextInputMode()
        case "delete":
            if !pinyin.input.isEmpty { sendTyping(.key(0xff08)) }
            else {
                insertingTypedText = true
                if language == .english { typingAssistance.delete(in: textDocumentProxy, correction: autoCorrectionEnabled); renderCandidates() }
                else { textDocumentProxy.deleteBackward() }
                if deleteDestination != nil { deleteDestination = KeyboardTextDestination(textDocumentProxy) }
                insertingTypedText = false
            }
        case "space":
            if !pinyin.input.isEmpty {
                if let first = visibleCandidates.first { sendTyping(first.spaceAction) }
                else { commitSpelling() }
            }
            else {
                insertingTypedText = true
                let replaced = doubleSpace.replaceIfMatching(in: textDocumentProxy, language: language)
                insertingTypedText = false
                if replaced { typingAssistance.clear(); renderCandidates() }
                else { insertAssistedText(" "); doubleSpace.remember(in: textDocumentProxy) }
            }
        case "tab": insertAssistedText("\t")
        case "left", "right":
            if !pinyin.input.isEmpty { commitSpelling() }
            else { textDocumentProxy.adjustTextPosition(byCharacterOffset: value == "left" ? -1 : 1) }
        case "return":
            // First Return accepts the spelling only; never submits an unfinished Pinyin word.
            if !pinyin.input.isEmpty { commitSpelling() }
            else { insertAssistedText("\n") }
        default:
            if usesPinyin, (value.count == 1 && value.first!.isASCII && value.first!.isLetter || value == "'" && !pinyin.input.isEmpty) {
                if pinyin.input.isEmpty {
                    compositionCase = capsLock ? .uppercase : shifted ? .initialCapital : .lowercase
                    compositionUsesMixedTyping = mixedTypingEnabled
                    compositionAutoCorrection = autoCorrectionEnabled
                }
                sendTyping(.key(Int32(value.lowercased().utf8.first!)))
                if shifted && !capsLock { shifted = false; updateKeyLegends() }
                return
            }
            if !pinyin.input.isEmpty {
                // Commit spelling before punctuation/numbers, preserving input order.
                deferredTaps.insert(value, at: 0); commitSpelling(); return
            }
            insertAssistedText(page == 0 && shifted ? value.uppercased() : value)
            // Complete a punctuation choice before returning to letters, including
            // Chinese punctuation and alternatives selected with a symbol hold.
            if page > 0, !value.isEmpty,
               value.unicodeScalars.allSatisfy({ CharacterSet.punctuationCharacters.contains($0) }) {
                page = 0; buildKeys()
            }
            if shifted && !capsLock && page == 0 { shifted = false; updateKeyLegends() }
        }
    }
    private func commitSpelling() {
        sendTyping(.english(compositionCase.apply(to: pinyin.input)))
    }

    private func insertAssistedText(_ text: String) {
        insertingTypedText = true
        if language == .english {
            typingAssistance.insert(text, into: textDocumentProxy, correction: autoCorrectionEnabled, spacing: smartSpacingEnabled)
        } else { textDocumentProxy.insertText(text) }
        insertingTypedText = false
        renderCandidates()
    }

    private var sameTypingDestination: Bool {
        typingDocument == KeyboardDocumentIdentity.snapshot(textDocumentProxy) &&
        typingBefore == textDocumentProxy.documentContextBeforeInput &&
        typingAfter == textDocumentProxy.documentContextAfterInput &&
        typingSelection == textDocumentProxy.selectedText
    }

    private func rememberTypingDestination() {
        typingDocument = KeyboardDocumentIdentity.snapshot(textDocumentProxy)
        typingBefore = textDocumentProxy.documentContextBeforeInput
        typingAfter = textDocumentProxy.documentContextAfterInput
        typingSelection = textDocumentProxy.selectedText
    }

    private func sendTyping(_ action: PinyinEngine.Action) {
        wordEdits.clear()
        if typingDocument == nil { rememberTypingDestination() }
        let generation = typingGeneration
        typingPending = true
        updateHeader()
        candidatePanel.setPending(true)
        PinyinEngine.shared.perform(action) { [weak self] result in
            guard let self, generation == self.typingGeneration else { return }
            guard self.sameTypingDestination else { self.resetComposition(); return }
            self.typingPending = false
            self.pinyin = result
            if let error = result.error { self.pendingMiniMode = nil; self.cursorKey?.cancelPress(); self.showError(error) }
            self.insertingTypedText = true
            // Replace the marked spelling with one plain insertion, never append a
            // second copy of it. Real hosts coalesce a turn's proxy writes and can
            // apply insertions before marked-text writes, so committing with
            // setMarkedText + unmarkText let a queued digit/symbol land before it
            // ("B03" became "0B3"). Insertions keep their relative order.
            if !result.committed.isEmpty {
                self.textDocumentProxy.insertText(result.committed)
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
            if self.currentKey?.value == "space", self.currentKey?.isPressed == true {
                self.cursorPressDestination = KeyboardTextDestination(self.textDocumentProxy)
            }
            if self.currentKey?.isPressed == true { self.editingSwipeDestination = KeyboardTextDestination(self.textDocumentProxy) }
            self.insertingTypedText = false
            if result.input.isEmpty { self.typingDocument = nil }
            self.renderCandidates()
            self.drainTypingTaps()
        }
    }

    private func drainTypingTaps() {
        guard !typingPending, (!usesPinyin || pinyinReady) else { return }
        guard !deferredTaps.isEmpty else {
            prepareCursorDrag()
            if let pendingMiniMode { setMiniMode(pendingMiniMode) }
            return
        }
        let value = deferredTaps.removeFirst()
        tap(value)
        if !typingPending { drainTypingTaps() }
    }

    private func resetComposition() {
        typingAssistance.clear()
        wordEdits.clear(); editingSwipeDestination = nil
        if let cursorKey { cursorKey.cancelPress() }
        pendingMiniMode = nil
        // Only touch marked text in the document that owns this composition.
        if !documentDetached, let typingDocument, typingDocument == KeyboardDocumentIdentity.snapshot(textDocumentProxy) {
            insertingTypedText = true
            textDocumentProxy.unmarkText()
            insertingTypedText = false
        }
        typingGeneration += 1
        typingDocument = nil; typingPending = false
        deferredTaps.removeAll(); pinyin = PinyinEngine.Snapshot()
        compositionUsesMixedTyping = mixedTypingEnabled
        compositionAutoCorrection = autoCorrectionEnabled
        PinyinEngine.shared.perform(.clear) { _ in }
        renderCandidates()
    }

    private func renderCandidates() {
        if language != .chinese {
            let choices = typingAssistance.suggestions
            visibleCandidates = choices.isEmpty ? [] : (choices + [typingAssistance.word]).enumerated().map {
                PinyinCandidates.Candidate(text: $0.element, identifier: "candidate.typing.\($0.offset)", action: .english($0.element))
            }
        }
        else {
            visibleCandidates = bilingualProvider.choices(for: pinyin, letterCase: compositionCase,
                policy: compositionUsesMixedTyping ? .experimental : .conservative, correctEnglish: compositionAutoCorrection)
        }
        let emojiQueries = language == .english ? [typingAssistance.word]
            : (pinyin.input.isEmpty ? [] : [pinyin.input] + Array(visibleCandidates.prefix(5).map(\.text)))
        let emojis = EmojiCatalog.suggestions(for: emojiQueries)
        if !emojis.isEmpty {
            // Emoji is an explicit choice; preserve word correction and Space's default.
            if visibleCandidates.isEmpty, language == .english, !typingAssistance.word.isEmpty {
                visibleCandidates = [.init(text: typingAssistance.word, identifier: "candidate.typing.original", action: .english(typingAssistance.word))]
            }
            let choices = emojis.enumerated().map { index, glyph in
                PinyinCandidates.Candidate(text: glyph, identifier: "candidate.emoji.\(index)", action: .english(glyph))
            }
            visibleCandidates.insert(contentsOf: choices, at: min(1, visibleCandidates.count))
        }
        candidateListGeneration &+= 1; candidateFetchPending = false
        nextCandidateOffset = pinyin.candidateOffset + pinyin.candidates.count
        hasMoreCandidates = !pinyin.isLastPage && !pinyin.input.isEmpty
        candidatePanel.setPending(typingPending)
        updateHeader()
        candidatePanel.show(visibleCandidates, hasMore: hasMoreCandidates)
    }

    private func loadMoreCandidates() {
        guard !typingPending, !candidateFetchPending, hasMoreCandidates, !candidatePanel.isHidden else { return }
        candidateFetchPending = true
        let generation = candidateListGeneration
        let revision = pinyin.revision
        PinyinEngine.shared.candidates(after: nextCandidateOffset, revision: revision) { [weak self] batch in
            guard let self, generation == self.candidateListGeneration else { return }
            self.candidateFetchPending = false
            guard !self.typingPending, self.sameTypingDestination, let batch else { return }
            self.visibleCandidates += batch.texts.enumerated().map { index, text in
                let absoluteIndex = batch.offset + index
                return PinyinCandidates.Candidate(text: text, identifier: "candidate.absolute.\(absoluteIndex)", action: .chooseAbsolute(absoluteIndex))
            }
            self.nextCandidateOffset = batch.offset + batch.texts.count
            self.hasMoreCandidates = batch.hasMore && !batch.texts.isEmpty
            self.candidatePanel.show(self.visibleCandidates, hasMore: self.hasMoreCandidates, appending: true)
        }
    }


    // MARK: Local-only Snippets
    private var snippetIsComposing: Bool { snippetComposing || typingPending || !pinyin.input.isEmpty || command != nil || dictationText != nil }
    private var snippetDestination: SnippetDestination? {
        guard !documentDetached else { return nil }
        return SnippetDestination.capture(textDocumentProxy, composing: snippetIsComposing)
    }
    @objc func clearSnippetSession() {
        snippetEpoch = UUID(); cancelSnippetTask(); snippetTask = nil
        snippetExpansion?.cancel(); snippetExpansion = nil; snippetOperation = nil
        snippetRaw.clear(); snippetMatch = nil; snippetReadGeneration = -1
        snippetsOpen = false; snippetComposing = false; snippetDocumentID = nil; snippetAccess = nil
        snippetStrip.show(.loading); snippetStrip.isHidden = true
    }
    private func checkSnippetPermission() {
        if !documentDetached {
            let document = KeyboardDocumentIdentity.read(textDocumentProxy)
            if let previous = snippetDocumentID, previous != document {
                clearSnippetSession()
                if isViewLoaded { updateHeader() }
            }
            snippetDocumentID = document
        }
        guard clipPillsAllowed else {
            // Polls must not continually dismiss the permission information layer.
            guard snippetAccess != false else { return }
            snippetAccess = false
            cancelSnippetTask(); snippetExpansion?.cancel(); snippetExpansion = nil
            snippetEpoch = UUID(); snippetRaw.clear(); snippetMatch = nil; snippetOperation = nil
            snippetReadGeneration = -1
            snippetStrip.show(.permission)
            if isViewLoaded { updateHeader() }
            return
        }
        let restored = snippetAccess == false
        snippetAccess = true
        if restored, snippetsOpen { openSnippets() }
    }
    private func cancelSnippetTask() {
        snippetTask?.cancel(); snippetTask = nil
        if snippetOperation != nil { snippetLastTap = .distantPast }
        snippetOperation = nil; snippetMatchRead = nil
    }
    private func readSnippets(_ store: SnippetStore) async -> Result<[Snippet], Error> {
        #if KEYBOARD_TESTING
        if let testingSnippetRead { return await testingSnippetRead() }
        #endif
        return await Task.detached { Result { try store.load() } }.value
    }
    private func invalidateSnippetContext() {
        let hadMatch = snippetMatch != nil, hadTap = snippetBusy
        cancelSnippetTask()
        snippetMatch = nil; snippetRaw.clear(); snippetReadGeneration = -1
        if hadTap { snippetNotice(snippetsOpen ? SnippetCopy.insertionFailure : SnippetCopy.unsafe) }
        else if hadMatch { snippetStrip.show(.loading); updateHeader() }
    }
    private func snippetWillChange(_ input: UITextInput?, selection: Bool = false) {
        if let input { snippetComposing = input.markedTextRange != nil }
        guard !insertingTypedText else { return }
        snippetContextRevision &+= 1
        if let expansion = snippetExpansion {
            expansion.willChange(selection: selection)
            return
        }
        // Invalidate ownership even before publication. Matching context after
        // an away-and-back event cannot re-authorize a pending read.
        invalidateSnippetContext()
    }
    private func snippetDocumentChanged(_ input: UITextInput?, selection: Bool = false) {
        if let input { snippetComposing = input.markedTextRange != nil }
        checkSnippetPermission()
        guard !insertingTypedText else { return }
        snippetContextRevision &+= 1
        if let expansion = snippetExpansion { expansion.changed(snippetDestination, selection: selection); return }
        if selection || snippetMatch != nil || snippetBusy {
            invalidateSnippetContext(); return
        }
        // A bare text acknowledgment may complete owned raw output after the
        // debounce. Restart its pending read with this revision, never a stale one.
        if snippetMatchRead != nil { cancelSnippetTask() }
        snippetRaw.observe(snippetDestination)
        refreshSnippetMatch()
    }
    private func handleSnippetLiteral(_ value: String) -> Bool {
        guard !snippetIsComposing, let destination = snippetDestination else { return false }
        if value == "delete", snippetRaw.canDelete(at: destination) {
            snippetMatch = nil; cancelSnippetTask(); snippetReadGeneration = -1
            snippetRaw.deleted(from: destination)
            insertingTypedText = true; textDocumentProxy.deleteBackward(); insertingTypedText = false
            renderCandidates(); refreshSnippetMatch(); return true
        }
        let text = page == 0 && shifted ? value.uppercased() : value
        guard value.count == 1, snippetRaw.wantsLiteral(text, at: destination) else { return false }
        snippetMatch = nil; cancelSnippetTask(); snippetReadGeneration = -1
        typingAssistance.clear(); wordEdits.clear()
        snippetRaw.inserted(text, from: destination)
        insertingTypedText = true; textDocumentProxy.insertText(text); insertingTypedText = false
        if page > 0, value == "@" { page = 0; buildKeys() }
        if shifted && !capsLock { shifted = false; updateKeyLegends() }
        renderCandidates(); refreshSnippetMatch()
        return true
    }
    private func refreshSnippetMatch() {
        guard !snippetsOpen, !snippetBusy, clipPillsAllowed, snippetMatchRead == nil,
              snippetRaw.token.hasPrefix("@@"), snippetRaw.token.count > 2,
              snippetReadGeneration != snippetRaw.generation else { return }
        let generation = snippetRaw.generation, epoch = snippetEpoch, store = snippetStore, read = UUID()
        cancelSnippetTask(); snippetMatchRead = read
        snippetTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.snippetMatchRead == read { self.snippetMatchRead = nil } }
            do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
            let deadline = ContinuousClock.now.advanced(by: .milliseconds(600))
            // Scheduled is not evaluated: delayed proxies can acknowledge after
            // the debounce. Only an exact owned acknowledgment permits lookup.
            while true {
                guard !Task.isCancelled, self.snippetEpoch == epoch, self.snippetMatchRead == read,
                      self.snippetRaw.generation == generation, !self.snippetsOpen, self.clipPillsAllowed,
                      let destination = self.snippetDestination else { return }
                if let token = self.snippetRaw.matchable(at: destination) {
                    self.snippetRaw.observe(destination)
                    let revision = self.snippetContextRevision
                    let result = await self.readSnippets(store)
                    guard !Task.isCancelled, self.snippetEpoch == epoch, self.snippetMatchRead == read,
                          self.snippetContextRevision == revision, self.clipPillsAllowed,
                          !self.snippetsOpen, self.snippetRaw.generation == generation,
                          self.snippetDestination == destination else { return }
                    self.snippetReadGeneration = generation
                    guard case .success(let records) = result,
                          let record = records.first(where: { $0.key == token.dropFirst(2).lowercased() }) else { return }
                    self.snippetMatch = (record, token, destination, generation)
                    self.snippetStrip.matching = true; self.snippetStrip.show(.data([record])); self.updateHeader()
                    return
                }
                self.snippetRaw.observe(destination)
                guard self.snippetRaw.generation == generation, ContinuousClock.now < deadline else { return }
                do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
            }
        }
    }
    func openSnippets() {
        checkSnippetPermission()
        cancelSnippetTask(); snippetExpansion?.cancel(); snippetExpansion = nil
        snippetOperation = nil; snippetMatch = nil; snippetsOpen = true
        snippetStrip.matching = false
        candidatePanel.setExpanded(false)
        snippetEpoch = UUID()
        guard clipPillsAllowed else { snippetStrip.show(.permission); updateHeader(); return }
        snippetStrip.show(.loading); updateHeader()
        let epoch = snippetEpoch, store = snippetStore
        snippetTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.readSnippets(store)
            guard !Task.isCancelled, self.snippetEpoch == epoch, self.snippetsOpen else { return }
            guard self.clipPillsAllowed else { self.checkSnippetPermission(); return }
            switch result {
            case .success(let records): self.snippetStrip.show(records.isEmpty ? .empty : .data(records))
            case .failure: self.snippetStrip.show(.failure)
            }
        }
    }
    func closeSnippets() {
        snippetEpoch = UUID()
        cancelSnippetTask(); snippetExpansion?.cancel(); snippetExpansion = nil
        snippetOperation = nil; snippetsOpen = false; snippetMatch = nil
        // Keep the raw segment literal, but suppress this generation's match.
        snippetReadGeneration = snippetRaw.generation
        snippetStrip.show(.loading); updateHeader()
        UIAccessibility.post(notification: .layoutChanged, argument: helperScroll.snippet)
    }
    func selectSnippet(_ displayed: Snippet) {
        guard !snippetBusy, Date().timeIntervalSince(snippetLastTap) >= 0.4 else { return }
        guard clipPillsAllowed else { checkSnippetPermission(); return }
        let match = snippetsOpen ? nil : snippetMatch
        guard snippetsOpen || match != nil else { return }
        guard let destination = snippetDestination else { snippetNotice(match == nil ? SnippetCopy.insertionFailure : SnippetCopy.unsafe); return }
        if let match {
            guard match.record.id == displayed.id, match.destination == destination,
                  match.generation == snippetRaw.generation,
                  snippetRaw.matchable(at: destination) == match.token else { snippetNotice(SnippetCopy.unsafe); return }
        }
        let epoch = snippetEpoch, contextRevision = snippetContextRevision, store = snippetStore, operation = UUID()
        cancelSnippetTask()
        snippetLastTap = Date(); snippetOperation = operation
        snippetTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.snippetOperation == operation { self.snippetOperation = nil } }
            let result = await self.readSnippets(store)
            guard !Task.isCancelled, self.snippetEpoch == epoch, self.snippetOperation == operation else { return }
            guard self.clipPillsAllowed else { self.checkSnippetPermission(); return }
            guard case .success(let records) = result else {
                self.snippetMatch = nil; self.snippetStrip.show(.failure); self.snippetsOpen = true; self.updateHeader(); return
            }
            guard let record = records.first(where: { $0.id == displayed.id }), record.revision == displayed.revision else {
                self.snippetNotice(SnippetError.stale.message)
                self.snippetTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    guard let self, self.snippetEpoch == epoch, self.snippetsOpen else { return }
                    self.openSnippets() // Fresh again; refresh never inserts automatically.
                }
                return
            }
            guard self.snippetContextRevision == contextRevision, self.snippetDestination == destination else { self.snippetNotice(match == nil ? SnippetCopy.insertionFailure : SnippetCopy.unsafe); return }
            self.typingAssistance.clear(); self.wordEdits.clear(); self.doubleSpace.reset(); self.pasteGeneration += 1
            if let match {
                guard self.snippetMatch?.generation == match.generation,
                      self.snippetRaw.matchable(at: destination) == match.token else { self.snippetNotice(SnippetCopy.unsafe); return }
                let expansion = SnippetExpansion(destination: destination)
                self.snippetExpansion = expansion
                let completed = await expansion.run(token: match.token, content: record.content, proxy: self.textDocumentProxy,
                    permitted: { [weak self] in self?.clipPillsAllowed == true && self?.snippetEpoch == epoch && self?.documentDetached == false },
                    composing: { [weak self] in self?.snippetIsComposing != false })
                guard self.snippetEpoch == epoch else { return }
                self.snippetExpansion = nil; self.snippetMatch = nil; self.snippetRaw.clear(); self.snippetReadGeneration = -1
                if completed { self.playTapFeedback(); self.updateHeader() }
                else { self.snippetNotice(SnippetCopy.unsafe) }
            } else {
                // Intentionally NOT completePaste: no code extraction, history,
                // length limit, clipboard fallback or prefix deletion.
                self.insertingTypedText = true
                self.textDocumentProxy.insertText(record.content)
                self.insertingTypedText = false
                self.snippetRaw.clear(); self.snippetReadGeneration = -1
                self.snippetStrip.show(records.isEmpty ? .empty : .data(records))
                self.playTapFeedback() // No invented success/failure receipt.
            }
        }
    }
    private func snippetNotice(_ text: String) {
        snippetMatch = nil; snippetRaw.clear(); snippetReadGeneration = -1
        snippetsOpen = true; snippetStrip.matching = false
        snippetStrip.show(.notice(text)); updateHeader()
        UIAccessibility.post(notification: .announcement, argument: text)
    }

    private func configureInputHelpers() {
        pasteConfiguration = UIPasteConfiguration(forAccepting: NSString.self)
        let strip = helperScroll
        strip.onePassword.setShortcutImage(UIImage(named: "OnePassword"))
        strip.onePassword.accessibilityIdentifier = "keyboard.open-1password"
        strip.onePassword.accessibilityLabel = "Open 1Password"
        strip.onePassword.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.pasteGeneration += 1
            guard let openURL = self.hostOpenURL else { self.showError("Open 1Password from your Home Screen."); return }
            openURL(URL(string: "onepassword://")!) { accepted in
                if !accepted { Task { @MainActor in self.showError("Couldn’t open 1Password. Open it from your Home Screen.") } }
            }
        }, for: .touchUpInside)
        strip.messages.setShortcutImage(UIImage(systemName: "message.fill"))
        strip.messages.accessibilityIdentifier = "keyboard.open-messages"
        strip.messages.accessibilityLabel = "Open Messages"
        strip.messages.addAction(UIAction { [weak self] _ in self?.openShortcut("sms:", name: "Messages") }, for: .touchUpInside)
        strip.snippet.setShortcutImage(UIImage(systemName: "text.bubble", withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .regular)))
        strip.snippet.iconView.tintColor = .label
        strip.snippet.accessibilityIdentifier = "keyboard.snippet"
        strip.snippet.accessibilityLabel = "Snippet"
        strip.snippet.addAction(UIAction { [weak self] _ in self?.openSnippets() }, for: .touchUpInside)
        strip.history.accessibilityIdentifier = "keyboard.clipboard-history"
        strip.history.accessibilityLabel = "Clipboard History"
        strip.history.showsMenuAsPrimaryAction = true
        strip.history.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            guard let self else { completion([]); return }
            completion(self.clipboardHistoryMenu())
        }])
        strip.onSelect = { [weak self] clip in self?.pasteClipPill(clip) }
    }

    /// Clip pills paste the full original (code pill: re-validated codeOnly) and
    /// never reorder history, so repeated taps hit the same pill.
    func pasteClipPill(_ clip: ClipPill) {
        if clip.isCode { pasteCopiedCode(); return }
        guard let request = beginPaste(codeOnly: false) else { return }
        // Keep a fresh code pill in place so neighbouring pills do not jump.
        completePaste(clip.text, request: request, remember: false, consumeCode: false)
    }

    func clipboardHistoryMenu() -> [UIMenuElement] {
        let request = beginPaste(codeOnly: textDocumentProxy.textContentType == .oneTimeCode)
        var actions: [UIMenuElement] = clipboardHistory.items.map { text in
            UIAction(title: ClipboardHistory.preview(text), attributes: request == nil ? [.disabled] : []) { [weak self] _ in
                guard let self, let request else { return }
                self.completePaste(text, request: request, remember: false)
            }
        }
        if actions.isEmpty { actions.append(UIAction(title: "No recent text clips", attributes: [.disabled]) { _ in }) }
        else { actions.append(UIAction(title: "Clear History", image: UIImage(systemName: "trash"), attributes: [.destructive]) { [weak self] _ in
            self?.clipboardHistory.clear(); self?.refreshCopiedCodeIndicator()
        }) }
        // Recent final dictation results (local only), e.g. after a dismissal mid-polish.
        let recent = dictationRecents.items
        guard !recent.isEmpty else { return actions }
        var dictated: [UIMenuElement] = recent.map { item in
            UIAction(title: ClipboardHistory.preview(item.text), subtitle: item.date.formatted(.relative(presentation: .named)),
                     attributes: request == nil ? [.disabled] : []) { [weak self] _ in
                guard let self, let request else { return }
                self.completePaste(item.text, request: request, remember: false)
            }
        }
        dictated.append(UIAction(title: "Clear Recent Dictation", image: UIImage(systemName: "trash"), attributes: [.destructive]) { [weak self] _ in
            self?.dictationRecents.clear()
        })
        return [UIMenu(title: "Clipboard", options: .displayInline, children: actions),
                UIMenu(title: "Recent Dictation", options: .displayInline, children: dictated)]
    }

    private func openShortcut(_ scheme: String, name: String) {
        pasteGeneration += 1
        guard let openURL = hostOpenURL, let url = URL(string: scheme) else { showError("Open \(name) from your Home Screen."); return }
        // No recipient or number: opening a shortcut must never send a message or dial.
        openURL(url) { accepted in
            if !accepted { Task { @MainActor in self.showError("Open \(name) from your Home Screen.") } }
        }
    }

    @objc private func refreshCopiedCodes() {
        #if KEYBOARD_TESTING
        if testingDocumentProxy != nil { return } // Unit tests never inspect the real clipboard.
        #endif
        guard keyboardVisible, hasFullAccess, command == nil, currentKey?.isPressed != true else { return }
        copiedCodes.onObservedText = { [weak self] text in self?.clipboardHistory.record(text) }
        copiedCodes.refresh()
        refreshCopiedCodeIndicator()
    }
    /// Without Full Access (or with no history) the strip keeps only the two
    /// shortcuts and the clock pill.
    private var clipPillsAllowed: Bool {
        #if KEYBOARD_TESTING
        if testingDocumentProxy != nil { return testingFullAccess ?? true }
        #endif
        return hasFullAccess
    }
    func refreshCopiedCodeIndicator() {
        guard !helperScroll.isHidden else { return } // Rebuilt when the strip is shown.
        guard clipPillsAllowed else { helperScroll.show([]); return }
        helperScroll.show(ClipPill.pills(history: clipboardHistory.items, code: copiedCodes.observedCode,
                                         codeAvailable: copiedCodes.isAvailable, codeSource: copiedCodes.observedSource))
    }
    func pasteCopiedCode() {
        guard let request = beginPaste(codeOnly: true) else { return }
        let code = copiedCodes.takeCode()
        refreshCopiedCodeIndicator()
        guard let code else { return }
        completePaste(code, request: request)
    }

    func beginPaste(codeOnly: Bool) -> PasteRequest? {
        typingAssistance.clear(); renderCandidates()
        guard !isMiniMode, cursorKey == nil, command == nil, activationRequest == nil, !typingPending,
              pinyin.input.isEmpty, deferredTaps.isEmpty else { return nil }
        pasteGeneration += 1
        return PasteRequest(generation: pasteGeneration, destination: KeyboardTextDestination(textDocumentProxy), codeOnly: codeOnly)
    }
    func completePaste(_ text: String, request: PasteRequest, remember: Bool = true, consumeCode: Bool = true) {
        guard request.generation == pasteGeneration,
              request.destination == KeyboardTextDestination(textDocumentProxy), command == nil,
              !isMiniMode, cursorKey == nil, !typingPending, pinyin.input.isEmpty, deferredTaps.isEmpty else { return }
        pasteGeneration += 1
        guard text.utf16.count <= 20_000 else { showError("This clipboard text is too long to paste here."); return }
        let insertion: String
        if request.codeOnly {
            guard let code = VerificationCode.extract(from: text) else { showError("Copy a single verification code, then tap Paste Code."); return }
            insertion = code
        } else { insertion = text }
        guard !insertion.isEmpty else { return }
        wordEdits.clear()
        insertingTypedText = true
        textDocumentProxy.insertText(insertion)
        insertingTypedText = false
        if consumeCode { copiedCodes.consume() }
        if remember && !request.codeOnly { clipboardHistory.record(text) }
        playTapFeedback(); updateHeader()
    }
    override func paste(itemProviders: [NSItemProvider]) {
        guard let provider = itemProviders.first(where: { $0.canLoadObject(ofClass: NSString.self) }),
              let request = beginPaste(codeOnly: textDocumentProxy.textContentType == .oneTimeCode) else { return }
        // Concealed copies (e.g. a 1Password password) paste but are never recorded.
        let concealed = itemProviders.contains { ConcealedPasteboard.isConcealed($0.registeredTypeIdentifiers) }
        provider.loadObject(ofClass: NSString.self) { [weak self] object, _ in
            let text = object as? String
            Task { @MainActor in
                guard let self, let text else { return }
                self.completePaste(text, request: request, remember: !concealed)
            }
        }
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
        // Gesture targets use actual keycaps, never the expanded typing targets.
        // Translation is a hover/release action; sliding away disarms it.
        guard let target = keys.first(where: {
            (["delete", "return", "language"].contains($0.value)) && $0.convert($0.bounds, to: view).contains(location)
        }) else { clearDictationTarget(); return true }
        if target.value == "language" {
            if dictationTargetKey !== target {
                clearDictationTarget()
                dictationTargetKey = target; target.dictationFeedback = .translate
                playTapFeedback()
            }
            return true
        }
        clearDictationTarget()
        if target.value == "delete" {
            cancelHold(discard: true)
            target.dictationFeedback = .cancel
        } else {
            endHold(submitAfterPolish: true)
            target.dictationFeedback = textDocumentProxy.returnKeyType == .send ? .send : .finish
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
        return VoiceConfiguration.microphoneAllowed
    }
    private func writeVoiceCommand(_ command: VoiceCommand) throws {
#if KEYBOARD_TESTING
        if testingVoiceAvailable { testingVoiceCommands.append(command); return }
#endif
        voiceSession.command(command)
    }

    private func beginHold() {
        typingAssistance.clear(); renderCandidates()
        wordEdits.clear(); editingSwipeDestination = nil
        pasteGeneration += 1
        guard !typingPending, pinyin.input.isEmpty, deferredTaps.isEmpty else {
            showError("Finish the current word before dictating."); return
        }
        guard command == nil else { showError("Please wait for your previous dictation."); return }
        guard voiceAccessAllowed else { showError("Enable Allow Full Access for vvhisper in Settings."); return }
        guard voiceReady else { showError("Open vvhisper once to allow microphone access.", offerHostLaunch: true); return }
        #if !KEYBOARD_TESTING
        webCapture.attach(to: view)
        #endif
        let command = VoiceCommand(id: UUID(), phase: .recording, updatedAt: Date())
        let text = DictationTextSession(id: command.id, proxy: textDocumentProxy)
        do {
            try writeVoiceCommand(command)
            clearDictationTarget()
            dictationText = text; self.command = command; started = true; releaseTime = nil
            quietKeys.start(id: command.id, at: Date())
            let meterTimer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.command?.id == command.id, self.command?.phase == .recording else { return }
                    self.receiveVoiceLevel(self.voiceSession.level)
                }
            }
            levelTimer = meterTimer; RunLoop.main.add(meterTimer, forMode: .common)
            errorUntil = .distantPast; offersHostLaunch = false
            status.text = nil; updateHeader(); playTapFeedback()
        }
        catch { showError("Cannot reach vvhisper. Check Full Access.") }
    }
    private func endHold(submitAfterPolish: Bool = false, translate: Bool = false) {
        guard var command, command.phase == .recording, started else { return }
        guard sameDestination else { cancelHold(); showError("Text field changed. Dictation cancelled."); return }
        command.translate = translate ? true : nil
        command.phase = .finish; command.updatedAt = Date(); self.command = command; releaseTime = Date()
        dictationText?.finishRecording(submitAfterPolish: submitAfterPolish)
        stopQuietKeys(animated: true)
        try? writeVoiceCommand(command); status.text = "Polishing…"; updateHeader()
    }
    private func cancelHold(discard: Bool = false) {
        stopQuietKeys(animated: false)
        if var command { command.phase = .cancel; command.updatedAt = Date(); try? writeVoiceCommand(command) }
        command = nil; started = false; releaseTime = nil
        if !documentDetached { dictationText?.cancel(in: textDocumentProxy, discard: discard) }
        dictationText = nil
        clearDictationTarget()
        updateHeader()
    }

    /// Returns true when the reply ends the session, so polling can remove its file.
    @discardableResult func receiveVoiceReply(_ reply: VoiceReply) -> Bool {
        guard command != nil, let dictationText else { return false }
        switch dictationText.receive(reply, in: textDocumentProxy) {
        case .finished:
            let needsManualSend = dictationText.needsManualSend
            stopQuietKeys(animated: true)
            command = nil; self.dictationText = nil; started = false; releaseTime = nil
            status.text = "Hold a letter key to speak"
            let notices = [reply.notice, needsManualSend ? "Text ready. Tap Send in the app." : nil].compactMap { $0 }
            if !notices.isEmpty { showError(notices.joined(separator: " ")) }
            updateHeader()
            return true
        case .failed:
            stopQuietKeys(animated: false)
            command = nil; self.dictationText = nil; started = false; releaseTime = nil
            if let error = reply.error { clearDictationTarget(); showError(error) }
            else { status.text = "Hold a letter key to speak" }
            updateHeader()
            return true
        case .destinationChanged:
            cancelHold(); showError("Text field changed. Dictation cancelled."); return true
        case .partial:
            return false
        case .ignored: return false
        }
    }
    /// The meter is independent of transcript delivery, and can only affect
    /// the current recording in its still-verified destination.
    func receiveVoiceLevel(_ sample: VoiceLevel?, at now: Date = Date()) {
        guard command?.phase == .recording, sameDestination else { return }
        quietKeys.advance(sample, at: now, reducedMotion: UIAccessibility.isReduceMotionEnabled)
        for button in touchSurface.controls.compactMap({ $0 as? KeyboardSwitcherButton }) {
            let x = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: view).x
            button.quietFeedback.setLevel(quietKeys.level, position: Double(x / max(1, view.bounds.width)))
        }
        for key in keys {
            let x = key.convert(CGPoint(x: key.bounds.midX, y: key.bounds.midY), to: view).x
            key.quietFeedback.setLevel(quietKeys.level, position: Double(x / max(1, view.bounds.width)))
        }
    }
    private func stopQuietKeys(animated: Bool) {
        levelTimer?.invalidate(); levelTimer = nil
        quietKeys.reset()
        for button in touchSurface.controls.compactMap({ $0 as? KeyboardSwitcherButton }) { button.setDictating(false, animated: animated) }
        for key in keys {
            key.quietFeedback.reset(animated: animated)
            key.setLegendHidden(false, animated: animated)
        }
    }

    private func poll() {
        checkSnippetPermission()
        guard !documentDetached, KeyboardDocumentIdentity.read(textDocumentProxy) != nil else { return }
        if let endCursor {
            endCursorSteps += 1
            if endCursorSteps > 200 || !endCursor.advanceToEnd(in: textDocumentProxy) { self.endCursor = nil }
        }
        if !insertingTypedText { wordEdits.observe(textDocumentProxy) }
        cancelCursorIfDestinationChanged()
        #if DEBUG
        if pollDictationDeviceVerification() { return }
        pollCursorDeviceVerification()
        #endif
        if Date().timeIntervalSince(lastPreferenceRefresh) >= 1 {
            refreshKeyboardPreferences()
            refreshCopiedCodes()
        }
        defer { updateHeader() }
        if typingDocument != nil, !sameTypingDestination { resetComposition() }
        if let request = activationRequest {
            if voiceReady {
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
            if command.phase == .recording {
                command.updatedAt = Date(); self.command = command; try? writeVoiceCommand(command) }
            voiceSession.tick()
            if let reply = voiceSession.reply, receiveVoiceReply(reply) {
                voiceSession.acknowledge(reply)
                return
            }
            if let releaseTime, Date().timeIntervalSince(releaseTime) > VoiceReply.finalWait { cancelHold(); showError("Recognition timed out. Try again.") }
            else if !voiceAccessAllowed { cancelHold(); showError("Enable Full Access for dictation.") }
        } else if Date() > errorUntil {
            status.text = hasFullAccess && voiceReady ? "Hold a letter key to speak" : "Open vvhisper"
        }
    }
    private func showError(_ message: String, offerHostLaunch: Bool = false) {
        offersHostLaunch = offerHostLaunch
        status.text = message; errorUntil = Date().addingTimeInterval(6); updateHeader()
    }
    #if DEBUG
    private func pollDictationDeviceVerification() -> Bool {
        if var check = dictationCheck {
            let elapsed = Date().timeIntervalSince(check.started)
            var completed = false
            if command != nil, check.request.isFresh {
                if check.phase == 0, elapsed >= 0.1 {
                    receiveVoiceReply(VoiceReply(id: check.request.id, text: check.request.draft, isFinal: false))
                    check.phase = 1
                } else if check.phase == 1, elapsed >= 0.4 {
                    receiveVoiceReply(VoiceReply(id: check.request.id, text: check.request.draft + check.request.continuation, isFinal: false))
                    check.phase = 2
                } else if check.phase == 2, elapsed >= 0.8 {
                    command?.phase = .finish; dictationText?.finishRecording()
                    receiveVoiceReply(VoiceReply(id: check.request.id, text: check.request.draft, isFinal: false, polishing: true))
                    check.phase = 3
                } else if check.phase == 3, elapsed >= 1.8 {
                    completed = receiveVoiceReply(VoiceReply(id: check.request.id, text: check.request.polished, isFinal: true,
                        updatedAt: check.started.addingTimeInterval(1.8)))
                }
            }
            if command == nil || !check.request.isFresh || elapsed >= 4 {
                let state = dictationText?.verificationState(in: textDocumentProxy) ?? [:]
                try? VoiceIPC.write(DictationDeviceVerification.Result(id: check.request.id, completed: completed, elapsed: elapsed, state: state), to: "dictation-check-result.json")
                if command != nil { cancelHold() }
                dictationCheck = nil
            } else { dictationCheck = check }
            return true
        }
        guard keyboardVisible, command == nil, currentKey?.isPressed != true,
              let request = VoiceIPC.read("dictation-check-request.json", as: DictationDeviceVerification.Request.self),
              request.isFresh, Date().timeIntervalSince(request.createdAt) >= 1, request.id != lastDictationCheck,
              (textDocumentProxy.documentContextBeforeInput ?? "") == request.prefix,
              (textDocumentProxy.documentContextAfterInput ?? "").isEmpty else { return false }
        lastDictationCheck = request.id
        dictationText = DictationTextSession(id: request.id, proxy: textDocumentProxy)
        command = VoiceCommand(id: request.id, phase: .recording, updatedAt: Date())
        started = true
        dictationCheck = (request, Date(), 0)
        return true
    }
    private func pollCursorDeviceVerification() {
        if keyboardVisible, currentKey?.isPressed != true,
           let request = VoiceIPC.read("haptic-check-request.json", as: HapticDeviceVerification.Request.self),
           request.isFresh, Date().timeIntervalSince(request.createdAt) >= 2, request.id != lastHapticCheck,
           textDocumentProxy.documentContextBeforeInput == request.fixture,
           (textDocumentProxy.documentContextAfterInput ?? "").isEmpty {
            lastHapticCheck = request.id
            let documentID = KeyboardDocumentIdentity.snapshot(textDocumentProxy)
            hapticCheck.start(request: request, feedback: tapFeedback, stillValid: { [weak self] in
                guard let self else { return false }
                if request.observeTouches {
                    return self.keyboardVisible && KeyboardDocumentIdentity.snapshot(self.textDocumentProxy) == documentID
                }
                return self.keyboardVisible && self.currentKey?.isPressed != true &&
                    self.textDocumentProxy.documentContextBeforeInput == request.fixture &&
                    (self.textDocumentProxy.documentContextAfterInput ?? "").isEmpty
            })
        }
        let now = ProcessInfo.processInfo.systemUptime
        if var check = cursorCheck {
            guard check.request.isFresh, keyboardVisible else { check.key.cancelPress(); cursorCheck = nil; return }
            let elapsed = now - check.started
            if check.phase == 0, elapsed >= 0.5 {
                check.key.advancePress(to: now)
                let accepted = check.key.movePress(to: CGPoint(x: check.point.x - 16, y: check.point.y), at: now)
                cursorCheckEvents.append(accepted ? "firstMoveAccepted" : "firstMoveRejected")
                check.phase = 1
            } else if check.phase == 1, elapsed >= 4.5 {
                check.held = check.key.isPressed && cursorKey === check.key && cursorDrag != nil
                _ = check.key.movePress(to: CGPoint(x: check.point.x - 24, y: check.point.y), at: now)
                check.phase = 2
            } else if check.phase == 2, elapsed >= 5.5 {
                check.key.releasePress()
                let result = CursorDeviceVerification.Result(id: check.request.id, heldAfterPause: check.held,
                    released: !check.key.isPressed && cursorDrag == nil, events: cursorCheckEvents,
                    customHapticPlayed: tapFeedback.verificationPlayedCustomFeedback,
                    hapticErrorCode: tapFeedback.verificationErrorCode)
                try? VoiceIPC.write(result, to: "cursor-check-result.json")
                cursorCheck = nil; return
            }
            cursorCheck = check
        } else if keyboardVisible, currentKey?.isPressed != true,
                  let request = VoiceIPC.read("cursor-check-request.json", as: CursorDeviceVerification.Request.self),
                  request.isFresh, Date().timeIntervalSince(request.createdAt) >= 2, request.id != lastCursorCheck,
                  textDocumentProxy.documentContextBeforeInput == request.fixture,
                  (textDocumentProxy.documentContextAfterInput ?? "").isEmpty,
                  let key = keys.first(where: { $0.value == "space" }), key.bounds.width > 0, key.bounds.height > 0 {
            lastCursorCheck = request.id
            cursorCheckEvents = []
            let point = CGPoint(x: key.bounds.midX, y: key.bounds.midY)
            guard key.press(at: now, point: point) else { return }
            cursorCheck = (request, key, point, now, 0, false)
        }
    }
    #endif
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
    let quietFeedback = QuietKeyFeedback()
    private var legendHidden = false
    var restingIcon: UIImage?
    var isPrimaryAction = false { didSet { if isPrimaryAction != oldValue { updateColors() } } }
    enum DictationFeedback { case cancel, send, translate, finish }
    var dictationFeedback: DictationFeedback? {
        didSet {
            updateColors()
            accessibilityValue = dictationFeedback == .cancel ? "Dictation cancelled" : dictationFeedback == .send ? "Send after polishing" : dictationFeedback == .translate ? "Release to translate" : dictationFeedback == .finish ? "Finish dictation; send from the app" : nil
        }
    }
    private func updateColors() {
        let restingFill = isPrimaryAction ? KeyboardMetrics.actionKeyFill : KeyboardMetrics.keyFill
        let restingInk = isPrimaryAction ? KeyboardMetrics.actionKeyInk : .label
        backgroundColor = dictationFeedback == .cancel ? .systemRed : dictationFeedback == .send || dictationFeedback == .finish ? .systemBlue : dictationFeedback == .translate ? .systemIndigo : restingFill
        // Preserve the action key's contrast while the surrounding keys meter voice.
        quietFeedback.setSuppressed(dictationFeedback != nil || isPrimaryAction)
        icon.tintColor = dictationFeedback == nil ? restingInk : .white
        label.textColor = dictationFeedback == nil ? restingInk : .white
    }
    var value = ""
    var allowsRolloverCommit: Bool { !isEditingSwipe && (value.count == 1 || value == "space" || value == "shift" || isDeleteKey) }
    var hasPendingChordTap: Bool { isPressed && allowsRolloverCommit && !gate.isHolding && !deleteGesture.isHolding }
    weak var touchSurface: KeyboardTouchSurface?
    var onPress: (() -> Bool)?
    var onPressFeedback: (() -> Void)?
    var onTap: (() -> Void)?
    var onHold: (() -> Void)?
    var onGapHold: (() -> Void)?
    var onPreviewChange: ((Bool) -> Void)?
    var onHoldMove: ((CGPoint) -> Bool)?
    var onEditSwipe: ((KeyboardEditSwipe) -> Void)?
    var onRelease: (() -> Void)?
    var onCancel: (() -> Void)?
    var onDeleteRepeat: (() -> Void)?
    var onDeleteHold: ((CGPoint) -> Void)?
    var onDeleteMove: ((CGPoint) -> Void)?
    var onDeleteEnd: ((Bool) -> Void)?
    var deleteClearTargetX: CGFloat?
    var onClearAll: (() -> Void)?
    var onSystemKeyboard: ((KeyControl, UIEvent) -> Void)?
    private var trackingEvent: UIEvent?
    private var systemKeyboardActive = false
    private(set) var systemKeyboardHoldReached = false
    func beginSystemKeyboardSelection() {
        guard !isGapPress, trackingEvent != nil, onSystemKeyboard != nil else { return }
        systemKeyboardHoldReached = true
    }
    var isDeleteKey = false
    private(set) var isPressed = false
    private(set) var isGapPress = false
    private(set) var isEditingSwipe = false
    private var pressedAt: TimeInterval = 0
    private var usesDeleteGesture: Bool { isDeleteKey && !(isGapPress && onGapHold != nil) }
    private var holdAction: (() -> Void)? { isGapPress ? onGapHold ?? onHold : onHold }
    private var holdDelay: TimeInterval { value == "dictate" && !isGapPress ? KeyboardModePinch.pairingGrace : HoldGate.threshold }
    var labelOffset: CGFloat = 0 { didSet { labelCenterY?.constant = labelOffset } }
    private var labelCenterY: NSLayoutConstraint?
    private var gate = HoldGate()
    private var deleteGesture = DeleteGesture()
    private var pressOrigin = CGPoint.zero
    private(set) var pressPoint = CGPoint.zero
    private var pressGeneration = 0
    private var holdSuppressedByMovement = false
    private var timer: Timer?
    override init(frame: CGRect) {
        super.init(frame: frame)
        // Mini's wide Dictate key can receive both fingers of a pinch. The
        // parent mode recognizer consumes the pair before key tracking types.
        isMultipleTouchEnabled = true
        quietFeedback.frame = bounds; quietFeedback.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(quietFeedback)
        label.textAlignment = .center; label.isUserInteractionEnabled = false; icon.contentMode = .scaleAspectFit; icon.tintColor = .label
        // Long Return titles (search, emergency call, 发送…) shrink inside their
        // key instead of overflowing or wrapping; ordinary legends already fit.
        label.numberOfLines = 1; label.adjustsFontSizeToFitWidth = true; label.minimumScaleFactor = 0.5
        label.baselineAdjustment = .alignCenters
        for item in [label, icon] { item.translatesAutoresizingMaskIntoConstraints = false; addSubview(item) }
        let labelFits = label.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -4)
        labelFits.priority = UILayoutPriority(999); labelFits.isActive = true
        labelCenterY = label.centerYAnchor.constraint(equalTo: centerYAnchor)
        NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: centerXAnchor), labelCenterY!, icon.centerXAnchor.constraint(equalTo: centerXAnchor), icon.centerYAnchor.constraint(equalTo: centerYAnchor), icon.widthAnchor.constraint(equalToConstant: 25), icon.heightAnchor.constraint(equalToConstant: 24)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func setLegendHidden(_ hidden: Bool, animated: Bool = true) {
        guard legendHidden != hidden || !animated else { return }
        legendHidden = hidden
        if animated && window != nil && !UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: 0.12, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut]) {
                self.label.alpha = hidden ? 0 : 1
                if ["shift", "emoji"].contains(self.value) { self.icon.alpha = hidden ? 0 : 1 }
            }
        } else {
            label.layer.removeAllAnimations(); label.alpha = hidden ? 0 : 1
            if ["shift", "emoji"].contains(value) { icon.layer.removeAllAnimations(); icon.alpha = hidden ? 0 : 1 }
        }
    }
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard let touchSurface else { return super.point(inside: point, with: event) }
        return touchSurface.target(at: convert(point, to: touchSurface)) === self
    }
    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        trackingEvent = event; systemKeyboardActive = false; systemKeyboardHoldReached = false
        guard press(at: ProcessInfo.processInfo.systemUptime, point: touch.location(in: self)) else { return false }
        if !isGapPress, onSystemKeyboard != nil, let event {
            systemKeyboardActive = true
            onSystemKeyboard?(self, event)
        }
        guard usesDeleteGesture || holdAction != nil else { return true }
        let generation = pressGeneration
        timer = Timer.scheduledTimer(withTimeInterval: usesDeleteGesture ? 0.02 : holdDelay, repeats: usesDeleteGesture) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.pressGeneration == generation else { return }
                self.advancePress(to: ProcessInfo.processInfo.systemUptime)
            }
        }
        return true
    }
    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        if systemKeyboardActive, let event { onSystemKeyboard?(self, event); return true }
        return movePress(to: touch.location(in: self), at: ProcessInfo.processInfo.systemUptime)
    }
    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        defer { trackingEvent = nil; systemKeyboardActive = false }
        if systemKeyboardActive, let event { onSystemKeyboard?(self, event); releasePress(); return }
        if let touch { _ = movePress(to: touch.location(in: self), at: ProcessInfo.processInfo.systemUptime) }
        releasePress()
    }
    override func cancelTracking(with event: UIEvent?) {
        if systemKeyboardActive, let event { onSystemKeyboard?(self, event) }
        trackingEvent = nil; systemKeyboardActive = false; cancelPress()
    }
    @discardableResult func press(at time: TimeInterval, point: CGPoint) -> Bool {
        stopTimer()
        isEditingSwipe = false; holdSuppressedByMovement = false; pressedAt = time
        isGapPress = bounds.width > 0 && bounds.height > 0 && !bounds.contains(point)
        guard onPress?() != false else { return false }
        pressOrigin = point; pressPoint = point; alpha = 0.55; isPressed = true
        onPressFeedback?()
        if usesDeleteGesture { deleteGesture.press(at: time, point: point, clearTargetX: deleteClearTargetX) }
        else { gate.press(at: time - (HoldGate.threshold - holdDelay)) }
        onPreviewChange?(true)
        return true
    }
    func advancePress(to time: TimeInterval) {
        guard isPressed, !isEditingSwipe, !holdSuppressedByMovement else { return }
        if usesDeleteGesture {
            let wasHolding = deleteGesture.isHolding
            if deleteGesture.advance(to: time) == .delete {
                if !wasHolding { onDeleteHold?(pressOrigin) }
                onDeleteRepeat?()
            }
        } else if let holdAction, gate.advance(to: time) {
            onPreviewChange?(false)
            holdAction()
        }
    }
    @discardableResult func movePress(to point: CGPoint, at time: TimeInterval) -> Bool {
        guard isPressed else { return false }
        pressPoint = point
        if isEditingSwipe { return true }
        let delta = CGPoint(x: point.x - pressOrigin.x, y: point.y - pressOrigin.y)
        // A thumb may settle sideways while tapping an edge key. Movement can
        // disarm a pending hold without swallowing the eventual tap. Only a
        // deliberate swipe (or a large unsupported movement) consumes the tap.
        if !gate.isHolding, !deleteGesture.isHolding, !holdSuppressedByMovement,
           hypot(delta.x, delta.y) >= 14 {
            holdSuppressedByMovement = true; stopTimer()
        }
        if onEditSwipe != nil, !gate.isHolding, !deleteGesture.isHolding,
           time - pressedAt < HoldGate.threshold, KeyboardEditSwipe.begins(at: delta) {
            isEditingSwipe = true; stopTimer(); gate.cancel(); deleteGesture.cancel()
            alpha = 1; onPreviewChange?(false)
            return true
        }
        if usesDeleteGesture {
            if abs(point.y - pressOrigin.y) > 40 || point.x > bounds.maxX + 30 {
                cancelPress(); return false
            }
            let wasHolding = deleteGesture.isHolding
            let action = deleteGesture.move(to: point, at: time)
            if !wasHolding, deleteGesture.isHolding { onDeleteHold?(pressOrigin) }
            if deleteGesture.isHolding { onDeleteMove?(point) }
            if action == .clearAll {
                stopTimer(); onClearAll?()
            }
        } else if gate.isHolding, let onHoldMove {
            if !onHoldMove(point) { cancelPress(); return false }
        } else if !self.point(inside: point, with: nil), !bounds.insetBy(dx: -30, dy: -40).contains(point) {
            cancelPress(); return false
        }
        return true
    }
    func releasePress() {
        guard isPressed else { return }
        stopTimer(); alpha = 1; isPressed = false
        onPreviewChange?(false)
        if isEditingSwipe {
            isEditingSwipe = false
            let delta = CGPoint(x: pressPoint.x - pressOrigin.x, y: pressPoint.y - pressOrigin.y)
            if let action = KeyboardEditSwipe.action(for: delta) { onEditSwipe?(action) }
            else { onCancel?() }
            return
        }
        if usesDeleteGesture {
            onDeleteEnd?(true)
            if deleteGesture.release() == .delete { onTap?() }
            onRelease?()
        } else {
            let wasHolding = gate.isHolding
            if gate.release() {
                // A brief physical touch on Dictate may be the start of a mode pinch.
                // VoiceOver's explicit activation still uses onTap to start/finish.
                if value != "dictate" { onTap?() }
            } else if wasHolding { onRelease?() }
        }
    }
    private func stopTimer() { timer?.invalidate(); timer = nil; pressGeneration += 1 }
    func cancelPress() {
        trackingEvent = nil; systemKeyboardActive = false
        guard isPressed else { return }
        onPreviewChange?(false)
        onDeleteEnd?(false)
        stopTimer(); alpha = 1; isPressed = false; isEditingSwipe = false; gate.cancel(); deleteGesture.cancel(); onCancel?()
    }
    override func accessibilityActivate() -> Bool { onPressFeedback?(); onTap?(); return true }
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
