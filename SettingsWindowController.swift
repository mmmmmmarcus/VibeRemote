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

    var connectionText: String {
        guard connected else { return "DISCONNECTED" }
        guard let batteryPercent, (0...100).contains(batteryPercent) else {
            return "CONNECTED — BATTERY UNKNOWN"
        }
        return "CONNECTED \(batteryPercent)%"
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
final class SettingsWindowController: NSWindowController, NSToolbarDelegate {
    private static let resetIdentifier = NSToolbarItem.Identifier("VibeRemote.ResetSettings")
    private let model: RemoteSettingsModel
    private let setSiriAction: (ButtonAction) -> Void
    private let resetSiriAction: () -> Void
    private var resetItem: NSToolbarItem?

    init(
        snapshot: RemoteSettingsSnapshot,
        setSiriAction: @escaping (ButtonAction) -> Void,
        resetSiriAction: @escaping () -> Void
    ) {
        model = RemoteSettingsModel(snapshot: snapshot)
        self.setSiriAction = setSiriAction
        self.resetSiriAction = resetSiriAction
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 722, height: 548),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        window.title = "Vibe Remote"
        window.identifier = NSUserInterfaceItemIdentifier("VibeRemote.Settings")
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unified
        window.setFrameAutosaveName("VibeRemote.Settings")
        window.contentViewController = NSHostingController(rootView: RemoteSettingsView(
            model: model,
            setSiriAction: setSiriAction
        ))

        let toolbar = NSToolbar(identifier: "VibeRemote.SettingsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .labelOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.setContentSize(NSSize(width: 722, height: 548))
        if !window.setFrameUsingName("VibeRemote.Settings") {
            window.center()
        }
        update(snapshot)
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        showWindow(nil)
        window?.deminiaturize(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        rmDebug("⚙️ Settings window visible=\(window?.isVisible == true)")
    }

    func update(_ snapshot: RemoteSettingsSnapshot) {
        if model.snapshot != snapshot { model.snapshot = snapshot }
        let defaultAction = remoteButtonDescriptors.first { $0.key == "siri" }?.defaultAction ?? .spaceKey
        resetItem?.isEnabled = snapshot.siriAction != defaultAction
    }

    @objc private func resetSettings() {
        resetSiriAction()
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.resetIdentifier]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard itemIdentifier == Self.resetIdentifier else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = "Reset"
        item.target = self
        item.action = #selector(resetSettings)
        item.autovalidates = false
        item.toolTip = "Restore the Siri button to Space. Fixed mappings are unchanged."
        resetItem = item
        return item
    }
}

@MainActor
private struct RemoteSettingsView: View {
    @ObservedObject var model: RemoteSettingsModel
    let setSiriAction: (ButtonAction) -> Void

    // The annotation rows follow the physical buttons in the supplied photograph.
    // Flowing columns preserve native control widths; only the artwork is cropped in
    // its view, leaving the downloaded source image unchanged.
    var body: some View {
        VStack(spacing: 36) {
            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 0) {
                    Spacer().frame(height: 128)
                    mapping("back", side: .left)
                    Spacer().frame(height: 10)
                    mapping("playPause", side: .left)
                    Spacer().frame(height: 10)
                    mapping("mute", side: .left)
                    Spacer(minLength: 0)
                }
                .frame(height: 398)

                RemoteArtwork()
                    .frame(width: 104, height: 398)
                    .accessibilityLabel("Siri Remote")
                    .help("Clickpad: arrow keys. Press the center for Enter. Hold the side Siri button while speaking.")

                VStack(spacing: 0) {
                    mapping("power", side: .right)
                    Spacer().frame(height: 28)
                    mapping("siri", side: .right)
                    Spacer().frame(height: 26)
                    mapping("tv", side: .right)
                    Spacer().frame(height: 6)
                    mapping("volumeUp", side: .right)
                    Spacer().frame(height: 14)
                    mapping("volumeDown", side: .right)
                    Spacer(minLength: 0)
                }
                .frame(height: 398)
            }
            .padding(.top, 40)

            VStack(spacing: 3) {
                Text("Siri Remote")
                    .font(.system(size: 13, weight: .medium))
                Text(model.snapshot.connectionText)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                    .accessibilityIdentifier("settings.connection")
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.textBackgroundColor))
    }

    private enum Side { case left, right }

    private func mapping(_ key: String, side: Side) -> some View {
        let descriptor = remoteButtonDescriptors.first { $0.key == key }!
        let action = key == "siri" ? model.snapshot.siriAction : descriptor.defaultAction
        return HStack(spacing: 8) {
            if side == .right { VStack { Divider() }.frame(width: 80) }
            MappingPopUp(
                descriptor: descriptor,
                action: action,
                onSelect: setSiriAction
            )
            .frame(width: 148, height: 36)
            if side == .left { VStack { Divider() }.frame(width: 80) }
        }
        .frame(height: 36)
    }
}

/// Draw the original photo at its reference scale, clipping only the surrounding
/// white canvas. Native image drawing also renders reliably in offscreen previews.
@MainActor
private struct RemoteArtwork: NSViewRepresentable {
    func makeNSView(context: Context) -> ArtworkView { ArtworkView() }
    func updateNSView(_ nsView: ArtworkView, context: Context) {}

    final class ArtworkView: NSView {
        private let image: NSImage? = SettingsAssets.bundle.url(forResource: "SiriRemote", withExtension: "png")
            .flatMap { NSImage(contentsOf: $0) }

        override var intrinsicContentSize: NSSize { NSSize(width: 104, height: 398) }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1.2, dy: 1.5), xRadius: 21, yRadius: 21).addClip()
            NSGraphicsContext.current?.imageInterpolation = .high
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
    let onSelect: (ButtonAction) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = SizedPopUpButton(frame: .zero, pullsDown: false)
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.font = .systemFont(ofSize: 13)
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectAction(_:))
        button.identifier = NSUserInterfaceItemIdentifier(descriptor.key)
        button.setAccessibilityIdentifier("settings.mapping.\(descriptor.key)")
        button.setAccessibilityLabel(descriptor.label)
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        updateNSView(button, context: context)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.onSelect = onSelect
        let editable = descriptor.key == "siri"
        let actions = editable ? ButtonAction.allCases : [action]
        button.toolTip = "\(descriptor.label)\n\(action.actionDescription)" + (editable ? "" : "\nFixed mapping")
        // Rebuild only when the choice changes; status/battery updates must not dismiss
        // an open native menu or reset its keyboard selection.
        if button.selectedItem?.representedObject as? String == action.rawValue,
           button.numberOfItems > 0 { return }
        button.removeAllItems()
        for option in actions {
            button.addItem(withTitle: option.settingsTitle)
            button.lastItem?.representedObject = option.rawValue
            button.lastItem?.toolTip = option.actionDescription
        }
        button.selectItem(at: actions.firstIndex(of: action) ?? 0)
        if !editable {
            button.menu?.addItem(.separator())
            let detail = NSMenuItem(title: action.actionDescription, action: nil, keyEquivalent: "")
            detail.isEnabled = false
            button.menu?.addItem(detail)
            let fixed = NSMenuItem(title: "Fixed mapping", action: nil, keyEquivalent: "")
            fixed.isEnabled = false
            button.menu?.addItem(fixed)
        }
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
            guard sender.identifier?.rawValue == "siri" else { return }
            guard let raw = sender.selectedItem?.representedObject as? String,
                  let action = ButtonAction(rawValue: raw) else { return }
            onSelect(action)
        }
    }
}
