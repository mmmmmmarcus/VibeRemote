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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 520),
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

@MainActor
struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    let requestBluetooth: () -> Void
    let requestInput: () -> Void
    let requestAccessibility: () -> Void
    let finish: (ButtonAction) -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 12)
            Image(systemName: ["appletvremote.gen4", "link", "mic"][model.step])
                .font(.system(size: 44, weight: .light)).frame(height: 54)
                .accessibilityHidden(true)
            Text(["Your remote. Your Mac.", "Connect your remote", "Make Siri yours"][model.step])
                .font(.system(size: 28, weight: .semibold))
            Group {
                switch model.step {
                case 0:
                    VStack(alignment: .leading, spacing: 18) {
                        Label("Navigate, edit and send from your remote.", systemImage: "arrow.up.arrow.down")
                        Label("Slide to position the text cursor. Press to confirm.", systemImage: "cursorarrow")
                        Label("Hold Siri to use your dictation shortcut.", systemImage: "mic")
                    }
                case 1:
                    VStack(spacing: 12) {
                        HStack {
                            Label(model.snapshot.connected ? "Remote connected" : "Pair in Bluetooth Settings", systemImage: "appletvremote.gen4")
                            Spacer()
                            Button("Open Bluetooth") {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!)
                            }
                        }
                        Divider()
                        permission("Bluetooth", ready: model.access.bluetooth, action: requestBluetooth)
                        permission("Input Monitoring", ready: model.access.input, action: requestInput)
                        permission("Accessibility", ready: model.access.accessibility, action: requestAccessibility)
                    }
                default:
                    VStack(spacing: 22) {
                        Text("Choose the shortcut used by your dictation app.")
                            .foregroundStyle(.secondary)
                        HStack {
                            Text("Siri Button")
                            Spacer()
                            SiriActionPopUp(action: model.action, onSelect: { model.action = $0 })
                                .frame(width: 220, height: 36)
                        }
                        Text(model.action.requiresHold ? "Hold Siri to press this key. Release to finish." : "Siri will perform the selected action.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            .font(.system(size: 14)).frame(maxWidth: 460, minHeight: 180)
            Spacer(minLength: 0)
            HStack {
                if model.step > 0 {
                    Button("Back") { model.step -= 1 }.accessibilityIdentifier("onboarding.back")
                }
                Spacer()
                Text("\(model.step + 1) of 3").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button(model.step == 2 ? "Get started" : "Continue") {
                    if model.step == 2 { finish(model.action) } else { model.step += 1 }
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("onboarding.continue")
            }
        }
        .padding(36).frame(width: 660, height: 520)
    }
    private func permission(_ title: String, ready: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Text(title); Spacer()
            if ready { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Allowed") }
            else { Button("Allow", action: action).accessibilityLabel("Allow \(title)") }
        }
    }
}
