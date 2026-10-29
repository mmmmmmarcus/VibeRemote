import AppKit
import Combine
import Sparkle

@MainActor
final class AppUpdater: NSObject, ObservableObject, NSMenuItemValidation, NSToolbarItemValidation {
    static let shared = AppUpdater()
    @Published private(set) var canCheck = false
    @Published private(set) var automaticallyChecks = false
    private var controller: SPUStandardUpdaterController?

    func start() {
        guard controller == nil, Bundle.main.bundleURL.pathExtension == "app" else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main).assign(to: &$canCheck)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates)
            .receive(on: RunLoop.main).assign(to: &$automaticallyChecks)
        controller.startUpdater()
    }

    func setAutomaticallyChecks(_ enabled: Bool) {
        controller?.updater.automaticallyChecksForUpdates = enabled
    }

    @objc func checkForUpdates(_ sender: Any? = nil) {
        guard canCheck else { return }
        controller?.checkForUpdates(sender)
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool { canCheck }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { canCheck }

    func makeMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        item.target = self
        item.isEnabled = canCheck
        return item
    }
}
