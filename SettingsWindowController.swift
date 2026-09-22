import AppKit
import SwiftUI

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
/// Keep images and callouts together: hiding new-remote buttons is not an old layout.
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
            left = [.init(key: "back", centerY: 149), .init(key: "siri", centerY: 201), .init(key: "playPause", centerY: 252)]
            right = [.init(key: "select", centerY: 70), .init(key: "tv", centerY: 149), .init(key: "volumeUp", centerY: 201), .init(key: "volumeDown", centerY: 252)]
        } else {
            resourceName = "SiriRemote"
            artworkWidth = 104
            left = [.init(key: "select", centerY: 62), .init(key: "touch.edit", centerY: 103), .init(key: "back", centerY: 146), .init(key: "playPause", centerY: 192), .init(key: "mute", centerY: 238)]
            right = [.init(key: "power", centerY: 18), .init(key: "siri", centerY: 82), .init(key: "tv", centerY: 144), .init(key: "volumeUp", centerY: 186), .init(key: "volumeDown", centerY: 236)]
        }
    }
}

/// The guide describes fixed functions, not physical button names.
enum RemoteSettingsGuide {
    static func title(for key: String, snapshot: RemoteSettingsSnapshot) -> String {

        if key == "touch.edit" { return "Slide to position caret" }
        if key == "select" { return "Position caret" }
        if key == "back" || key == "menu" { return "Delete word\nDouble-click: clear all" }
        let action = RemoteButtonMapping.action(button: key, generation: snapshot.generation, siriAction: snapshot.siriAction)
        return action == .none ? "Not assigned" : action.settingsTitle
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
        case .none: return "None"
        }
    }
}

@MainActor
private final class RemoteSettingsModel: ObservableObject {
    @Published var snapshot: RemoteSettingsSnapshot

    init(snapshot: RemoteSettingsSnapshot) {
        self.snapshot = snapshot
    }
}

/// Retained after closing: repeated menu clicks bring the same window forward. A
/// standard AppKit window/toolbar hosts SwiftUI content without changing LSUIElement.
@MainActor
final class SettingsWindowController: NSWindowController, NSToolbarDelegate, NSWindowDelegate {
    private static let moreIdentifier = NSToolbarItem.Identifier("VibeRemote.MoreSettings")
    private let model: RemoteSettingsModel
    private let setSiriAction: (ButtonAction) -> Void
    private let resetSiriAction: () -> Void
    private var resetItem: NSMenuItem?
    private let audioSettingsMenu: NSMenu?
    private let diagnosticsMenu: NSMenu?

    init(
        snapshot: RemoteSettingsSnapshot,
        setSiriAction: @escaping (ButtonAction) -> Void,
        resetSiriAction: @escaping () -> Void,
        setIdleTimeout: @escaping (RemoteIdleTimeout) -> Void = { _ in },
        audioSettingsMenu: NSMenu? = nil,
        diagnosticsMenu: NSMenu? = nil
    ) {
        model = RemoteSettingsModel(snapshot: snapshot)
        self.setSiriAction = setSiriAction
        self.resetSiriAction = resetSiriAction
        self.audioSettingsMenu = audioSettingsMenu
        self.diagnosticsMenu = diagnosticsMenu
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 660),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        window.delegate = self
        window.title = "Vibe Remote"
        window.identifier = NSUserInterfaceItemIdentifier("VibeRemote.Settings")
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unified
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isOpaque = false
        window.backgroundColor = .clear
        window.setFrameAutosaveName("VibeRemote.Settings.Split")
        let hosting = NSHostingController(rootView: RemoteSettingsView(
            model: model,
            setSiriAction: setSiriAction,
            setIdleTimeout: setIdleTimeout
        ))
        let content = NSViewController()
        content.addChild(hosting)
        // The window supplies a quiet translucent backdrop; glass is reserved for the
        // interactive controls. System materials follow appearance, contrast and Reduce
        // Transparency instead of baking a white fill or a custom blur into the view.
        let backdrop = NSVisualEffectView()
        backdrop.material = .underWindowBackground
        backdrop.blendingMode = .behindWindow
        backdrop.state = .followsWindowActiveState
        content.view = backdrop
        let glassContainer = NSGlassEffectContainerView()
        glassContainer.spacing = 0
        glassContainer.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(glassContainer)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        glassContainer.contentView = hosting.view
        NSLayoutConstraint.activate([
            glassContainer.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            glassContainer.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
            glassContainer.topAnchor.constraint(equalTo: backdrop.safeAreaLayoutGuide.topAnchor),
            glassContainer.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),
            hosting.view.leadingAnchor.constraint(equalTo: glassContainer.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: glassContainer.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: glassContainer.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: glassContainer.bottomAnchor)
        ])
        window.contentViewController = content

        let toolbar = NSToolbar(identifier: "VibeRemote.SettingsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.setContentSize(NSSize(width: 1000, height: 660))
        // Preserve the existing outer window size, extending only the backdrop beneath
        // the native toolbar. Controls stay within the unobscured safe area above.
        window.styleMask.insert(.fullSizeContentView)
        if !window.setFrameUsingName("VibeRemote.Settings.Split") {
            window.center()
        }
        update(snapshot)
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        NSApp.setActivationPolicy(.regular)
        showWindow(nil)
        window?.deminiaturize(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        rmDebug("⚙️ Settings window visible=\(window?.isVisible == true)")
    }

    func windowWillClose(_ notification: Notification) {
        // Keep the Dock entry while minimized so it can restore Settings, but return
        // to menu-bar-only operation when the retained settings window is closed.
        NSApp.setActivationPolicy(.accessory)
    }

    func update(_ snapshot: RemoteSettingsSnapshot) {
        if model.snapshot != snapshot { model.snapshot = snapshot }
        let defaultAction = remoteButtonDescriptors.first { $0.key == "siri" }?.defaultAction ?? .spaceKey
        resetItem?.isEnabled = snapshot.siriAction != defaultAction || snapshot.idleTimeout != .defaultValue
        for item in audioSettingsMenu?.items ?? [] where item.representedObject is String {
            item.state = item.representedObject as? String == (UserDefaults.standard.string(forKey: "audioOutputBackend") ?? "shared") ? .on : .off
        }
    }

    @objc private func resetSettings() {
        resetSiriAction()
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.moreIdentifier]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard itemIdentifier == Self.moreIdentifier else { return nil }
        // Let AppKit supply the toolbar's glass button and anchored system menu.
        // Only Reset is disabled at defaults; the More menu remains available.
        let item = NSMenuToolbarItem(itemIdentifier: itemIdentifier)
        item.label = "More"
        item.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "More settings")
        item.showsIndicator = false
        item.isBordered = true
        item.autovalidates = false
        item.toolTip = "More settings"
        let menu = NSMenu(title: "More settings")
        menu.autoenablesItems = false
        let reset = NSMenuItem(title: "Reset", action: #selector(resetSettings), keyEquivalent: "")
        reset.target = self
        reset.identifier = NSUserInterfaceItemIdentifier("VibeRemote.ResetSettings")
        reset.image = NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: nil)
        reset.toolTip = "Restore Siri Button, touch speeds and auto disconnect to their defaults."
        menu.addItem(reset)
        if let audioSettingsMenu {
            menu.addItem(.separator())
            let audio = NSMenuItem(title: "Audio Output", action: nil, keyEquivalent: "")
            audio.submenu = audioSettingsMenu; menu.addItem(audio)
        }
        if let diagnosticsMenu {
            let diagnostics = NSMenuItem(title: "Diagnostics", action: nil, keyEquivalent: "")
            diagnostics.submenu = diagnosticsMenu
            menu.addItem(diagnostics)
        }
        item.menu = menu
        resetItem = reset
        return item
    }
}

@MainActor
private struct RemoteSettingsView: View {
    @ObservedObject var model: RemoteSettingsModel
    let setSiriAction: (ButtonAction) -> Void
    let setIdleTimeout: (RemoteIdleTimeout) -> Void
    private var layout: RemoteSettingsLayout { RemoteSettingsLayout(generation: model.snapshot.generation) }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 24) {
                HStack(alignment: .top, spacing: 0) {
                    callouts(layout.left, side: .left)
                    RemoteArtwork(generation: model.snapshot.generation)
                        .frame(width: layout.artworkWidth, height: 398)
                        .accessibilityLabel(model.snapshot.generation.displayName)
                    callouts(layout.right, side: .right)
                }
                VStack(spacing: 7) {
                    Text(model.snapshot.generation.displayName)
                        .font(.system(size: 13, weight: .medium))
                    HStack(spacing: 6) {
                        Circle().fill(model.snapshot.connected ? Color.green : Color.secondary).frame(width: 6, height: 6)
                        Text(model.snapshot.connectionText).font(.system(size: 11, design: .monospaced))
                    }.foregroundStyle(.secondary)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("settings.connection")
                    Text("Remote controls")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            .frame(width: 556)
            .frame(maxHeight: .infinity)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Settings").font(.system(size: 22, weight: .semibold))
                    VStack(alignment: .leading, spacing: 14) {
                        sectionTitle("Controls")
                        HStack {
                            Text("Siri Button")
                            Spacer()
                            SiriActionPopUp(action: model.snapshot.siriAction, onSelect: setSiriAction)
                                .frame(width: 190, height: 32)
                        }
                        Text("Other button actions are fixed.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        sectionTitle("Text cursor")
                        Text("Press the center button to position the cursor. Slide to move, then press again to confirm.")
                        Text("Siri or Return exits without dictating or submitting. An active text field is required.")
                            .foregroundStyle(.secondary)
                    }.font(.system(size: 12))
                    Divider()
                    VStack(alignment: .leading, spacing: 12) {
                        sectionTitle("Connection")
                        HStack {
                            Text("Auto disconnect")
                            Spacer()
                            Picker("Auto disconnect", selection: Binding(get: { model.snapshot.idleTimeout }, set: setIdleTimeout)) {
                                ForEach(RemoteIdleTimeout.allCases, id: \.self) { value in Text(value.title).tag(value) }
                            }.labelsHidden().pickerStyle(.menu).fixedSize()
                                .accessibilityIdentifier("settings.idleTimeout")
                        }
                        Text("Disconnect after inactivity.")
                            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .font(.system(size: 13))
                .padding(28)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 13, weight: .semibold))
    }



    private enum Side { case left, right }
    private func callouts(_ items: [RemoteSettingsLayout.Callout], side: Side) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(items) { item in
                callout(item.key, side: side).offset(y: item.centerY - 17)
            }
        }.frame(width: 180, height: 398, alignment: .topLeading)
    }

    private func callout(_ key: String, side: Side) -> some View {
        let title = RemoteSettingsGuide.title(for: key, snapshot: model.snapshot)
        return HStack(spacing: 8) {
            if side == .right { connector }
            Text(title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                .frame(width: 136, alignment: side == .left ? .trailing : .leading)
            if side == .left { connector }
        }
        .frame(height: 34)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityIdentifier("settings.guide.\(key)")
    }

    private var connector: some View {
        Rectangle().fill(Color.primary.opacity(0.18)).frame(width: 36, height: 1)
    }
}

/// Draw the original photo at its reference scale, clipping only the surrounding
/// white canvas. Native image drawing also renders reliably in offscreen previews.
@MainActor
private struct RemoteArtwork: NSViewRepresentable {
    let generation: RemoteGeneration
    func makeNSView(context: Context) -> ArtworkView { ArtworkView() }
    func updateNSView(_ nsView: ArtworkView, context: Context) {
        nsView.configure(generation: generation)
    }

    final class ArtworkView: NSView {
        private var resourceName = ""
        private var image: NSImage?
        private var isFirstGeneration = false

        func configure(generation: RemoteGeneration) {
            let layout = RemoteSettingsLayout(generation: generation)
            guard resourceName != layout.resourceName else { return }
            resourceName = layout.resourceName
            isFirstGeneration = generation == .glassTouchSurface
            image = SettingsAssets.bundle.url(forResource: resourceName, withExtension: "png")
                .flatMap { NSImage(contentsOf: $0) }
            needsDisplay = true
        }

        override var intrinsicContentSize: NSSize { NSSize(width: 104, height: 398) }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1.2, dy: 1.5), xRadius: 21, yRadius: 21).addClip()
            NSGraphicsContext.current?.imageInterpolation = .high
            if isFirstGeneration {
                image?.draw(in: bounds)
                return
            }
            image?.draw(in: NSRect(
                x: (bounds.width - 476) / 2,
                y: (bounds.height - 476) / 2,
                width: 476,
                height: 476
            ))
        }
    }
}

/// NSPopUpButton supplies keyboard navigation, VoiceOver and the system appearance.
/// Only the Siri button exposes an editable action menu.
@MainActor
private struct SiriActionPopUp: NSViewRepresentable {
    let action: ButtonAction
    let onSelect: (ButtonAction) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

    func makeNSView(context: Context) -> GlassMappingView {
        let button = SizedPopUpButton(frame: .zero, pullsDown: false)
        button.bezelStyle = .rounded
        button.isBordered = false
        button.controlSize = .large
        button.font = .systemFont(ofSize: 13)
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectAction(_:))
        button.identifier = NSUserInterfaceItemIdentifier("siri")
        button.setAccessibilityIdentifier("settings.mapping.siri")
        button.setAccessibilityLabel("Siri Button")
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let glass = GlassMappingView(button: button)
        updateNSView(glass, context: context)
        return glass
    }

    func updateNSView(_ glass: GlassMappingView, context: Context) {
        let button = glass.button
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

    final class GlassMappingView: NSGlassEffectView {
        let button: NSPopUpButton

        init(button: NSPopUpButton) {
            self.button = button
            super.init(frame: NSRect(x: 0, y: 0, width: 148, height: 36))
            style = .regular
            cornerRadius = 18
            effectIsInteractive = true
            let controls = NSView()
            contentView = controls
            controls.translatesAutoresizingMaskIntoConstraints = false
            button.translatesAutoresizingMaskIntoConstraints = false
            controls.addSubview(button)
            NSLayoutConstraint.activate([
                controls.leadingAnchor.constraint(equalTo: leadingAnchor),
                controls.trailingAnchor.constraint(equalTo: trailingAnchor),
                controls.topAnchor.constraint(equalTo: topAnchor),
                controls.bottomAnchor.constraint(equalTo: bottomAnchor),
                button.leadingAnchor.constraint(equalTo: controls.leadingAnchor, constant: 10),
                button.trailingAnchor.constraint(equalTo: controls.trailingAnchor, constant: -10),
                button.topAnchor.constraint(equalTo: controls.topAnchor),
                button.bottomAnchor.constraint(equalTo: controls.bottomAnchor)
            ])
        }

        required init?(coder: NSCoder) { nil }
    }

    private final class SizedPopUpButton: NSPopUpButton {
        // Explanations in the menu can be longer than the selected title. Do not let
        // the longest menu item widen a button into the neighboring connector/photo.
        override var intrinsicContentSize: NSSize { NSSize(width: 148, height: 36) }
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
