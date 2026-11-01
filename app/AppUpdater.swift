import AppKit
import Combine
import Sparkle

@MainActor
final class AppUpdater: NSObject, ObservableObject, NSMenuItemValidation, NSToolbarItemValidation, SPUStandardUserDriverDelegate {
    static let shared = AppUpdater()
    @Published private(set) var canCheck = false
    @Published private(set) var updateAvailable = false
    private var controller: SPUStandardUpdaterController?

    func start() {
        guard controller == nil, Bundle.main.bundleURL.pathExtension == "app" else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: self)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main).assign(to: &$canCheck)
        // Automatic checks are mandatory, including for existing opted-out installs.
        controller.updater.automaticallyChecksForUpdates = true
        controller.startUpdater()
    }

    @objc func checkForUpdates(_ sender: Any? = nil) {
        guard canCheck || updateAvailable else { return }
        controller?.checkForUpdates(sender)
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool { canCheck || updateAvailable }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { canCheck || updateAvailable }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool { false }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        updateAvailable = true
    }

    func standardUserDriverWillFinishUpdateSession() {
        updateAvailable = false
    }

    func makeMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        item.target = self
        item.isEnabled = canCheck
        return item
    }
}
