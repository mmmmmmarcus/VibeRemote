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

// Fixed Siri Remote mapping (not user-editable):
// - Volume Up/Down  → arrow Up/Down (navigation)
// - Back / Menu     → Backspace
// - TV              → Shift+Enter (newline; the convention most agent apps use)
// - Play/Pause      → Enter (submit)
// - Siri            → Space (held; drives voice dictation and the mic bridge)
let remoteButtonDescriptors: [RemoteButtonDescriptor] = [
    RemoteButtonDescriptor(key: "menu", label: "Menu Button", defaultAction: .backspace, supportsHold: false),
    RemoteButtonDescriptor(key: "back", label: "Back Button", defaultAction: .backspace, supportsHold: false),
    RemoteButtonDescriptor(key: "tv", label: "TV Button", defaultAction: .shiftEnter, supportsHold: false),
    RemoteButtonDescriptor(key: "siri", label: "Siri Button", defaultAction: .spaceKey, supportsHold: true),
    RemoteButtonDescriptor(key: "playPause", label: "Play/Pause Button", defaultAction: .enterKey, supportsHold: false),
    RemoteButtonDescriptor(key: "volumeUp", label: "Volume Up", defaultAction: .upKey, supportsHold: false),
    RemoteButtonDescriptor(key: "volumeDown", label: "Volume Down", defaultAction: .downKey, supportsHold: false),
    RemoteButtonDescriptor(key: "mute", label: "Mute Button", defaultAction: .none, supportsHold: false),
    RemoteButtonDescriptor(key: "power", label: "Power Button", defaultAction: .none, supportsHold: false),
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
    private let statusMenuItem: NSMenuItem
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
        self.statusMenuItem = NSMenuItem(title: "Status: Disconnected", action: nil, keyEquivalent: "")
        super.init()

        diagnosticsMenu.delegate = self
        setupMenuBar()
    }

    /// Draws the menu-bar remote glyph. When `paused` is true, a small pause badge is
    /// notched into the bottom-right corner to signal that the microphone bridge is
    /// enabled but not currently running. The image stays a template so macOS keeps
    /// tinting it for light/dark menu bars; the badge is rendered as tinted disc with the
    /// two pause bars punched out as transparent negative space.
    private static func makeRemoteIcon(paused: Bool = false) -> NSImage {
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

    /// Reflects microphone-bridge health in the menu-bar glyph: a pause badge appears
    /// whenever the bridge is not running — with the app open, the bridge is always
    /// meant to be running.
    private func updateStatusIcon(microphoneStatus: MicrophoneBridgeStatus) {
        statusItem.button?.image = Self.makeRemoteIcon(paused: !microphoneStatus.running)
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        let microphoneStatus = microphoneBridgeManager.menuStatus()
        updateStatusIcon(microphoneStatus: microphoneStatus)

        // Permissions appear only while something still needs granting, pinned to the top.
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

        statusMenuItem.title = remoteSummaryTitle()
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(NSMenuItem.separator())

        // Only the Siri button remains user-customizable; all other buttons are fixed.
        if let siriDescriptor = remoteButtonDescriptors.first(where: { $0.key == Self.siriButtonKey }) {
            let siriItem = NSMenuItem(title: "Siri Button Action", action: nil, keyEquivalent: "")
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
            menu.addItem(NSMenuItem.separator())
        }

        // Microphone controls live directly in the top-level menu.
        addMicrophoneSection(status: microphoneStatus, to: menu)
        menu.addItem(NSMenuItem.separator())

        let diagnosticsItem = NSMenuItem(title: "Diagnostics", action: nil, keyEquivalent: "")
        // A submenu may still be retained by the menu item AppKit just removed.
        // Reusing that NSMenu immediately raises "already a submenu" during rapid
        // device/status refreshes, so each rebuild gets a fresh menu instance.
        diagnosticsMenu.delegate = nil
        diagnosticsMenu = NSMenu()
        diagnosticsMenu.delegate = self
        showDiagnosticsPlaceholder("Open to Load Diagnostics")
        diagnosticsItem.submenu = diagnosticsMenu
        menu.addItem(diagnosticsItem)
        menu.addItem(NSMenuItem.separator())

        let refreshItem = NSMenuItem(title: "Refresh Status", action: #selector(refreshMenu), keyEquivalent: "")
        refreshItem.target = self
        menu.addItem(refreshItem)

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
                    addDisabledItem("Bluetooth Audio: Ready", to: submenu)
                }
            case .notDetermined:
                addActionItem("Allow Bluetooth Audio...", action: #selector(requestBluetoothAccess), to: submenu)
            case .denied:
                addActionItem("Bluetooth Audio: Open Settings...", action: #selector(requestBluetoothAccess), to: submenu)
            case .restricted:
                addDisabledItem("Bluetooth Audio: Restricted", to: submenu)
            }
        }

        if inputAccessIsReady {
            if !onlyRequired {
                addDisabledItem("Button Input: Ready", to: submenu)
            }
        } else {
            switch remoteInputState {
            case .starting:
                addDisabledItem("Button Input: Checking...", to: submenu)
            case .unavailable:
                addDisabledItem("Button Input: Unavailable", to: submenu)
            case .permissionRequired:
                addActionItem("Allow Button Input...", action: #selector(requestInputAccess), to: submenu)
            case .waitingForRemote, .ready:
                break
            }
        }

        if remoteControlState == .ready {
            if !onlyRequired {
                addDisabledItem("Keyboard Control: Ready", to: submenu)
            }
        } else if remoteControlState == .starting {
            addDisabledItem("Keyboard Control: Checking...", to: submenu)
        } else {
            addActionItem("Allow Keyboard Control...", action: #selector(requestControlAccess), to: submenu)
        }

        return submenu
    }

    /// Microphone controls rendered directly into the top-level menu: one status line and
    /// one Start/Restart action. There is no mode toggle or stop action — with the app
    /// open, the bridge is always meant to be running.
    private func addMicrophoneSection(status: MicrophoneBridgeStatus, to menu: NSMenu) {
        addDisabledItem("Microphone: \(status.running ? "Running" : "Stopped")", to: menu)
        if let error = status.lastError {
            let item = NSMenuItem(title: "Needs Attention: \(truncate(error, max: 72))", action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.indentationLevel = 1
            menu.addItem(item)
        }

        let startItemTitle = status.running ? "Restart Bridge" : "Start Bridge"
        let startItem = NSMenuItem(title: startItemTitle, action: #selector(startMicrophoneBridge), keyEquivalent: "")
        startItem.target = self
        startItem.indentationLevel = 1
        menu.addItem(startItem)

        // Only surface the install link while the virtual audio device is actually missing.
        if status.outputDeviceName == nil {
            let installItem = NSMenuItem(
                title: "Install BlackHole...",
                action: #selector(openVirtualAudioDriverPage),
                keyEquivalent: ""
            )
            installItem.target = self
            installItem.indentationLevel = 1
            menu.addItem(installItem)
        }
    }

    /// Compact diagnostics: the handful of facts that answer "is it working, and if not, why".
    /// Copy Diagnostics still exports the full detailed report for debugging.
    private func renderDiagnosticsMenu(_ diagnostics: MicrophoneBridgeDiagnostics) {
        let submenu = diagnosticsMenu
        submenu.removeAllItems()

        addDisabledItem("Bridge: \(diagnostics.bridgeRunning ? "Running" : "Stopped")", to: submenu)
        addDisabledItem("Remote: \(diagnostics.remoteAddress ?? "Not detected")", to: submenu)
        addDisabledItem("Output Device: \(diagnostics.outputDeviceName ?? "Missing")", to: submenu)
        addDisabledItem("Default Input: \(diagnostics.defaultInputDeviceName ?? "Unknown")", to: submenu)
        addDisabledItem(
            "Voice Sessions: \(diagnostics.helperVoiceStartedCount) started, \(diagnostics.helperVoiceEndedCount) ended",
            to: submenu
        )

        if !diagnostics.blockingIssues.isEmpty {
            submenu.addItem(NSMenuItem.separator())
            addDisabledItem("Blocking Issues:", to: submenu)
            for issue in diagnostics.blockingIssues.prefix(4) {
                addDisabledItem("- \(truncate(issue, max: 82))", to: submenu)
            }
        }
        if let error = diagnostics.lastError {
            submenu.addItem(NSMenuItem.separator())
            addDisabledItem("Last Error: \(truncate(error, max: 82))", to: submenu)
        }

        submenu.addItem(NSMenuItem.separator())

        let copyItem = NSMenuItem(title: "Copy Diagnostics", action: #selector(copyDiagnostics), keyEquivalent: "")
        copyItem.target = self
        submenu.addItem(copyItem)

        let appLogItem = NSMenuItem(title: "Open App Log", action: #selector(openAppLog), keyEquivalent: "")
        appLogItem.target = self
        appLogItem.isEnabled = diagnostics.appLogAge != "missing"
        submenu.addItem(appLogItem)

        let refreshItem = NSMenuItem(title: "Refresh Diagnostics", action: #selector(refreshDiagnosticsMenu), keyEquivalent: "")
        refreshItem.target = self
        submenu.addItem(refreshItem)
    }

    private func showDiagnosticsPlaceholder(_ title: String) {
        diagnosticsMenu.removeAllItems()
        addDisabledItem(title, to: diagnosticsMenu)
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === diagnosticsMenu else { return }
        if let cachedDiagnostics {
            renderDiagnosticsMenu(cachedDiagnostics)
        } else {
            showDiagnosticsPlaceholder("Loading Diagnostics...")
        }
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
        if cachedDiagnostics == nil {
            showDiagnosticsPlaceholder("Loading Diagnostics...")
        }

        microphoneBridgeManager.diagnosticsAsync { [weak self] diagnostics in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.cachedDiagnostics = diagnostics
                self.diagnosticsRefreshInFlight = false
                self.renderDiagnosticsMenu(diagnostics)
                let callbacks = self.pendingDiagnosticsCallbacks
                self.pendingDiagnosticsCallbacks.removeAll()
                callbacks.forEach { $0(diagnostics) }
            }
        }
    }

    @objc private func refreshDiagnosticsMenu() {
        requestDiagnostics(force: true)
    }

    private func addDisabledItem(_ title: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

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

    @objc private func openVirtualAudioDriverPage() {
        microphoneBridgeManager.openVirtualAudioDriverPage()
        rebuildMenu()
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
        statusMenuItem.title = remoteSummaryTitle()
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

    private func remoteSummaryTitle() -> String {
        if remoteConnected {
            if let remoteBatteryPercent {
                return "Remote: Connected · Battery \(remoteBatteryPercent)%"
            }
            return "Remote: Connected"
        }
        if !inputAccessIsReady {
            return "Remote: Setup Required"
        }
        return "Remote: Not Connected"
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
