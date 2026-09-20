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
    var interactionMode: RemoteInteractionMode = .audio
    var modeSwitchButtons: Set<String> = []

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
            left = [.init(key: "back", centerY: 146), .init(key: "playPause", centerY: 192), .init(key: "mute", centerY: 238)]
            right = [.init(key: "power", centerY: 18), .init(key: "siri", centerY: 82), .init(key: "tv", centerY: 144), .init(key: "volumeUp", centerY: 186), .init(key: "volumeDown", centerY: 236)]
        }
    }
}

extension ButtonAction {
    var settingsTitle: String {
        switch self {
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
        case .none: return "None"
        case .toggleInteractionMode: return "Touch / Audio"
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
    private static let modeIdentifier = NSToolbarItem.Identifier("VibeRemote.InteractionMode")
    private var modeItems: [NSMenuItem] = []
    private let setInteractionMode: (RemoteInteractionMode) -> Void
    private static let moreIdentifier = NSToolbarItem.Identifier("VibeRemote.MoreSettings")
    private let model: RemoteSettingsModel
    private let setSiriAction: (ButtonAction) -> Void
    private let resetSiriAction: () -> Void
    private var resetItem: NSMenuItem?
    private let audioSettingsMenu: NSMenu?

    init(
        snapshot: RemoteSettingsSnapshot,
        setSiriAction: @escaping (ButtonAction) -> Void,
        resetSiriAction: @escaping () -> Void,
        setModeSwitch: @escaping (String, Bool) -> Void = { _, _ in },
        setInteractionMode: @escaping (RemoteInteractionMode) -> Void = { _ in },
        audioSettingsMenu: NSMenu? = nil
    ) {
        model = RemoteSettingsModel(snapshot: snapshot)
        self.setSiriAction = setSiriAction
        self.resetSiriAction = resetSiriAction
        self.setInteractionMode = setInteractionMode
        self.audioSettingsMenu = audioSettingsMenu
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 722, height: 548),
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
        window.setFrameAutosaveName("VibeRemote.Settings")
        let hosting = NSHostingController(rootView: RemoteSettingsView(
            model: model,
            setSiriAction: setSiriAction,
            setModeSwitch: setModeSwitch
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
        window.setContentSize(NSSize(width: 722, height: 548))
        // Preserve the existing outer window size, extending only the backdrop beneath
        // the native toolbar. Controls stay within the unobscured safe area above.
        window.styleMask.insert(.fullSizeContentView)
        if !window.setFrameUsingName("VibeRemote.Settings") {
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
        resetItem?.isEnabled = snapshot.siriAction != defaultAction || !snapshot.modeSwitchButtons.isEmpty
        for item in audioSettingsMenu?.items ?? [] where item.representedObject is String {
            item.state = item.representedObject as? String == (UserDefaults.standard.string(forKey: "audioOutputBackend") ?? "shared") ? .on : .off
        }
        for item in modeItems { item.state = item.representedObject as? String == snapshot.interactionMode.rawValue ? .on : .off }
    }

    @objc private func selectMode(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let mode = RemoteInteractionMode(rawValue: raw) else { return }
        setInteractionMode(mode)
    }

    @objc private func resetSettings() {
        resetSiriAction()
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.modeIdentifier, .flexibleSpace, Self.moreIdentifier]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        if itemIdentifier == Self.modeIdentifier {
            let item = NSMenuToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Mode"; item.toolTip = "Audio or touch mode"
            item.image = NSImage(systemSymbolName: "hand.draw", accessibilityDescription: "Interaction mode")
            item.isBordered = true; item.autovalidates = false
            let menu = NSMenu(title: "Mode"); menu.autoenablesItems = false
            modeItems = RemoteInteractionMode.allCases.map { mode in
                let entry = NSMenuItem(title: mode.title, action: #selector(selectMode(_:)), keyEquivalent: "")
                entry.target = self; entry.representedObject = mode.rawValue
                entry.state = mode == model.snapshot.interactionMode ? .on : .off
                menu.addItem(entry); return entry
            }
            item.menu = menu; return item
        }
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
        reset.toolTip = "Restore Siri to Space and Play/Pause and Mute to their original actions."
        menu.addItem(reset)
        if let audioSettingsMenu {
            menu.addItem(.separator())
            let audio = NSMenuItem(title: "Audio Output", action: nil, keyEquivalent: "")
            audio.submenu = audioSettingsMenu; menu.addItem(audio)
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
    let setModeSwitch: (String, Bool) -> Void

    private var layout: RemoteSettingsLayout { RemoteSettingsLayout(generation: model.snapshot.generation) }

    var body: some View {
        VStack(spacing: 36) {
            HStack(alignment: .top, spacing: 0) {
                callouts(layout.left, side: .left)
                RemoteArtwork(generation: model.snapshot.generation)
                    .frame(width: layout.artworkWidth, height: 398)
                    .accessibilityLabel(model.snapshot.generation.displayName)
                    .help(model.snapshot.generation == .glassTouchSurface
                          ? "Press the touch surface for Enter. Hold the microphone button below Menu while speaking."
                          : "Clickpad: arrow keys. Press the center for Enter. Hold the side Siri button while speaking.")
                callouts(layout.right, side: .right)
            }
            .padding(.top, 40)

            VStack(spacing: 3) {
                Text(model.snapshot.interactionMode == .touch ? "Touch Control" : model.snapshot.generation.displayName)
                    .font(.system(size: 13, weight: .medium))
                Text(model.snapshot.interactionMode == .touch ? "Slide to move · Tap to click · Two fingers to scroll" : model.snapshot.connectionText)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                    .accessibilityIdentifier("settings.connection")
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private enum Side { case left, right }

    private func callouts(_ items: [RemoteSettingsLayout.Callout], side: Side) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(items.filter { model.snapshot.interactionMode == .audio || RemoteModeSwitchMapping.eligibleButtons.contains($0.key) }) { item in
                mapping(item.key, side: side)
                    .offset(y: item.centerY - 18)
            }
        }
        .frame(width: 236, height: 398, alignment: .topLeading)
    }


    private func mapping(_ key: String, side: Side) -> some View {
        let descriptor = remoteButtonDescriptors.first { $0.key == key }!
        let baseline = model.snapshot.generation.action(for: key, defaultAction: descriptor.defaultAction, siriAction: model.snapshot.siriAction)
        let action = RemoteModeSwitchMapping.action(button: key, defaultAction: baseline, enabled: model.snapshot.modeSwitchButtons)
        return HStack(spacing: 8) {
            if side == .right { VStack { Divider() }.frame(width: 80) }
            MappingPopUp(
                descriptor: descriptor,
                action: action,
                defaultAction: baseline,
                onSelect: { selected in
                    if key == "siri" { setSiriAction(selected) }
                    else { setModeSwitch(key, selected == .toggleInteractionMode) }
                }
            )
            .frame(width: 148, height: 36)
            if side == .left { VStack { Divider() }.frame(width: 80) }
        }
        .frame(height: 36)
        .opacity(model.snapshot.generation.absentButtonKeys.contains(key) ? 0 : 1)
        .allowsHitTesting(!model.snapshot.generation.absentButtonKeys.contains(key))
        .accessibilityHidden(model.snapshot.generation.absentButtonKeys.contains(key))
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
/// Fixed buttons expose their action/hold explanation, not editable mapping options.
@MainActor
private struct MappingPopUp: NSViewRepresentable {
    let descriptor: RemoteButtonDescriptor
    let action: ButtonAction
    let defaultAction: ButtonAction
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
        button.identifier = NSUserInterfaceItemIdentifier(descriptor.key)
        button.setAccessibilityIdentifier("settings.mapping.\(descriptor.key)")
        button.setAccessibilityLabel(descriptor.label)
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let glass = GlassMappingView(button: button)
        updateNSView(glass, context: context)
        return glass
    }

    func updateNSView(_ glass: GlassMappingView, context: Context) {
        let button = glass.button
        context.coordinator.onSelect = onSelect
        let modeSwitch = RemoteModeSwitchMapping.eligibleButtons.contains(descriptor.key)
        let editable = descriptor.key == "siri" || modeSwitch
        let actions = descriptor.key == "siri" ? ButtonAction.allCases.filter(\.isAssignableToSiriButton)
            : (modeSwitch ? [defaultAction, .toggleInteractionMode] : [action])
        button.toolTip = "\(descriptor.label)\n\(action.actionDescription)"
        // Rebuild only when the choice changes; status/battery updates must not dismiss
        // an open native menu or reset its keyboard selection.
        if button.selectedItem?.representedObject as? String == action.rawValue,
           button.itemArray.compactMap({ $0.representedObject as? String }) == actions.map(\.rawValue) { return }
        button.removeAllItems()
        for option in actions {
            button.addItem(withTitle: editable ? option.settingsTitle : option.actionDescription)
            button.lastItem?.representedObject = option.rawValue
            button.lastItem?.toolTip = option.actionDescription
        }
        button.selectItem(at: actions.firstIndex(of: action) ?? 0)
        if !editable {
            // Keep the compact label on the glass control, while its menu contains the
            // complete explanation exactly once. This display item is not a menu entry.
            if let cell = button.cell as? NSPopUpButtonCell {
                cell.usesItemFromMenu = false
                cell.menuItem = NSMenuItem(title: action.settingsTitle, action: nil, keyEquivalent: "")
            }
        }
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
            guard let key = sender.identifier?.rawValue,
                  key == "siri" || RemoteModeSwitchMapping.eligibleButtons.contains(key) else { return }
            guard let raw = sender.selectedItem?.representedObject as? String,
                  let action = ButtonAction(rawValue: raw) else { return }
            onSelect(action)
        }
    }
}
