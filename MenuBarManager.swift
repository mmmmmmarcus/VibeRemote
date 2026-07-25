//
//  MenuBarManager.swift
//  VibeRemote
//
//  Manages the menu bar icon and button mapping menu.
//

import AppKit

enum ButtonAction: String, CaseIterable, Sendable {
    case enterKey = "Enter: Submit prompt"
    case shiftEnter = "Shift + Enter: Newline"
    case backspace = "Backspace: Delete"
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
    case slashOrModifier = "Slash: Skill Picker / Hold: Modifier"
    case none = "None"

    var requiresHold: Bool {
        switch self {
        case .spaceKey, .rightCmd, .rightOpt:
            return true
        default:
            return false
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

// Fixed Siri Remote mapping (not user-editable except the Siri button):
// - Clickpad Up/Down/Left/Right → arrow keys; center press → Enter
// - Volume Up/Down  → bullet-list control in AI prompt editors (new/indent, outdent/remove)
// - Back / Menu     → Backspace
// - TV              → Shift+Enter (newline; the convention most agent apps use)
// - Play/Pause      → toggle the Codex / Claude desktop client to the front
// - Power           → Enter
// - Mute            → tap types "/" (skill/command pickers); held it becomes a modifier:
//                     Mute+Back clears all input, Mute+Play/Pause sends Esc
// - Siri            → Space (held; drives voice dictation and the mic bridge)
let remoteButtonDescriptors: [RemoteButtonDescriptor] = [
    RemoteButtonDescriptor(key: "menu", label: "Menu Button", defaultAction: .backspace, supportsHold: false),
    RemoteButtonDescriptor(key: "back", label: "Back Button", defaultAction: .backspace, supportsHold: false),
    RemoteButtonDescriptor(key: "tv", label: "TV Button", defaultAction: .shiftEnter, supportsHold: false),
    RemoteButtonDescriptor(key: "siri", label: "Siri Button", defaultAction: .spaceKey, supportsHold: true),
    RemoteButtonDescriptor(key: "playPause", label: "Play/Pause Button", defaultAction: .launchAgentClient, supportsHold: false),
    RemoteButtonDescriptor(key: "select", label: "Clickpad Center", defaultAction: .enterKey, supportsHold: false),
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
    private var diagnosticsMenu = NSMenu()
    private let microphoneBridgeManager: MicrophoneBridgeManager
    private let remoteBatteryReader = RemoteBatteryReader()
    /// Fixed, non-customizable button-to-action map built from `remoteButtonDescriptors`.
    /// Every button except the Siri button is locked to its descriptor default; the Siri
    /// button stays user-customizable (see `siriButtonAction`).
    private static let fixedButtonActions: [String: ButtonAction] = Dictionary(
        uniqueKeysWithValues: remoteButtonDescriptors.map { ($0.key, $0.defaultAction) }
    )
    private static let siriButtonKey = "siri"
    private static let siriButtonDefaultsKey = "siriButtonAction"
    private static let siriButtonDefaultAction: ButtonAction =
        remoteButtonDescriptors.first { $0.key == siriButtonKey }?.defaultAction ?? .spaceKey
    /// The one remaining customizable mapping, persisted across launches.
    private var siriButtonAction: ButtonAction = MenuBarManager.loadSiriButtonAction()
    private var remoteConnected = false
    private var bluetoothAccessState: BluetoothAccessState = .notDetermined
    private var remoteInputState: RemoteInputState = .permissionRequired
    private var remoteControlState: RemoteControlState = .permissionRequired
    private var requestBluetoothAccessHandler: (() -> Void)?
    private var requestInputAccessHandler: (() -> Void)?
    private var requestControlAccessHandler: (() -> Void)?
    private var statusRefreshHandler: (() -> Void)?
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

        diagnosticsMenu.delegate = self
        setupMenuBar()
    }

    /// The menu-bar glyph: the Apple TV remote SF Symbol, with a pause badge notched into
    /// the bottom-right corner when `paused` (remote disconnected or bridge stopped). Falls
    /// back to a hand-drawn remote if the symbol is unavailable (older macOS). The image
    /// stays a template so macOS keeps tinting it for light/dark menu bars.
    private static func makeRemoteIcon(paused: Bool = false) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        guard let symbol = NSImage(systemSymbolName: "appletvremote.gen4", accessibilityDescription: "VibeRemote")?
            .withSymbolConfiguration(config) else {
            return makeFallbackRemoteIcon(paused: paused)
        }
        guard paused else {
            symbol.isTemplate = true
            return symbol
        }
        let size = symbol.size
        let badged = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            symbol.draw(in: rect)
            let r = size.width * 0.34
            let cx = size.width - r * 0.85
            let cy = r * 0.85

            // Notch a transparent moat so the badge reads as a separate element.
            ctx.setBlendMode(.clear)
            ctx.fillEllipse(in: CGRect(x: cx - r * 1.2, y: cy - r * 1.2, width: r * 2.4, height: r * 2.4))

            // Solid (tinted) badge disc.
            ctx.setBlendMode(.normal)
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))

            // Two pause bars punched out of the disc.
            ctx.setBlendMode(.clear)
            let barW = r * 0.30
            let barH = r * 0.92
            let gap = r * 0.24
            ctx.fill(CGRect(x: cx - gap / 2 - barW, y: cy - barH / 2, width: barW, height: barH))
            ctx.fill(CGRect(x: cx + gap / 2, y: cy - barH / 2, width: barW, height: barH))
            ctx.setBlendMode(.normal)
            return true
        }
        badged.isTemplate = true
        return badged
    }

    /// Hand-drawn remote used only when the SF Symbol is unavailable.
    private static func makeFallbackRemoteIcon(paused: Bool = false) -> NSImage {
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

            if paused {
                let cx = 0.72 * s
                let cy = 0.74 * s
                let badgeR = 0.23 * s
                let moatR = badgeR + 0.05 * s

                // Notch a transparent moat so the badge reads as a separate element even
                // where it overlaps the remote body.
                ctx.setBlendMode(.clear)
                ctx.fillEllipse(in: CGRect(x: cx - moatR, y: cy - moatR, width: 2 * moatR, height: 2 * moatR))

                // Solid (tinted) badge disc.
                ctx.setBlendMode(.normal)
                ctx.fillEllipse(in: CGRect(x: cx - badgeR, y: cy - badgeR, width: 2 * badgeR, height: 2 * badgeR))

                // Two pause bars punched out of the disc.
                ctx.setBlendMode(.clear)
                let barW = 0.06 * s
                let barH = 0.18 * s
                let gap = 0.05 * s
                let barY = cy - barH / 2
                ctx.fill(CGRect(x: cx - gap / 2 - barW, y: barY, width: barW, height: barH))
                ctx.fill(CGRect(x: cx + gap / 2, y: barY, width: barW, height: barH))
                ctx.setBlendMode(.normal)
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private func setupMenuBar() {
        guard let button = statusItem.button else { return }
        button.image = Self.makeRemoteIcon()
        button.title = ""

        rebuildMenu()
        statusItem.menu = menu
    }

    /// Badges the menu-bar glyph whenever something needs attention: the remote is
    /// disconnected, or the bridge is not running.
    private func updateStatusIcon(microphoneStatus: MicrophoneBridgeStatus) {
        let needsAttention = !remoteConnected || !microphoneStatus.running
        statusItem.button?.image = Self.makeRemoteIcon(paused: needsAttention)
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

    private func rebuildMenu() {
        menu.removeAllItems()

        let microphoneStatus = microphoneBridgeManager.menuStatus()
        updateStatusIcon(microphoneStatus: microphoneStatus)

        // Permissions appear only while something still needs granting, pinned to the top.
        // A missing permission is the real reason the remote won't connect, so it takes
        // precedence over the disconnected notice below.
        let bluetoothNeeded = bluetoothAccessState != .allowed
        let missingPermissionCount = (inputAccessIsReady ? 0 : 1)
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

        // With no remote connected there is nothing to control, so show only a notice
        // (same banner style, no button) and Quit — Status and Siri mapping are hidden.
        guard remoteConnected else {
            menu.addItem(makeBanner(symbolName: "exclamationmark.triangle.fill", text: "Remote disconnected"))
            menu.addItem(NSMenuItem.separator())
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
        } else if !microphoneStatus.running {
            menu.addItem(makeBanner(
                symbolName: "pause.circle.fill",
                text: "Bridge is stopped",
                buttonTitle: "Start",
                buttonAction: #selector(startMicrophoneBridge)
            ))
            menu.addItem(NSMenuItem.separator())
        }

        // At-a-glance lines rendered directly in the top level. Bridge run state is already
        // conveyed by the menu-bar icon and the stopped banner, so this row is a fixed
        // "Status" entry that opens the detailed diagnostics submenu.
        addInfoItem("Bluetooth: \(remoteConnected ? "Connected" : "Not Connected")", to: menu)
        addInfoItem("Battery: \(remoteBatteryPercent.map { "\($0)%" } ?? "Unknown")", to: menu)

        let bridgeItem = NSMenuItem(title: "Status", action: nil, keyEquivalent: "")
        // A submenu may still be retained by the menu item AppKit just removed.
        // Reusing that NSMenu immediately raises "already a submenu" during rapid
        // device/status refreshes, so each rebuild gets a fresh menu instance.
        diagnosticsMenu.delegate = nil
        diagnosticsMenu = NSMenu()
        diagnosticsMenu.delegate = self
        renderBridgeDetailMenu(diagnostics: cachedDiagnostics)
        bridgeItem.submenu = diagnosticsMenu
        menu.addItem(bridgeItem)
        menu.addItem(NSMenuItem.separator())

        // Only the Siri button remains user-customizable; all other buttons are fixed.
        if let siriDescriptor = remoteButtonDescriptors.first(where: { $0.key == Self.siriButtonKey }) {
            let siriItem = NSMenuItem(title: "Siri Button Mapping", action: nil, keyEquivalent: "")
            let siriSubmenu = NSMenu()
            for action in ButtonAction.allCases {
                if action.requiresHold && !siriDescriptor.supportsHold { continue }
                let actionItem = NSMenuItem(
                    title: action.rawValue,
                    action: #selector(changeSiriButtonAction(_:)),
                    keyEquivalent: ""
                )
                actionItem.target = self
                actionItem.representedObject = action
                actionItem.state = siriButtonAction == action ? .on : .off
                siriSubmenu.addItem(actionItem)
            }
            siriItem.submenu = siriSubmenu
            menu.addItem(siriItem)
        }
        menu.addItem(NSMenuItem.separator())

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
                addInfoItem("Button Input: Unavailable", to: submenu)
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

    /// The Bridge line's submenu: detailed diagnostics plus bridge/diagnostic actions.
    /// The at-a-glance status (Bluetooth / Battery / Bridge) lives in the top-level menu.
    /// Detail lines lazy-load once the async diagnostics snapshot arrives; Copy Diagnostics
    /// still exports the full detailed report for debugging.
    private func renderBridgeDetailMenu(diagnostics: MicrophoneBridgeDiagnostics?) {
        let submenu = diagnosticsMenu
        submenu.removeAllItems()
        let microphoneStatus = microphoneBridgeManager.menuStatus()

        if let error = microphoneStatus.lastError {
            addInfoItem("Needs Attention: \(truncate(error, max: 72))", to: submenu)
            submenu.addItem(NSMenuItem.separator())
        }

        let helperDescription: String
        switch PrivilegedHelperClient.shared.state {
        case .ready: helperDescription = "Approved"
        case .awaitingApproval: helperDescription = "Waiting for approval"
        case .notRegistered: helperDescription = "Not set up"
        case .unsupported: helperDescription = "Unavailable (needs macOS 13+)"
        }
        addInfoItem("Helper: \(helperDescription)", to: submenu)

        if let diagnostics {
            addInfoItem("Remote: \(diagnostics.remoteAddress ?? "Not detected")", to: submenu)
            addInfoItem("Output Device: \(diagnostics.outputDeviceName ?? "Missing")", to: submenu)
            addInfoItem("Default Input: \(diagnostics.defaultInputDeviceName ?? "Unknown")", to: submenu)
            addInfoItem(
                "Voice Sessions: \(diagnostics.helperVoiceStartedCount) started, \(diagnostics.helperVoiceEndedCount) ended",
                to: submenu
            )
            if !diagnostics.blockingIssues.isEmpty {
                submenu.addItem(NSMenuItem.separator())
                addInfoItem("Blocking Issues:", to: submenu)
                for issue in diagnostics.blockingIssues.prefix(4) {
                    addInfoItem("- \(truncate(issue, max: 82))", to: submenu)
                }
            }
        } else {
            addInfoItem("Loading Diagnostics...", to: submenu)
        }

        submenu.addItem(NSMenuItem.separator())

        let bridgeActionTitle = microphoneStatus.running ? "Restart Bridge" : "Start Bridge"
        let bridgeActionItem = NSMenuItem(title: bridgeActionTitle, action: #selector(startMicrophoneBridge), keyEquivalent: "")
        bridgeActionItem.target = self
        submenu.addItem(bridgeActionItem)

        if microphoneStatus.outputDeviceName == nil, microphoneBridgeManager.bundledAudioDriverAvailable {
            let installItem = NSMenuItem(
                title: "Install Audio Device...",
                action: #selector(installAudioDriver),
                keyEquivalent: ""
            )
            installItem.target = self
            submenu.addItem(installItem)
        }

        let copyItem = NSMenuItem(title: "Copy Diagnostics", action: #selector(copyDiagnostics), keyEquivalent: "")
        copyItem.target = self
        submenu.addItem(copyItem)

        let appLogItem = NSMenuItem(title: "Open App Log", action: #selector(openAppLog), keyEquivalent: "")
        appLogItem.target = self
        appLogItem.isEnabled = diagnostics.map { $0.appLogAge != "missing" } ?? true
        submenu.addItem(appLogItem)

        let refreshItem = NSMenuItem(title: "Refresh Status", action: #selector(refreshMenu), keyEquivalent: "")
        refreshItem.target = self
        submenu.addItem(refreshItem)
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === diagnosticsMenu else { return }
        renderBridgeDetailMenu(diagnostics: cachedDiagnostics)
        requestDiagnostics(force: false)
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
                self.renderBridgeDetailMenu(diagnostics: diagnostics)
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

    func getMapping(for button: String) -> ButtonAction {
        if button == Self.siriButtonKey {
            return siriButtonAction
        }
        return Self.fixedButtonActions[button] ?? .none
    }

    private static func loadSiriButtonAction() -> ButtonAction {
        guard let raw = UserDefaults.standard.string(forKey: siriButtonDefaultsKey),
              let action = ButtonAction(rawValue: raw) else {
            return siriButtonDefaultAction
        }
        return action
    }

    private func setSiriButtonAction(_ action: ButtonAction) {
        siriButtonAction = action
        UserDefaults.standard.set(action.rawValue, forKey: Self.siriButtonDefaultsKey)
        rebuildMenu()
    }

    @objc private func changeSiriButtonAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? ButtonAction else { return }
        setSiriButtonAction(action)
    }

    @objc private func requestInputAccess() {
        requestInputAccessHandler?()
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
