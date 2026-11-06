//
//  MenuBarManager.swift
//  VibeRemote
//
//  Manages the menu bar icon and button mapping menu.
//

import AppKit

enum RemoteStatusBadge: Equatable, Sendable {
    case none, starting, disconnected

    init(remoteConnected: Bool, bridgeRunning: Bool) {
        self = !remoteConnected ? .disconnected : (bridgeRunning ? .none : .starting)
    }
}

/// Compact battery visualization used by the menu's device summary. Drawing the percentage
/// and progress in one view keeps their alignment stable at every menu width and appearance.
@MainActor
final class RemoteBatteryRingView: NSView {
    private let percent: Int?

    init(percent: Int?) {
        self.percent = percent.map { min(100, max(0, $0)) }
        super.init(frame: NSRect(x: 0, y: 0, width: 34, height: 34))
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel("Remote battery")
        setAccessibilityValue(self.percent.map { "\($0)%" } ?? "Unknown")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { NSSize(width: 34, height: 34) }

    /// The charge arc, in this unflipped view's y-up user space, where angles grow
    /// counterclockwise from the positive x-axis. Empty reads as the top of the ring and
    /// the arc grows clockwise from there, which is why the end angle *decreases* and the
    /// stroke passes `clockwise: true`.
    nonisolated static func progressArc(percent: Int) -> (start: CGFloat, end: CGFloat) {
        let fraction = CGFloat(min(100, max(0, percent))) / 100
        let top = CGFloat.pi / 2
        return (top, top - .pi * 2 * fraction)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius: CGFloat = 13
        let lineWidth: CGFloat = 3
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setStrokeColor(NSColor.quaternaryLabelColor.cgColor)
        context.addArc(
            center: center,
            radius: radius,
            startAngle: 0,
            endAngle: .pi * 2,
            clockwise: false
        )
        context.strokePath()

        if let percent, percent > 0 {
            let sweep = RemoteBatteryRingView.progressArc(percent: percent)
            context.setStrokeColor(NSColor.systemGreen.cgColor)
            context.addArc(
                center: center,
                radius: radius,
                startAngle: sweep.start,
                endAngle: sweep.end,
                clockwise: true
            )
            context.strokePath()
        }

        let text = percent.map(String.init) ?? "—"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(
            at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
            withAttributes: attributes
        )
    }
}

enum ButtonAction: String, CaseIterable, Sendable {
    case enterKey = "Enter: Submit prompt"
    case shiftEnter = "Shift + Enter: Newline"
    case backspace = "Backspace: Delete Word"
    case upKey = "Up: Navigate Up"
    case downKey = "Down: Navigate Down"
    case leftKey = "Left: Navigate Left"
    case rightKey = "Right: Navigate Right"
    case escKey = "Esc: Navigate Back"
    case ctrlC = "Control + C: Cancel Prompt"
    case spaceKey = "Space: Voice Dictation"
    case rightCmd = "Right Command: 3rd-party Voice Dictation"
    case rightOpt = "Right Option: 3rd-party Voice Dictation"
    case launchAgentClient = "Toggle Codex / Claude Desktop"
    case bulletIndent = "Bullet: New / Indent"
    case bulletOutdent = "Bullet: Outdent / Remove"
    // Keep the persisted raw value stable for existing Siri-button assignments.
    case slashOrModifier = "Slash: Skill Picker / Hold: Modifier"
    /// 1st-gen stand-in for the mute button's modifier half (the remote has no mute key).
    case shiftEnterOrModifier = "Shift + Enter: Newline / Hold: Modifier"
    /// 1st-gen stand-in for the mute button's "/" half.
    case agentClientOrSlash = "Toggle Codex / Claude Desktop / Hold: Slash"
    case none = "None"
    case advancedMenu = "Advanced Menu"
    case positionCaret = "Position text cursor"
    case skillPicker = "Skill Picker"

    var requiresHold: Bool {
        switch self {
        case .spaceKey, .rightCmd, .rightOpt:
            return true
        default:
            return false
        }
    }

    /// Composite actions exist to fold two roles onto one physical key on a remote that is
    /// short of keys. They are assigned by the generation profile, never chosen by hand.
    var isAssignableToSiriButton: Bool {
        switch self {
        case .shiftEnterOrModifier, .agentClientOrSlash, .advancedMenu, .positionCaret, .skillPicker:
            return false
        default:
            return true
        }
    }

    var actionDescription: String {
        switch self {
        case .slashOrModifier:
            return "Skill Picker: $ in ChatGPT / Codex, / in Claude; Hold: Modifier"
        case .bulletIndent:
            return "Create a bullet list, or indent the current item"
        case .bulletOutdent:
            return "Outdent, or remove the current list item"
        default: return rawValue
        }
    }
}

/// Single source of truth for the fixed button-to-action mapping and hold support.
/// Mappings are hardcoded and no longer user-customizable; this stays the one place
/// that defines them and lets SwiftPM tests verify key uniqueness and hold validity.
struct RemoteButtonDescriptor: Equatable, Sendable {
    let key: String
    let label: String
    let defaultAction: ButtonAction
    let supportsHold: Bool
}

// Fixed remote mappings; only Siri is customizable.
// - Clickpad Up/Down/Left/Right → arrow keys; center press → Enter
// - Volume Up/Down  → bullet-list control in AI prompt editors (new/indent, outdent/remove)
// - Back / Menu     → word-wise Backspace (Option+Delete; the system tokenizer segments
//                     Chinese, so 我爱北京天安门 deletes 天安门, then 北京, …)
// - TV              → Shift+Enter (newline; the convention most agent apps use);
//                     held 0.5 s it opens the computer-use agent panel instead
// - Play/Pause      → toggle the Codex / Claude desktop client to the front
// - Power           → Enter
// - Mute            → tap opens the focused app's skill picker ($ in Codex, / otherwise);
//                     held it becomes a modifier:
//                     Mute+Back clears all input, Mute+Play/Pause sends Esc
// - Siri            → Space (held; drives voice dictation and the mic bridge)
let remoteButtonDescriptors: [RemoteButtonDescriptor] = [
    RemoteButtonDescriptor(key: "menu", label: "Menu Button", defaultAction: .backspace, supportsHold: false),
    RemoteButtonDescriptor(key: "back", label: "Back Button", defaultAction: .backspace, supportsHold: false),
    RemoteButtonDescriptor(key: "tv", label: "TV Button", defaultAction: .shiftEnter, supportsHold: false),
    RemoteButtonDescriptor(key: "siri", label: "Siri Button", defaultAction: .spaceKey, supportsHold: true),
    RemoteButtonDescriptor(key: "playPause", label: "Play/Pause Button", defaultAction: .launchAgentClient, supportsHold: false),
    RemoteButtonDescriptor(key: "select", label: "Clickpad Center", defaultAction: .positionCaret, supportsHold: false),
    RemoteButtonDescriptor(key: "navUp", label: "Clickpad Up", defaultAction: .upKey, supportsHold: false),
    RemoteButtonDescriptor(key: "navDown", label: "Clickpad Down", defaultAction: .downKey, supportsHold: false),
    RemoteButtonDescriptor(key: "navLeft", label: "Clickpad Left", defaultAction: .leftKey, supportsHold: false),
    RemoteButtonDescriptor(key: "navRight", label: "Clickpad Right", defaultAction: .rightKey, supportsHold: false),
    RemoteButtonDescriptor(key: "volumeUp", label: "Volume Up", defaultAction: .bulletIndent, supportsHold: false),
    RemoteButtonDescriptor(key: "volumeDown", label: "Volume Down", defaultAction: .bulletOutdent, supportsHold: false),
    RemoteButtonDescriptor(key: "mute", label: "Mute Button", defaultAction: .slashOrModifier, supportsHold: false),
    RemoteButtonDescriptor(key: "power", label: "Power Button", defaultAction: .enterKey, supportsHold: false),
    RemoteButtonDescriptor(key: "nextTrack", label: "Next Track", defaultAction: .rightKey, supportsHold: false),
    RemoteButtonDescriptor(key: "prevTrack", label: "Previous Track", defaultAction: .leftKey, supportsHold: false),
]

enum RemoteInputState: Equatable, Sendable {
    case permissionRequired
    case starting
    case waitingForRemote
    case ready
    case unavailable

    var menuTitle: String {
        switch self {
        case .permissionRequired: return "Input: Permission Required..."
        case .starting: return "Input: Starting..."
        case .waitingForRemote: return "Input: Waiting for Remote"
        case .ready: return "Input: Ready"
        case .unavailable: return "Input: Unavailable"
        }
    }
}

enum RemoteControlState: Equatable, Sendable {
    case permissionRequired
    case starting
    case ready

    var menuTitle: String {
        switch self {
        case .permissionRequired: return "Control: Permission Required..."
        case .starting: return "Control: Checking Permission..."
        case .ready: return "Control: Ready"
        }
    }
}

@MainActor
final class MenuBarManager: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu: NSMenu
    private var settingsWindowController: SettingsWindowController?
    private var onboardingWindowController: OnboardingWindowController?
    private let microphoneBridgeManager: MicrophoneBridgeManager
    private let remoteBatteryReader = RemoteBatteryReader()
    private static let siriButtonKey = "siri"
    private static let siriButtonDefaultsKey = "siriButtonAction"
    private static let siriButtonDefaultAction: ButtonAction =
        remoteButtonDescriptors.first { $0.key == siriButtonKey }?.defaultAction ?? .spaceKey
    /// Siri is the only customizable physical button.
    private var siriButtonAction: ButtonAction = MenuBarManager.loadSiriButtonAction()
    var touchStatus = "Waiting for a remote touch surface"
    private var remoteConnected = false
    private var remoteGeneration: RemoteGeneration = .unknown
    /// The remote's own Bluetooth name, shown under the connection state. nil falls back to
    /// the hardware family, which is all we know before any interface opens.
    private var remoteName: String?
    private var bluetoothAccessState: BluetoothAccessState = .notDetermined
    private var remoteInputState: RemoteInputState = .permissionRequired
    private var remoteControlState: RemoteControlState = .permissionRequired
    private var requestBluetoothAccessHandler: (() -> Void)?
    private var requestInputAccessHandler: (() -> Void)?
    private var requestControlAccessHandler: (() -> Void)?
    private var statusRefreshHandler: (() -> Void)?
    private var agentPanelHandler: (() -> Void)?
    private var remoteIdleTimeoutHandler: ((RemoteIdleTimeout) -> Void)?
    private var remoteIdleTimeout = RemoteIdleTimeout.load()
    private var remoteBatteryPercent: Int?
    private var batteryRefreshInFlight = false
    private var lastBatteryRefreshAt: Date?
    private let batteryRefreshInterval: TimeInterval = 300
    private var cachedDiagnostics: MicrophoneBridgeDiagnostics?
    private var diagnosticsRefreshInFlight = false
    private var pendingDiagnosticsCallbacks: [(MicrophoneBridgeDiagnostics) -> Void] = []
    private let diagnosticsCacheInterval: TimeInterval = 30

    init(statusItem: NSStatusItem, microphoneBridgeManager: MicrophoneBridgeManager) {
        self.statusItem = statusItem
        self.microphoneBridgeManager = microphoneBridgeManager
        self.menu = NSMenu()
        super.init()

        menu.delegate = self
        setupMenuBar()
    }

    /// The menu-bar glyph: the Apple TV remote SF Symbol, with a status badge notched into
    /// the bottom-right corner (slash for disconnected, refresh for bridge startup). Falls
    /// back to a hand-drawn remote if the symbol is unavailable (older macOS). The image
    /// stays a template so macOS keeps tinting it for light/dark menu bars.
    static func makeRemoteIcon(badge: RemoteStatusBadge = .none) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        guard let symbol = NSImage(systemSymbolName: "appletvremote.gen4", accessibilityDescription: "VibeRemote")?
            .withSymbolConfiguration(config) else {
            return makeFallbackRemoteIcon(badge: badge)
        }
        guard badge != .none else {
            symbol.isTemplate = true
            return symbol
        }
        let size = symbol.size
        let badged = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            symbol.draw(in: rect)
            // The symbol bitmap is a tight canvas: anything past its edges is clipped, so
            // the disc must sit tangent to the corner, never overhang it.
            let r = size.width * 0.34
            let cx = size.width - r
            let cy = r

            // Notch a transparent moat so the badge reads as a separate element.
            ctx.setBlendMode(.clear)
            ctx.fillEllipse(in: CGRect(x: cx - r * 1.2, y: cy - r * 1.2, width: r * 2.4, height: r * 2.4))

            ctx.setBlendMode(.normal)
            drawStatusBadge(badge, in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
            return true
        }
        badged.isTemplate = true
        return badged
    }

    /// Hand-drawn remote used only when the SF Symbol is unavailable.
    private static func makeFallbackRemoteIcon(badge: RemoteStatusBadge = .none) -> NSImage {
        let pt: CGFloat = 18
        let image = NSImage(size: NSSize(width: pt, height: pt), flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let s = rect.width
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))

            let body = CGRect(x: 0.34 * s, y: 0.12 * s, width: 0.32 * s, height: 0.76 * s)
            let ring = CGRect(x: 0.39 * s, y: 0.18 * s, width: 0.22 * s, height: 0.22 * s)
            let siri = CGRect(x: 0.69 * s, y: 0.36 * s, width: 0.08 * s, height: 0.18 * s)

            let path = CGMutablePath()
            path.addPath(CGPath(roundedRect: body, cornerWidth: 0.12 * s, cornerHeight: 0.12 * s, transform: nil))
            path.addEllipse(in: ring)
            path.addPath(CGPath(roundedRect: siri, cornerWidth: 0.04 * s, cornerHeight: 0.04 * s, transform: nil))
            ctx.addPath(path)
            ctx.fillPath()

            if badge != .none {
                let cx = 0.72 * s
                let cy = 0.74 * s
                let badgeR = 0.23 * s
                let moatR = badgeR + 0.05 * s

                // Notch a transparent moat so the badge reads as a separate element even
                // where it overlaps the remote body.
                ctx.setBlendMode(.clear)
                ctx.fillEllipse(in: CGRect(x: cx - moatR, y: cy - moatR, width: 2 * moatR, height: 2 * moatR))

                ctx.setBlendMode(.normal)
                drawStatusBadge(
                    badge,
                    in: CGRect(x: cx - badgeR, y: cy - badgeR, width: 2 * badgeR, height: 2 * badgeR)
                )
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    static let disconnectedBadgeImage: NSImage? = {
        // alignmentRect describes typographic alignment, not visible artwork: for this
        // symbol it is 18 x 10.5 inside an 18 x 17 canvas. Drawing that rect into a square
        // stretches the badge at menu-bar size. Rasterize once at 4x, trim only transparent
        // pixels, and retain the artwork's aspect ratio at every destination scale.
        let config = NSImage.SymbolConfiguration(pointSize: 60, weight: .regular)
        guard let slash = NSImage(systemSymbolName: "slash.circle.fill", accessibilityDescription: "Remote disconnected")?
            .withSymbolConfiguration(config),
              let cgImage = slash.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        var minX = bitmap.pixelsWide, minY = bitmap.pixelsHigh
        var maxX = -1, maxY = -1
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0 {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY,
              let trimmed = cgImage.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)) else { return nil }
        return NSImage(cgImage: trimmed, size: NSSize(width: trimmed.width, height: trimmed.height))
    }()

    static let startingBadgeImage: NSImage? = {
        let config = NSImage.SymbolConfiguration(pointSize: 60, weight: .regular)
        return NSImage(systemSymbolName: "arrow.clockwise.circle.fill", accessibilityDescription: "Bridge starting")?
            .withSymbolConfiguration(config)
    }()

    static func drawStatusBadge(_ badge: RemoteStatusBadge, in rect: CGRect) {
        let image: NSImage?
        switch badge {
        case .none: return
        case .starting: image = startingBadgeImage
        case .disconnected: image = disconnectedBadgeImage
        }
        guard let image else { return }
        let scale = min(rect.width / image.size.width, rect.height / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let destination = NSRect(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        image.draw(
            in: destination,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high.rawValue]
        )
    }

    static func drawDisconnectedBadge(in rect: CGRect) {
        guard let slash = disconnectedBadgeImage else { return }
        let scale = min(rect.width / slash.size.width, rect.height / slash.size.height)
        let size = NSSize(width: slash.size.width * scale, height: slash.size.height * scale)
        let destination = NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
        slash.draw(in: destination, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
    }

    private func setupMenuBar() {
        guard let button = statusItem.button else { return }
        button.image = Self.makeRemoteIcon()
        button.title = ""

        rebuildMenu()
        statusItem.menu = menu
        setupApplicationMenu()
    }

    /// An accessory app still needs the standard keyboard menu while its settings
    /// window is key (Cmd-comma, Cmd-W, Hide and Quit).
    private func setupApplicationMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "VibeRemote")
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(AppUpdater.shared.makeMenuItem())
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide VibeRemote", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit VibeRemote", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        appMenu.addItem(quit)
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        // Native field-editor shortcuts are essential for the command input (including dictation edits).
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        for (title, selector, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"),
                                       ("Copy", "copy:", "c"), ("Paste", "paste:", "v"),
                                       ("Select All", "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: Selector(selector), keyEquivalent: key)
        }
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)
        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    private var settingsSnapshot: RemoteSettingsSnapshot {
        RemoteSettingsSnapshot(
            connected: remoteConnected,
            batteryPercent: remoteBatteryPercent,
            siriAction: siriButtonAction,
            generation: remoteGeneration,
            idleTimeout: remoteIdleTimeout
        )
    }



    private var onboardingAccess: OnboardingAccess {
        let helperState = PrivilegedHelperClient.shared.state
        return OnboardingAccess(bluetooth: bluetoothAccessState == .allowed,
                                input: inputAccessIsReady, accessibility: remoteControlState == .ready,
                                helper: !helperState.needsUserAction,
                                helperNeedsApproval: helperState == .awaitingApproval,
                                audio: microphoneBridgeManager.menuStatus().outputDeviceName != nil,
                                audioInstallable: microphoneBridgeManager.bundledAudioDriverAvailable)
    }

    func showOnboardingIfNeeded() {
        if OnboardingState.needsPresentation() { showOnboarding() }
    }

    func showOnboarding() {
        statusRefreshHandler?()
        // A new guide starts from the current choice without changing it until Finish.
        if onboardingWindowController?.window?.isVisible != true && onboardingWindowController?.window?.isMiniaturized != true {
            onboardingWindowController = OnboardingWindowController(
                snapshot: settingsSnapshot, access: onboardingAccess,
                actions: OnboardingActions(
                    requestBluetooth: { [weak self] in self?.requestBluetoothAccessHandler?() },
                    requestInput: { [weak self] in self?.requestInputAccessHandler?() },
                    requestAccessibility: { [weak self] in self?.requestControlAccessHandler?() },
                    setUpHelper: { [weak self] in
                        guard let self else { return }
                        if PrivilegedHelperClient.shared.state == .awaitingApproval { self.openHelperSettings() }
                        else { self.registerPrivilegedHelper() }
                    },
                    installAudio: { [weak self] in self?.installAudioDriver() }),
                finish: { [weak self] action in self?.setSiriButtonAction(action) })
        }
        onboardingWindowController?.show()
    }

    @objc func restartOnboarding() {
        rmDebug("🧭 Onboarding restart requested")
        showOnboarding()
        onboardingWindowController?.update(snapshot: settingsSnapshot, access: onboardingAccess)
        onboardingWindowController?.restart()
    }

    @objc func showSettings() {
        rmDebug("⚙️ Settings window requested")
        statusRefreshHandler?()
        refreshRemoteBattery()
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(
                snapshot: settingsSnapshot,
                setSiriAction: { [weak self] action in self?.setSiriButtonAction(action) },
                resetSiriAction: { [weak self] in
                    self?.setRemoteIdleTimeout(.defaultValue)
                    self?.setSiriButtonAction(Self.siriButtonDefaultAction)
                },
                setIdleTimeout: { [weak self] timeout in self?.setRemoteIdleTimeout(timeout) },
                actions: SettingsActions(
                    installAudioDriver: { [weak self] in self?.installAudioDriver() },
                    restartBridge: { [weak self] in self?.startMicrophoneBridge() },
                    copyDiagnostics: { [weak self] in self?.copyDiagnostics() },
                    openAppLog: { [weak self] in self?.openAppLog() },
                    refreshDiagnostics: { [weak self] in self?.requestDiagnostics(force: true) },
                    showOnboarding: { [weak self] in self?.showOnboarding() },
                    openAgentPanel: { [weak self] in self?.agentPanelHandler?() }
                )
            )
        }
        settingsWindowController?.update(settingsSnapshot)
        publishDiagnostics(cachedDiagnostics)
        onboardingWindowController?.update(snapshot: settingsSnapshot, access: onboardingAccess)
        settingsWindowController?.show()
    }

    /// Badges the menu-bar glyph whenever the remote is disconnected or its always-on bridge
    /// is still starting. There is no user-facing stopped state.
    private func updateStatusIcon(microphoneStatus: MicrophoneBridgeStatus) {
        let badge = RemoteStatusBadge(remoteConnected: remoteConnected, bridgeRunning: microphoneStatus.running)
        statusItem.button?.image = Self.makeRemoteIcon(badge: badge)
    }

    /// A double-height banner row: an SF Symbol glyph, a bold label, and an optional
    /// trailing action button. Used for both the stopped-bridge and disconnected-remote
    /// notices so they share one look.
    private func makeBanner(
        symbolName: String,
        text: String,
        buttonTitle: String? = nil,
        buttonAction: Selector? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem()
        let rowHeight: CGFloat = 44
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: rowHeight))
        container.autoresizingMask = [.width]

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        icon.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: text)?
            .withSymbolConfiguration(symbolConfig)
        icon.contentTintColor = .systemOrange

        let label = NSTextField(labelWithString: text)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .labelColor

        container.addSubview(icon)
        container.addSubview(label)

        var constraints = [
            icon.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            icon.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ]

        if let buttonTitle, let buttonAction {
            let button = NSButton(title: buttonTitle, target: self, action: buttonAction)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.bezelStyle = .rounded
            button.controlSize = .regular
            container.addSubview(button)
            constraints += [
                button.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
                button.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                button.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 12),
            ]
        } else {
            constraints.append(
                label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -14)
            )
        }

        NSLayoutConstraint.activate(constraints)
        item.view = container
        return item
    }

    /// The first menu row is the complete remote summary. It replaces the former three text
    /// rows for Bluetooth, model and battery so the same state is never repeated below it.
    /// Half the padding this row used to carry, at the user's request (2026-11-06). The row
    /// height is measured from the labels rather than hardcoded, so the space above and below
    /// stays equal to this whatever the text metrics do.
    private static let statusRowPadding: CGFloat = 6.5
    private static let batteryGaugeDiameter: CGFloat = 34

    private func makeDeviceStatusItem(microphoneStatus: MicrophoneBridgeStatus) -> NSMenuItem {
        let item = NSMenuItem()
        let padding = Self.statusRowPadding

        let statusTitle: String
        if !remoteConnected {
            statusTitle = "Disconnected"
        } else {
            statusTitle = microphoneStatus.running ? "Connected" : "Starting"
        }
        let title = NSTextField(labelWithString: statusTitle)
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.textColor = .labelColor

        var generation: NSTextField?
        var battery: RemoteBatteryRingView?
        let rowHeight: CGFloat
        if remoteConnected {
            let fallbackText: String
            switch remoteGeneration {
            case .glassTouchSurface: fallbackText = "1st Generation"
            case .aluminumClickpad: fallbackText = "2nd / 3rd Generation"
            case .unknown: fallbackText = "Generation Unknown"
            }
            let subtitle = NSTextField(labelWithString: remoteName ?? fallbackText)
            subtitle.translatesAutoresizingMaskIntoConstraints = false
            subtitle.font = .systemFont(ofSize: 11.5)
            subtitle.textColor = .secondaryLabelColor

            let gauge = RemoteBatteryRingView(percent: remoteBatteryPercent)
            gauge.translatesAutoresizingMaskIntoConstraints = false
            generation = subtitle
            battery = gauge
            // The gauge is centered, so it needs the same breathing room as the text stack.
            rowHeight = max(
                padding * 2 + ceil(title.fittingSize.height) + 2 + ceil(subtitle.fittingSize.height),
                padding * 2 + Self.batteryGaugeDiameter
            )
        } else {
            rowHeight = padding * 2 + ceil(title.fittingSize.height)
        }

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: rowHeight))
        container.autoresizingMask = [.width]
        container.addSubview(title)

        if let generation, let battery {
            container.addSubview(generation)
            container.addSubview(battery)

            NSLayoutConstraint.activate([
                title.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
                title.topAnchor.constraint(equalTo: container.topAnchor, constant: padding),
                generation.leadingAnchor.constraint(equalTo: title.leadingAnchor),
                generation.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
                generation.trailingAnchor.constraint(lessThanOrEqualTo: battery.leadingAnchor, constant: -12),
                battery.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
                battery.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                battery.widthAnchor.constraint(equalToConstant: Self.batteryGaugeDiameter),
                battery.heightAnchor.constraint(equalToConstant: Self.batteryGaugeDiameter),
            ])
        } else {
            NSLayoutConstraint.activate([
                title.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
                title.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                title.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -14),
            ])
        }

        item.view = container
        return item
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        settingsWindowController?.update(settingsSnapshot)
        publishDiagnostics(cachedDiagnostics)
        onboardingWindowController?.update(snapshot: settingsSnapshot, access: onboardingAccess)

        let microphoneStatus = microphoneBridgeManager.menuStatus()
        menu.addItem(makeDeviceStatusItem(microphoneStatus: microphoneStatus))
        menu.addItem(.separator())

        // Settings must remain reachable before pairing and while the remote sleeps.
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(AppUpdater.shared.makeMenuItem())
        // Also reachable by holding TV; the menu item works without a remote.
        let agentItem = NSMenuItem(title: "Computer Use Agent", action: #selector(toggleAgentPanel), keyEquivalent: "")
        agentItem.target = self
        menu.addItem(agentItem)
        // The guide starts with pairing, so it stays reachable while disconnected too.
        let onboardingItem = NSMenuItem(title: "Restart Onboarding", action: #selector(restartOnboarding), keyEquivalent: "")
        onboardingItem.target = self
        menu.addItem(onboardingItem)
        menu.addItem(.separator())
        updateStatusIcon(microphoneStatus: microphoneStatus)

        // Permissions appear only while something still needs granting, pinned to the top.
        // A missing permission is the real reason the remote won't connect, so it takes
        // precedence over the disconnected notice below.
        let bluetoothNeeded = bluetoothAccessState != .allowed
        // .unavailable means the HID manager failed to open for a non-permission reason;
        // there is nothing to grant, so it gets its own retry banner instead of being
        // counted here.
        let inputPermissionNeeded = !inputAccessIsReady && remoteInputState != .unavailable
        let missingPermissionCount = (inputPermissionNeeded ? 1 : 0)
            + (remoteControlState == .ready ? 0 : 1)
            + (bluetoothNeeded ? 1 : 0)
        if missingPermissionCount > 0 {
            let permissionsItem = NSMenuItem(
                title: "Permissions Required (\(missingPermissionCount))...",
                action: nil,
                keyEquivalent: ""
            )
            permissionsItem.submenu = buildPermissionsMenu(
                includeBluetooth: bluetoothNeeded,
                onlyRequired: true
            )
            menu.addItem(permissionsItem)
            menu.addItem(NSMenuItem.separator())
        }

        // The HID-failure banner also stays above the disconnected guard: detection is
        // independent of the remote's connection, and retrying it must remain reachable
        // while the remote is offline.
        if remoteInputState == .unavailable {
            menu.addItem(makeBanner(
                symbolName: "exclamationmark.triangle.fill",
                text: "Button input unavailable",
                buttonTitle: "Retry",
                buttonAction: #selector(retryInputDetection)
            ))
            menu.addItem(NSMenuItem.separator())
        }

        // Keep the disconnected menu short. The settings window remains available above.
        guard remoteConnected else {
            let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
            quitItem.target = self
            menu.addItem(quitItem)
            return
        }

        // A prominent double-height banner pinned to the top when the bridge cannot run.
        // The helper comes first: approving it once removes the password prompts that the
        // remaining setup steps would otherwise raise.
        let helperState = PrivilegedHelperClient.shared.state
        if helperState.needsUserAction {
            menu.addItem(makeBanner(
                symbolName: "lock.shield.fill",
                text: helperState == .awaitingApproval ? "Approve VibeRemote Helper" : "One-time setup required",
                buttonTitle: helperState == .awaitingApproval ? "Open Settings" : "Set Up",
                buttonAction: helperState == .awaitingApproval
                    ? #selector(openHelperSettings)
                    : #selector(registerPrivilegedHelper)
            ))
            menu.addItem(NSMenuItem.separator())
        }

        // Setting up the audio device comes next: the bridge needs it to play into.
        if microphoneStatus.outputDeviceName == nil {
            menu.addItem(makeBanner(
                symbolName: "speaker.badge.exclamationmark.fill",
                text: "Audio setup required",
                buttonTitle: microphoneBridgeManager.bundledAudioDriverAvailable ? "Install" : nil,
                buttonAction: microphoneBridgeManager.bundledAudioDriverAvailable
                    ? #selector(installAudioDriver)
                    : nil
            ))
            menu.addItem(NSMenuItem.separator())
        }

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private var inputAccessIsReady: Bool {
        remoteInputState == .ready || remoteInputState == .waitingForRemote
    }

    private func buildPermissionsMenu(includeBluetooth: Bool, onlyRequired: Bool) -> NSMenu {
        let submenu = NSMenu()

        if includeBluetooth {
            switch bluetoothAccessState {
            case .allowed:
                if !onlyRequired {
                    addInfoItem("Bluetooth Audio: Ready", to: submenu)
                }
            case .notDetermined:
                addActionItem("Allow Bluetooth Audio...", action: #selector(requestBluetoothAccess), to: submenu)
            case .denied:
                addActionItem("Bluetooth Audio: Open Settings...", action: #selector(requestBluetoothAccess), to: submenu)
            case .restricted:
                addInfoItem("Bluetooth Audio: Restricted", to: submenu)
            }
        }

        if inputAccessIsReady {
            if !onlyRequired {
                addInfoItem("Button Input: Ready", to: submenu)
            }
        } else {
            switch remoteInputState {
            case .starting:
                addInfoItem("Button Input: Checking...", to: submenu)
            case .unavailable:
                // Not a grantable permission; the top-level retry banner owns this state.
                if !onlyRequired {
                    addInfoItem("Button Input: Unavailable", to: submenu)
                }
            case .permissionRequired:
                addActionItem("Allow Button Input...", action: #selector(requestInputAccess), to: submenu)
            case .waitingForRemote, .ready:
                break
            }
        }

        if remoteControlState == .ready {
            if !onlyRequired {
                addInfoItem("Keyboard Control: Ready", to: submenu)
            }
        } else if remoteControlState == .starting {
            addInfoItem("Keyboard Control: Checking...", to: submenu)
        } else {
            addActionItem("Allow Keyboard Control...", action: #selector(requestControlAccess), to: submenu)
        }

        return submenu
    }

    /// Settings' Microphone and Diagnostics panes. The at-a-glance status (Bluetooth /
    /// Battery / Bridge) lives in the top-level menu; detail fields fill in once the async
    /// diagnostics snapshot arrives, and Copy Diagnostics exports the full report.
    private func publishDiagnostics(_ diagnostics: MicrophoneBridgeDiagnostics?) {
        guard let settingsWindowController else { return }
        let microphoneStatus = microphoneBridgeManager.menuStatus()
        var state = SettingsDiagnostics()
        state.attention = microphoneStatus.lastError
        switch PrivilegedHelperClient.shared.state {
        case .ready: state.helper = "Approved"
        case .awaitingApproval: state.helper = "Waiting for approval"
        case .notRegistered: state.helper = "Not set up"
        case .unsupported: state.helper = "Unavailable (needs macOS 13+)"
        }
        state.bridgeRunning = microphoneStatus.running
        state.canInstallDriver = microphoneStatus.outputDeviceName != "VibeRemote"
            && microphoneBridgeManager.bundledAudioDriverAvailable
        if let diagnostics {
            state.report = SettingsDiagnostics.Report(
                remoteAddress: diagnostics.remoteAddress,
                outputDevice: diagnostics.outputDeviceName,
                defaultInput: diagnostics.defaultInputDeviceName,
                voiceSessions: "\(diagnostics.helperVoiceStartedCount) started, \(diagnostics.helperVoiceEndedCount) ended",
                blockingIssues: Array(diagnostics.blockingIssues.prefix(4)),
                appLogAvailable: diagnostics.appLogAge != "missing")
        }
        settingsWindowController.update(diagnostics: state)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        rebuildMenu()
    }

    private func requestDiagnostics(
        force: Bool,
        completion: ((MicrophoneBridgeDiagnostics) -> Void)? = nil
    ) {
        let cacheIsFresh = cachedDiagnostics.map {
            Date().timeIntervalSince($0.generatedAt) < diagnosticsCacheInterval
        } ?? false
        if !force, cacheIsFresh, let cachedDiagnostics {
            completion?(cachedDiagnostics)
            return
        }

        if let completion {
            pendingDiagnosticsCallbacks.append(completion)
        }
        guard !diagnosticsRefreshInFlight else { return }

        diagnosticsRefreshInFlight = true

        microphoneBridgeManager.diagnosticsAsync { [weak self] diagnostics in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.cachedDiagnostics = diagnostics
                self.diagnosticsRefreshInFlight = false
                self.publishDiagnostics(diagnostics)
                let callbacks = self.pendingDiagnosticsCallbacks
                self.pendingDiagnosticsCallbacks.removeAll()
                callbacks.forEach { $0(diagnostics) }
            }
        }
    }

    /// A non-actionable information row shown in full label color rather than dimmed.
    /// A disabled NSMenuItem is greyed out by AppKit, so these rows carry a harmless
    /// no-op action instead, which keeps them legible while doing nothing when clicked.
    private func addInfoItem(_ title: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: #selector(noop), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    @objc private func noop() {}

    private func addActionItem(_ title: String, action: Selector, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }


    private func truncate(_ value: String, max: Int) -> String {
        guard value.count > max else { return value }
        let index = value.index(value.startIndex, offsetBy: max)
        return String(value[..<index]) + "..."
    }


    @objc private func startMicrophoneBridge() {
        cachedDiagnostics = nil
        if bluetoothAccessState != .allowed {
            requestBluetoothAccessHandler?()
        }
        microphoneBridgeManager.restartAsync { [weak self] in
            Task { @MainActor [weak self] in
                self?.rebuildMenu()
            }
        }
    }

    @objc private func registerPrivilegedHelper() {
        switch PrivilegedHelperClient.shared.register() {
        case .success(let state):
            rebuildMenu()
            if state == .awaitingApproval, #available(macOS 13.0, *) {
                // macOS shows the request in System Settings; take the user straight there.
                PrivilegedHelperClient.shared.openLoginItemsSettings()
            }
        case .failure(let error):
            rebuildMenu()
            let alert = NSAlert()
            alert.messageText = "Setup Failed"
            alert.informativeText = "VibeRemote could not register its helper: \(error.localizedDescription)"
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    @objc private func openHelperSettings() {
        guard #available(macOS 13.0, *) else { return }
        PrivilegedHelperClient.shared.openLoginItemsSettings()
    }

    @objc private func installAudioDriver() {
        cachedDiagnostics = nil
        microphoneBridgeManager.installAudioDriver { [weak self] succeeded, message in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.rebuildMenu()
                guard !succeeded, let message else { return }
                let alert = NSAlert()
                alert.messageText = "Audio Setup Failed"
                alert.informativeText = message
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }

    @objc private func refreshMenu() {
        cachedDiagnostics = nil
        statusRefreshHandler?()
        refreshRemoteBattery(force: true)
        rebuildMenu()
    }

    @objc private func copyDiagnostics() {
        requestDiagnostics(force: false) { diagnostics in
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(diagnostics.copyText, forType: .string)
        }
    }

    @objc private func openAppLog() {
        microphoneBridgeManager.openAppLog()
    }

    func refresh() {
        refreshRemoteBattery()
        rebuildMenu()
    }

    /// The bridge health timer calls this more frequently than the full menu refresh so the
    /// startup badge clears promptly without forcing battery work or rebuilding a closed menu.
    func refreshBridgeStatusIcon() {
        updateStatusIcon(microphoneStatus: microphoneBridgeManager.menuStatus())
    }

    func setBluetoothAccessRequestHandler(_ handler: @escaping () -> Void) {
        requestBluetoothAccessHandler = handler
    }

    func setInputAccessRequestHandler(_ handler: @escaping () -> Void) {
        requestInputAccessHandler = handler
    }

    func setControlAccessRequestHandler(_ handler: @escaping () -> Void) {
        requestControlAccessHandler = handler
    }

    func setStatusRefreshHandler(_ handler: @escaping () -> Void) {
        statusRefreshHandler = handler
    }

    func setAgentPanelHandler(_ handler: @escaping () -> Void) {
        agentPanelHandler = handler
    }

    @objc func toggleAgentPanel() {
        rmDebug("🤖 Agent panel requested from the menu")
        agentPanelHandler?()
    }

    func setRemoteIdleTimeoutHandler(
        _ handler: @escaping (RemoteIdleTimeout) -> Void
    ) {
        remoteIdleTimeoutHandler = handler
        handler(remoteIdleTimeout)
    }

    func updateBluetoothConnectionStatus(connected: Bool) {
        let wasConnected = remoteConnected
        remoteConnected = connected
        if !connected {
            remoteBatteryReader.cancel()
            remoteBatteryPercent = nil
            lastBatteryRefreshAt = nil
            batteryRefreshInFlight = false
        }
        rebuildMenu()
        if connected {
            refreshRemoteBattery(force: !wasConnected || remoteBatteryPercent == nil)
        }
    }

    func updateRemoteInputState(_ state: RemoteInputState) {
        guard remoteInputState != state else { return }
        remoteInputState = state
        rebuildMenu()
    }

    func updateRemoteControlState(_ state: RemoteControlState) {
        guard remoteControlState != state else { return }
        remoteControlState = state
        rebuildMenu()
    }

    func updateBluetoothAccessState(_ state: BluetoothAccessState) {
        guard bluetoothAccessState != state else { return }
        bluetoothAccessState = state
        if !state.allowsBatteryLookup {
            remoteBatteryReader.cancel()
            remoteBatteryPercent = nil
            lastBatteryRefreshAt = nil
            batteryRefreshInFlight = false
        }
        rebuildMenu()
        if state.allowsBatteryLookup, remoteConnected {
            refreshRemoteBattery(force: true)
        }
    }

    private func refreshRemoteBattery(force: Bool = false) {
        guard remoteConnected,
              bluetoothAccessState.allowsBatteryLookup,
              !batteryRefreshInFlight else { return }
        if !force,
           let lastBatteryRefreshAt,
           Date().timeIntervalSince(lastBatteryRefreshAt) < batteryRefreshInterval {
            return
        }

        batteryRefreshInFlight = true
        remoteBatteryReader.readBatteryPercent { [weak self] percent in
            guard let self = self else { return }
            self.batteryRefreshInFlight = false
            guard self.remoteConnected else {
                self.rebuildMenu()
                return
            }
            self.lastBatteryRefreshAt = Date()
            if let percent {
                self.remoteBatteryPercent = percent
            }
            self.rebuildMenu()
        }
    }

    /// `generation` is the remote that produced the press, not necessarily the one the menu
    /// shows: a 1st-gen and a 2nd/3rd-gen remote can be paired at the same time and each must
    /// keep its own profile.
    func getMapping(for button: String, generation: RemoteGeneration? = nil) -> ButtonAction {
        RemoteButtonMapping.action(button: button, generation: generation ?? remoteGeneration, siriAction: siriButtonAction)
    }



    func updateRemoteGeneration(_ generation: RemoteGeneration) {
        guard remoteGeneration != generation else { return }
        remoteGeneration = generation
        rebuildMenu()
    }

    func updateRemoteName(_ name: String?) {
        guard remoteName != name else { return }
        remoteName = name
        rebuildMenu()
    }

    private static func loadSiriButtonAction() -> ButtonAction {
        guard let raw = UserDefaults.standard.string(forKey: siriButtonDefaultsKey),
              let action = ButtonAction(rawValue: raw),
              // Profile-only composite actions are not valid user settings.
              action.isAssignableToSiriButton else {
            return siriButtonDefaultAction
        }
        return action
    }

    private func setSiriButtonAction(_ action: ButtonAction) {
        guard action.isAssignableToSiriButton else { return }
        siriButtonAction = action
        UserDefaults.standard.set(action.rawValue, forKey: Self.siriButtonDefaultsKey)
        rebuildMenu()
    }

    private func setRemoteIdleTimeout(_ timeout: RemoteIdleTimeout) {
        remoteIdleTimeout = timeout
        UserDefaults.standard.set(timeout.rawValue, forKey: RemoteIdleTimeout.defaultsKey)
        remoteIdleTimeoutHandler?(timeout)
        rebuildMenu()
    }

    @objc private func requestInputAccess() {
        requestInputAccessHandler?()
    }

    /// Retry after a HID open failure (.unavailable). Routes through the status refresh:
    /// the delegate re-checks Input Monitoring and re-arms detection (the failed start
    /// already cleared its started flag), so this never raises a permission prompt.
    @objc private func retryInputDetection() {
        remoteInputState = .starting
        statusRefreshHandler?()
        rebuildMenu()
    }

    @objc private func requestBluetoothAccess() {
        requestBluetoothAccessHandler?()
    }

    @objc private func requestControlAccess() {
        requestControlAccessHandler?()
    }

    @objc private func quitApp() {
        NSStatusBar.system.removeStatusItem(statusItem)
        NSApp.terminate(nil)
    }
}
