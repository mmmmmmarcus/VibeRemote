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
        let action = RemoteButtonMapping.action(button: key, generation: snapshot.generation, siriAction: snapshot.siriAction)
        return action == .none ? "Not assigned" : action.settingsTitle
    }

    /// The guide's controls from the top of the remote down, for the Buttons list.
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

    var attention: String?
    var helper = "Checking…"
    var bridgeRunning = false
    var canInstallDriver = false
    var report: Report?
}

/// Everything a pane can ask the app to do. The menu manager owns the work; Settings
/// only forwards the user's choice.
struct SettingsActions {
    var installAudioDriver: () -> Void = {}
    var restartBridge: () -> Void = {}
    var copyDiagnostics: () -> Void = {}
    var openAppLog: () -> Void = {}
    var refreshDiagnostics: () -> Void = {}
    var showOnboarding: () -> Void = {}
    var openAgentPanel: () -> Void = {}
}

enum SettingsTab: String, CaseIterable, Identifiable {
    /// `agent` keeps its raw value so saved accessibility identifiers and any stored
    /// selection survive the rename of its visible title to "Interface Control".
    case remote, cursor, agent, diagnostics, about
    var id: String { rawValue }

    /// The remote itself and what it drives. Buttons and Microphone used to be panes of
    /// their own; both now live on the Remote pane, so no single-row group is left behind.
    static let remoteTabs: [SettingsTab] = [.remote, .cursor, .agent]
    /// About the app rather than the remote, so they close the sidebar in their own group.
    static let appTabs: [SettingsTab] = [.diagnostics, .about]

    var title: String {
        switch self {
        case .remote: return "Remote"
        case .cursor: return "Text Cursor"
        case .agent: return "Interface Control"
        case .diagnostics: return "Diagnostics"
        case .about: return "About"
        }
    }

    var systemImage: String {
        switch self {
        case .remote: return "appletvremote.gen4"
        case .cursor: return "character.cursor.ibeam"
        case .agent: return "cursorarrow.motionlines"
        case .diagnostics: return "stethoscope"
        case .about: return "info.circle"
        }
    }
}

extension RemoteSettingsSnapshot {
    /// Restore Defaults covers exactly the two choices Settings can change on the remote.
    var isAtDefaults: Bool {
        let defaultAction = remoteButtonDescriptors.first { $0.key == "siri" }?.defaultAction ?? .spaceKey
        return siriAction == defaultAction && idleTimeout == .defaultValue
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
/// Only the Siri button exposes an editable action menu.
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
