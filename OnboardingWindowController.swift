import AppKit
import SwiftUI

/// Completion is recorded only after Finish; closing the guide never changes a mapping.
enum OnboardingState {
    static let completionKey = "onboardingCompletedVersion"
    static func needsPresentation(defaults: UserDefaults = .standard) -> Bool {
        if defaults.integer(forKey: completionKey) >= 1 { return false }
        // Existing installations already have a chosen mapping or bridge configuration.
        // Migrate them quietly; the guide remains available from Settings.
        if defaults.object(forKey: "siriButtonAction") != nil || defaults.object(forKey: "microphoneBridgeEngine") != nil {
            defaults.set(1, forKey: completionKey)
            return false
        }
        return true
    }
    static func complete(action: ButtonAction, defaults: UserDefaults = .standard) -> Bool {
        guard action.isAssignableToSiriButton else { return false }
        defaults.set(action.rawValue, forKey: "siriButtonAction")
        defaults.set(1, forKey: completionKey)
        return true
    }
}

struct OnboardingAccess: Equatable {
    var bluetooth = false
    var input = false
    var accessibility = false
}

@MainActor
final class OnboardingModel: ObservableObject {
    @Published var step = 0
    @Published var action: ButtonAction
    @Published var snapshot: RemoteSettingsSnapshot
    @Published var access: OnboardingAccess
    init(snapshot: RemoteSettingsSnapshot, access: OnboardingAccess) {
        self.snapshot = snapshot; self.action = snapshot.siriAction; self.access = access
    }
}

@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private let model: OnboardingModel
    init(snapshot: RemoteSettingsSnapshot, access: OnboardingAccess,
         requestBluetooth: @escaping () -> Void, requestInput: @escaping () -> Void,
         requestAccessibility: @escaping () -> Void, finish: @escaping (ButtonAction) -> Void) {
        model = OnboardingModel(snapshot: snapshot, access: access)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Welcome to VibeRemote"
        window.identifier = .init("VibeRemote.Onboarding")
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: OnboardingView(
            model: model, requestBluetooth: requestBluetooth, requestInput: requestInput,
            requestAccessibility: requestAccessibility, finish: { [weak self] action in
                guard OnboardingState.complete(action: action) else { return }
                finish(action)
                self?.close()
            }))
        window.center()
    }
    required init?(coder: NSCoder) { nil }
    func show() {
        NSApp.setActivationPolicy(.regular)
        showWindow(nil); window?.deminiaturize(nil)
        NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil)
    }
    func update(snapshot: RemoteSettingsSnapshot, access: OnboardingAccess) {
        model.snapshot = snapshot; model.access = access
    }
    func windowWillClose(_ notification: Notification) {
        restoreAccessoryPolicy(closing: window)
    }
}

@MainActor
func restoreAccessoryPolicy(closing window: NSWindow?) {
    let setupIDs = ["VibeRemote.Settings", "VibeRemote.Onboarding"]
    let otherWindow = NSApp.windows.contains {
        $0 !== window && ($0.isVisible || $0.isMiniaturized) && setupIDs.contains($0.identifier?.rawValue ?? "")
    }
    if !otherWindow { NSApp.setActivationPolicy(.accessory) }
}

enum OnboardingPage: Equatable {
    case connection
    case button(String)
    case siri

    static func pages(for generation: RemoteGeneration) -> [OnboardingPage] {
        let keys = generation == .glassTouchSurface
            ? ["touch.edit", "select", "back", "tv", "playPause", "volumeUp", "volumeDown"]
            : ["touch.edit", "select", "back", "tv", "playPause", "mute", "power", "volumeUp", "volumeDown"]
        return [.connection] + keys.map { .button($0) } + [.siri]
    }
}

@MainActor
struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    let requestBluetooth: () -> Void
    let requestInput: () -> Void
    let requestAccessibility: () -> Void
    let finish: (ButtonAction) -> Void
    private var pages: [OnboardingPage] { OnboardingPage.pages(for: model.snapshot.generation) }
    private var index: Int { min(model.step, pages.count - 1) }
    private var page: OnboardingPage { pages[index] }
    private var key: String? {
        switch page { case .connection: return nil; case .siri: return "siri"; case .button(let key): return key }
    }
    private var sectionLabel: String {
        guard let key else { return "WELCOME" }
        if page == .siri { return "YOUR SHORTCUT" }
        if key == "touch.edit" { return model.snapshot.generation == .glassTouchSurface ? "TOUCH SURFACE" : "CLICKPAD" }
        if key == "select" { return model.snapshot.generation == .glassTouchSurface ? "SURFACE PRESS" : "CENTER PRESS" }
        return remoteButtonDescriptors.first { $0.key == key }?.label.uppercased() ?? "BUTTON GUIDE"
    }
    private var title: String {
        switch page {
        case .connection: return "Make the connection."
        case .siri: return "Make Siri yours."
        case .button("touch.edit"): return "Move through your words."
        case .button("select"): return "Put the cursor in place."
        case .button(let key):
            return RemoteButtonMapping.action(button: key, generation: model.snapshot.generation, siriAction: model.action).settingsTitle
        }
    }
    private var detail: String {
        guard case .button(let key) = page else { return "" }
        if key == "touch.edit" { return "Press the edges for arrow keys. Slide across the touch surface to position the text cursor." }
        if key == "select" {
            return model.snapshot.generation == .glassTouchSurface
                ? "Press the touch surface to confirm a cursor position. Outside cursor positioning, a press sends Enter."
                : "Press the center to confirm your cursor position. Outside cursor positioning, the center is reserved."
        }
        let action = RemoteButtonMapping.action(button: key, generation: model.snapshot.generation, siriAction: model.action)
        switch action {
        case .backspace: return "Press Back to delete one word. Keep holding to delete more words."
        case .shiftEnter: return "Press TV to add a new line without sending your message."
        case .skillPicker: return "Open the skill picker in the focused app: $ in Codex, / in Claude and other apps."
        case .advancedMenu: return "Press to open Advanced Menu for extra actions, including stopping a task and clearing your input."
        case .enterKey: return "Press Power to send Enter. In Advanced Menu, it sends Command–Enter."
        case .bulletIndent: return "Press Volume Up to start a list in Codex, or indent the current list item."
        case .bulletOutdent: return "Press Volume Down to outdent a list item. At the outer level, it removes the list."
        case .shiftEnterOrModifier: return "Press TV for a new line. Hold it to use the remote’s modifier shortcuts."
        case .agentClientOrSlash: return "Press to bring Codex or Claude forward. Hold to type the skill-picker shortcut."
        default: return action.actionDescription
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color(red: 0.47, green: 0.74, blue: 0.90)
                if let url = SettingsAssets.bundle.url(forResource: "OnboardingSky", withExtension: "png"),
                   let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).resizable().scaledToFill()
                }
                OnboardingRemoteIllustration(generation: model.snapshot.generation, highlighted: key)
                    .frame(width: 440, height: 285)
                    .padding(.top, 24)
                    .allowsHitTesting(false)
            }
            .frame(width: 560, height: 330).clipped()
            .accessibilityLabel(key == nil ? "Siri Remote" : "Highlighted remote control")

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(sectionLabel)
                        .font(.system(size: 10, weight: .semibold)).tracking(1.6).foregroundStyle(.secondary)
                    Text(title).font(.system(size: 27, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    switch page {
                    case .connection:
                        HStack {
                            Text(model.snapshot.connected ? "Your remote is connected." : "Pair your remote to get started.")
                            Spacer()
                            Button("Bluetooth Settings") {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!)
                            }
                        }
                        VStack(spacing: 8) {
                            permission("Bluetooth", ready: model.access.bluetooth, action: requestBluetooth)
                            permission("Input Monitoring", ready: model.access.input, action: requestInput)
                            permission("Accessibility", ready: model.access.accessibility, action: requestAccessibility)
                        }
                    case .siri:
                        Text("Choose the shortcut used by your dictation app.").foregroundStyle(.secondary)
                        HStack {
                            Text("Siri Button")
                            Spacer()
                            SiriActionPopUp(action: model.action, onSelect: { model.action = $0 })
                                .frame(width: 220, height: 36)
                        }
                        Text(model.action.requiresHold ? "Hold Siri to press this key. Release to finish." : "Siri will perform the selected action.")
                            .foregroundStyle(.secondary)
                    case .button:
                        Text(detail).font(.system(size: 15)).lineSpacing(5).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading).padding(30)
            }
            HStack {
                Button("Back") { model.step = max(0, index - 1) }
                    .disabled(index == 0).accessibilityIdentifier("onboarding.back")
                Spacer()
                Text("\(index + 1) / \(pages.count)").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                Button(page == .siri ? "Get started" : "Continue") {
                    if page == .siri { finish(model.action) } else { model.step = index + 1 }
                }.keyboardShortcut(.defaultAction).accessibilityIdentifier("onboarding.continue")
            }.padding(.horizontal, 30).padding(.bottom, 24).padding(.top, 12)
        }.frame(width: 560, height: 700).ignoresSafeArea(edges: .top)
    }
    private func permission(_ title: String, ready: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Text(title); Spacer()
            if ready { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Allowed") }
            else { Button("Allow", action: action).accessibilityLabel("Allow \(title)") }
        }
    }
}

/// The guide reuses the exact CAD asset and has no hardware ownership or idle animation.
@MainActor
private struct OnboardingRemoteIllustration: NSViewRepresentable {
    let generation: RemoteGeneration
    let highlighted: String?
    func makeNSView(context: Context) -> RemoteModelNSView { RemoteModelNSView() }
    func updateNSView(_ view: RemoteModelNSView, context: Context) {
        view.configure(generation: generation)
        view.applyHighlight(highlighted == "touch.edit" && generation == .glassTouchSurface ? "select" : highlighted)
    }
    static func dismantleNSView(_ view: RemoteModelNSView, coordinator: ()) { view.scene = nil }
}
