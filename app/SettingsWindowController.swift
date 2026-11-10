import AppKit
import SwiftUI
import Combine

enum SettingsAssets {
    // SwiftPM's command-line accessor searches beside the executable bundle. Our
    // signed .app keeps resources in Contents/Resources; resolve that location first
    // so a copied app never depends on a build directory on the developer's machine.
    static let bundle: Bundle = bundledResources(in: .main) ?? .module

    static func bundledResources(in appBundle: Bundle) -> Bundle? {
        guard let url = appBundle.resourceURL?.appendingPathComponent("VibeRemote_VibeRemote.bundle") else {
            return nil
        }
        return Bundle(url: url)
    }
}

/// Presentation values only. The menu manager remains the owner of mappings and live
/// connection state, so opening a window never creates a second Bluetooth/HID session.
struct RemoteSettingsSnapshot: Equatable, Sendable {
    var connected: Bool
    var batteryPercent: Int?
    var siriAction: ButtonAction
    var generation: RemoteGeneration = .unknown
    var idleTimeout: RemoteIdleTimeout = .defaultValue
    /// The remote's Bluetooth name, shown under the Status section's Bluetooth row.
    var remoteName: String? = nil
    /// The user's per-button choices for `generation`, keyed by `RemoteButtonMapping.overrideKey`.
    var buttonOverrides: [String: ButtonAction] = [:]
    /// Every profile, and the one Settings is editing. `siriAction` and `buttonOverrides`
    /// above are that profile's effective values, General's filled in where it follows them.
    var profiles: ButtonProfileSet = .defaults()
    var editingProfileID: String = ButtonProfile.generalID

    var editingProfile: ButtonProfile { profiles.profile(id: editingProfileID) ?? profiles.general }

    /// Whether `key` ("siri" or a button) follows General in the edited app profile.
    func followsGeneral(_ key: String) -> Bool {
        profiles.inherits(key, profile: editingProfileID, generation: generation)
    }

    /// What `key` does in General, for an app profile's "Same as General" choice.
    func generalAction(for key: String) -> ButtonAction {
        key == "siri" ? profiles.siriAction(profile: ButtonProfile.generalID)
            : profiles.action(button: key, generation: generation, profile: ButtonProfile.generalID)
    }

    func action(for button: String) -> ButtonAction {
        RemoteButtonMapping.action(button: button, generation: generation, siriAction: siriAction,
                                   overrides: buttonOverrides)
    }

    var connectionText: String {
        guard connected else { return "DISCONNECTED" }
        guard let batteryPercent, (0...100).contains(batteryPercent) else {
            return "CONNECTED — BATTERY UNKNOWN"
        }
        return "CONNECTED \(batteryPercent)%"
    }
}

/// Coordinates are measured from the top of each generation's 398-point artwork.
/// Coordinates follow the imported CAD controls. Keep both physical layouts distinct.
struct RemoteSettingsLayout {
    struct Callout: Identifiable {
        let key: String
        let centerY: CGFloat
        var id: String { key }
    }
    let resourceName: String
    let artworkWidth: CGFloat
    let left: [Callout]
    let right: [Callout]

    init(generation: RemoteGeneration) {

        if generation == .glassTouchSurface {
            resourceName = "SiriRemoteFirstGeneration"
            artworkWidth = 123
            left = [.init(key: "back", centerY: 147.3), .init(key: "siri", centerY: 198.8), .init(key: "playPause", centerY: 251.5)]
            right = [.init(key: "select", centerY: 70), .init(key: "tv", centerY: 147.3), .init(key: "volumeUp", centerY: 198.8), .init(key: "volumeDown", centerY: 251.5)]
        } else {
            resourceName = "SiriRemote"
            artworkWidth = 104
            left = [.init(key: "select", centerY: 84.6), .init(key: "touch.edit", centerY: 124.5), .init(key: "back", centerY: 150.8), .init(key: "playPause", centerY: 193.5), .init(key: "mute", centerY: 236.2)]
            right = [.init(key: "power", centerY: 22.2), .init(key: "siri", centerY: 84.6), .init(key: "tv", centerY: 150.8), .init(key: "volumeUp", centerY: 193.5), .init(key: "volumeDown", centerY: 236.2)]
        }
    }
}

/// Settings shows every control's function as a pill beside the remote at once, so pills on
/// one side must not overlap: each sits on its button's row unless that is closer than `pitch`
/// to the one above, then moves down just enough; a column that runs past the bottom shifts
/// back up. Pure so the spacing is testable. `centers` are in top-down preview points.
enum RemotePillLayout {
    static func centers(_ centers: [CGFloat], pitch: CGFloat, height: CGFloat) -> [CGFloat] {
        let order = centers.indices.sorted { centers[$0] < centers[$1] }
        var placed = [CGFloat](repeating: 0, count: centers.count)
        var previous = -CGFloat.infinity
        for index in order {
            placed[index] = max(centers[index], previous + pitch, pitch / 2)
            previous = placed[index]
        }
        var next = CGFloat.infinity
        for index in order.reversed() {
            placed[index] = min(placed[index], next - pitch, height - pitch / 2)
            next = placed[index]
        }
        return placed
    }
}

/// The guide describes fixed functions, not physical button names.
enum RemoteSettingsGuide {
    static func title(for key: String, snapshot: RemoteSettingsSnapshot) -> String {

        if key == "siri" { return snapshot.siriAction.settingsTitle }
        if key == "touch.edit" { return "Slide to position caret" }
        if key == "select" {
            return snapshot.generation == .glassTouchSurface
                ? "Enter / Confirm caret\nSwipe: Arrow key"
                : "Confirm caret"
        }
        let action = snapshot.action(for: key)
        return action == .none ? "Not assigned" : action.settingsTitle
    }

    /// The choices a Settings pill offers, with the current one; nil for fixed-role controls
    /// (Advanced Menu opener, caret confirmation, the clickpad ring).
    static func pillOptions(for key: String, snapshot: RemoteSettingsSnapshot) -> (choices: [ButtonAction], current: ButtonAction)? {
        if key == "siri" {
            return (ButtonAction.allCases.filter(\.isAssignableToSiriButton), snapshot.siriAction)
        }
        guard let choices = RemoteButtonMapping.choices(button: key, generation: snapshot.generation) else { return nil }
        return (choices, snapshot.action(for: key))
    }

    /// The guide's controls from the top of the remote down.
    static func buttons(for generation: RemoteGeneration) -> [String] {
        let layout = RemoteSettingsLayout(generation: generation)
        return (layout.left + layout.right).sorted { $0.centerY < $1.centerY }.map(\.key)
    }

    /// Printed names follow the remote family (glass: Menu, Touch Surface; aluminum: Back, Clickpad).
    static func buttonName(for key: String, generation: RemoteGeneration) -> String {
        let glass = generation == .glassTouchSurface
        switch key {
        case "select": return glass ? "Touch Surface" : "Clickpad Center"
        case "touch.edit": return "Clickpad Ring"
        case "back": return glass ? "Menu" : "Back"
        case "playPause": return "Play/Pause"
        case "volumeUp": return "Volume Up"
        case "volumeDown": return "Volume Down"
        case "tv": return "TV"
        case "siri": return "Siri"
        case "mute": return "Mute"
        case "power": return "Power"
        default: return key
        }
    }
}

extension ButtonAction {
    var settingsTitle: String {
        switch self {
        case .positionCaret: return "Position caret"
        case .enterKey: return "Enter"
        case .shiftEnter: return "Shift + Enter"
        case .backspace: return "Delete word"
        case .upKey: return "Up Arrow"
        case .downKey: return "Down Arrow"
        case .leftKey: return "Left Arrow"
        case .rightKey: return "Right Arrow"
        case .escKey: return "Escape"
        case .ctrlC: return "Control + C"
        case .spaceKey: return "Space"
        case .rightCmd: return "Right Command"
        case .rightOpt: return "Right Option"
        case .launchAgentClient: return "Codex / Claude"
        case .bulletIndent: return "New / Indent"
        case .bulletOutdent: return "Outdent"
        case .slashOrModifier: return "Skill / Modifier"
        case .shiftEnterOrModifier: return "Newline / Modifier"
        case .agentClientOrSlash: return "Client / Skill"
        case .advancedMenu: return "Advanced Menu"
        case .skillPicker: return "Skill"
        case .slashSkill: return "Skill (/)"
        case .dollarSkill: return "Skill ($)"
        case .commandEnter: return "Command + Enter"
        case .undo: return "Undo"
        case .redo: return "Redo"
        case .vibeDictation: return "Dictation"
        case .none: return "None"
        }
    }
}

/// The bridge's health as Settings shows it. `MenuBarManager` builds it from the same
/// sources the old Diagnostics submenu read; `report` is nil until the async snapshot lands.
struct SettingsDiagnostics: Equatable {
    struct Report: Equatable {
        var remoteAddress: String?
        var outputDevice: String?
        var defaultInput: String?
        var voiceSessions: String
        var blockingIssues: [String]
        var appLogAvailable: Bool
    }

    /// A setup step the user still has to finish. Settings shows the Helper and Audio Driver
    /// rows only while one of these exists, plus the red Fix pill that opens its guide.
    enum SetupIssue: Equatable, Identifiable {
        case helperNotSetUp
        case helperAwaitingApproval
        /// No supported virtual device exists; `installable` is false when this build
        /// bundles no driver (a fresh clone that never ran build_audio_driver.sh).
        case audioDriverMissing(installable: Bool)

        var id: String {
            switch self {
            case .helperNotSetUp, .helperAwaitingApproval: return "helper"
            case .audioDriverMissing: return "audioDriver"
            }
        }

        var isHelper: Bool { id == "helper" }
    }

    var attention: String?
    var helper = "Checking…"
    var bridgeRunning = false
    var setupIssues: [SetupIssue] = []
    var report: Report?

    /// The same health rules as the status menu's setup banners and onboarding: the helper
    /// needs action until it is approved, and the driver counts as present as soon as any
    /// supported output device (VibeRemote, BlackHole, Soundflower) exists. `.unsupported`
    /// cannot happen on the macOS 27 deployment target and has nothing to fix, so it is no issue.
    static func setupIssues(helper: PrivilegedHelperState, outputDeviceName: String?,
                            driverInstallable: Bool) -> [SetupIssue] {
        var issues: [SetupIssue] = []
        switch helper {
        case .notRegistered: issues.append(.helperNotSetUp)
        case .awaitingApproval: issues.append(.helperAwaitingApproval)
        case .ready, .unsupported: break
        }
        if outputDeviceName == nil { issues.append(.audioDriverMissing(installable: driverInstallable)) }
        return issues
    }

    /// The pill names the single thing to fix, or the whole setup when both need work.
    var setupPillTitle: String? {
        switch (setupIssues.contains(where: \.isHelper), setupIssues.contains(where: { !$0.isHelper })) {
        case (true, true): return "Fix Setup"
        case (true, false): return "Fix Helper"
        case (false, true): return "Fix Audio Driver"
        case (false, false): return nil
        }
    }
}

/// Everything a pane can ask the app to do. The menu manager owns the work; Settings
/// only forwards the user's choice.
struct SettingsActions {
    var installAudioDriver: () -> Void = {}
    /// Registers the helper, or opens Login Items when it is already waiting for approval.
    var setUpHelper: () -> Void = {}
    /// A pill's choice for a non-Siri button on the remote family Settings shows.
    var setButtonAction: (String, ButtonAction) -> Void = { _, _ in }
    /// An app profile's "Same as General" for one pill ("siri" or a button key).
    var followGeneral: (String) -> Void = { _ in }
    var selectProfile: (String) -> Void = { _ in }
    /// Adds a profile for the app (bundle identifier, display name) and starts editing it.
    var addProfile: (String, String) -> Void = { _, _ in }
    var removeProfile: (String) -> Void = { _ in }
    var restartBridge: () -> Void = {}
    var copyDiagnostics: () -> Void = {}
    var openAppLog: () -> Void = {}
    var refreshDiagnostics: () -> Void = {}
    var showOnboarding: () -> Void = {}
    var openAgentPanel: () -> Void = {}
}

enum SettingsTab: String, CaseIterable, Identifiable {
    /// `agent` keeps its raw value so saved accessibility identifiers and any stored
    /// selection survive the renames of its visible title (now "Computer Use").
    case remote, cursor, dictation, agent, diagnostics, about
    var id: String { rawValue }

    /// The remote itself and what it drives. Buttons and Microphone used to be panes of
    /// their own; both now live on the Remote pane, so no single-row group is left behind.
    static let remoteTabs: [SettingsTab] = [.remote, .cursor, .dictation, .agent]
    /// About the app rather than the remote, so they close the sidebar in their own group.
    static let appTabs: [SettingsTab] = [.diagnostics, .about]

    var title: String {
        switch self {
        case .remote: return "Remote"
        case .cursor: return "Text Cursor"
        case .dictation: return "Dictation"
        case .agent: return "Computer Use"
        case .diagnostics: return "Diagnostics"
        case .about: return "About"
        }
    }

    var systemImage: String {
        switch self {
        case .remote: return "appletvremote.gen4"
        case .cursor: return "character.cursor.ibeam"
        case .dictation: return "waveform"
        case .agent: return "cursorarrow.motionlines"
        case .diagnostics: return "stethoscope"
        case .about: return "info.circle"
        }
    }
}

extension RemoteSettingsSnapshot {
    /// Restore Defaults covers the edited profile's choices (and, for General, Auto Disconnect).
    var isAtDefaults: Bool {
        // Auto Disconnect is not per app, so only General's Restore Defaults covers it. For
        // General the effective values above are its own choices.
        guard editingProfileID == ButtonProfile.generalID else { return profiles.isAtDefaults(editingProfileID) }
        return siriAction == ButtonProfileSet.siriDefault && idleTimeout == .defaultValue && buttonOverrides.isEmpty
    }
}

@MainActor
final class RemoteSettingsModel: ObservableObject {
    @Published var snapshot: RemoteSettingsSnapshot
    @Published var diagnostics = SettingsDiagnostics()
    @Published var tab: SettingsTab = .remote

    init(snapshot: RemoteSettingsSnapshot) {
        self.snapshot = snapshot
    }
}

/// Retained after closing: repeated menu clicks bring the same window forward. The
/// layout follows Spotter's Settings (and System Settings): a fixed 720 x 550 window with
/// a transparent title bar, a 190-point sidebar and grouped-Form panes.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let size = NSSize(width: 720, height: 550)
    /// A new key per width: `setFrameUsingName` restores the saved frame after
    /// `setContentSize`, so reusing the old name would bring the wider window back.
    private static let frameName = "VibeRemote.Settings.Compact"
    let model: RemoteSettingsModel

    init(
        snapshot: RemoteSettingsSnapshot,
        setSiriAction: @escaping (ButtonAction) -> Void,
        resetSiriAction: @escaping () -> Void,
        setIdleTimeout: @escaping (RemoteIdleTimeout) -> Void = { _ in },
        actions: SettingsActions = SettingsActions()
    ) {
        model = RemoteSettingsModel(snapshot: snapshot)
        refreshDiagnostics = actions.refreshDiagnostics
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        window.delegate = self
        window.title = "Vibe Remote"
        window.identifier = NSUserInterfaceItemIdentifier("VibeRemote.Settings")
        window.isReleasedWhenClosed = false
        // Content runs edge to edge under the transparent title bar; the traffic lights
        // sit over the sidebar, as in System Settings.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        let hosting = NSHostingView(rootView: SettingsRootView(
            model: model,
            setSiriAction: setSiriAction,
            restoreDefaults: resetSiriAction,
            setIdleTimeout: setIdleTimeout,
            actions: actions
        ))
        // Keep the requested size instead of the SwiftUI fitting size; panes fill the frame.
        hosting.sizingOptions = []
        window.contentView = hosting
        window.setContentSize(Self.size)
        if !window.setFrameUsingName(Self.frameName) { window.center() }
        window.setFrameAutosaveName(Self.frameName)
        update(snapshot)
    }

    required init?(coder: NSCoder) { nil }

    /// Helper approval happens in System Settings, outside this window; re-reading the status
    /// when the user comes back clears the Fix pill without waiting for the next menu rebuild.
    private let refreshDiagnostics: () -> Void

    func windowDidBecomeKey(_ notification: Notification) { refreshDiagnostics() }

    func show(tab: SettingsTab? = nil) {
        if let tab { model.tab = tab }
        NSApp.setActivationPolicy(.regular)
        showWindow(nil)
        window?.deminiaturize(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        rmDebug("⚙️ Settings window visible=\(window?.isVisible == true) tab=\(model.tab.rawValue)")
    }

    func windowWillClose(_ notification: Notification) {
        // Keep the Dock entry while minimized so it can restore Settings, but return
        // to menu-bar-only operation when the retained settings window is closed.
        restoreAccessoryPolicy(closing: window)
    }

    func update(_ snapshot: RemoteSettingsSnapshot) {
        if model.snapshot != snapshot { model.snapshot = snapshot }
    }

    func update(diagnostics: SettingsDiagnostics) {
        if model.diagnostics != diagnostics { model.diagnostics = diagnostics }
    }
}

/// NSPopUpButton supplies keyboard navigation, VoiceOver and the system appearance.
/// Onboarding's Siri page uses it; Settings edits Siri through its pill instead.
@MainActor
struct SiriActionPopUp: NSViewRepresentable {
    let action: ButtonAction
    let onSelect: (ButtonAction) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

    func makeNSView(context: Context) -> SizedPopUpButton {
        let button = SizedPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectAction(_:))
        button.identifier = NSUserInterfaceItemIdentifier("siri")
        button.setAccessibilityIdentifier("settings.mapping.siri")
        button.setAccessibilityLabel("Siri Button")
        updateNSView(button, context: context)
        return button
    }

    func updateNSView(_ button: SizedPopUpButton, context: Context) {
        context.coordinator.onSelect = onSelect
        let actions = ButtonAction.allCases.filter(\.isAssignableToSiriButton)
        button.toolTip = action.actionDescription
        // Rebuild only when the choice changes; status/battery updates must not dismiss
        // an open native menu or reset its keyboard selection.
        if button.selectedItem?.representedObject as? String == action.rawValue,
           button.itemArray.compactMap({ $0.representedObject as? String }) == actions.map(\.rawValue) { return }
        button.removeAllItems()
        for option in actions {
            button.addItem(withTitle: option.settingsTitle)
            button.lastItem?.representedObject = option.rawValue
            button.lastItem?.toolTip = option.actionDescription
        }
        button.selectItem(at: actions.firstIndex(of: action) ?? 0)
    }

    final class SizedPopUpButton: NSPopUpButton {
        // Explanations in the menu can be longer than the selected title. Keep the
        // row's control a fixed width instead of growing to the longest item.
        override var intrinsicContentSize: NSSize { NSSize(width: 180, height: super.intrinsicContentSize.height) }
    }

    @MainActor
    final class Coordinator: NSObject {
        var onSelect: (ButtonAction) -> Void

        init(onSelect: @escaping (ButtonAction) -> Void) {
            self.onSelect = onSelect
        }

        @objc func selectAction(_ sender: NSPopUpButton) {
            guard sender.isEnabled, sender.identifier?.rawValue == "siri" else { return }
            guard let raw = sender.selectedItem?.representedObject as? String,
                  let action = ButtonAction(rawValue: raw), action.isAssignableToSiriButton else { return }
            onSelect(action)
        }
    }
}
