import XCTest
import SwiftUI
@testable import VibeRemote

final class OnboardingTests: XCTestCase {
    private func isolatedDefaults() -> UserDefaults {
        let name = "VibeRemote.OnboardingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return defaults
    }

    func testFirstRunRemainsPendingUntilAnAssignableMappingIsConfirmed() {
        let defaults = isolatedDefaults()
        XCTAssertTrue(OnboardingState.needsPresentation(defaults: defaults))
        XCTAssertFalse(OnboardingState.complete(action: .advancedMenu, defaults: defaults))
        XCTAssertTrue(OnboardingState.needsPresentation(defaults: defaults))
        XCTAssertNil(defaults.string(forKey: "siriButtonAction"))
        XCTAssertTrue(OnboardingState.complete(action: .rightOpt, defaults: defaults))
        XCTAssertEqual(defaults.string(forKey: "siriButtonAction"), ButtonAction.rightOpt.rawValue)
        XCTAssertFalse(OnboardingState.needsPresentation(defaults: defaults))
    }

    func testExistingInstallKeepsItsMappingAndDoesNotForceOnboarding() {
        let defaults = isolatedDefaults()
        defaults.set(ButtonAction.rightCmd.rawValue, forKey: "siriButtonAction")
        XCTAssertFalse(OnboardingState.needsPresentation(defaults: defaults))
        XCTAssertEqual(defaults.string(forKey: "siriButtonAction"), ButtonAction.rightCmd.rawValue)
        XCTAssertEqual(defaults.integer(forKey: OnboardingState.completionKey), 1)
    }

    @MainActor
    func testClosingGuideDoesNotSaveOrCallFinish() throws {
        _ = NSApplication.shared
        var finished = false
        let controller = OnboardingWindowController(
            snapshot: RemoteSettingsSnapshot(connected: false, batteryPercent: nil, siriAction: .rightOpt),
            access: OnboardingAccess(), requestBluetooth: {}, requestInput: {}, requestAccessibility: {},
            finish: { _ in finished = true })
        XCTAssertEqual(controller.window?.identifier?.rawValue, "VibeRemote.Onboarding")
        controller.close()
        XCTAssertFalse(finished)
    }
    @MainActor
    func testGuideLayoutsAcrossStepsAndAppearances() throws {
        guard let directory = ProcessInfo.processInfo.environment["VIBEREMOTE_ONBOARDING_RENDER"] else { return }
        _ = NSApplication.shared
        let model = OnboardingModel(
            snapshot: RemoteSettingsSnapshot(connected: false, batteryPercent: nil, siriAction: .rightOpt),
            access: OnboardingAccess())
        let hosting = NSHostingController(rootView: OnboardingView(model: model,
            requestBluetooth: {}, requestInput: {}, requestAccessibility: {}, finish: { _ in }))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 520),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = hosting
        defer { window.close() }
        let frame = try XCTUnwrap(window.contentView?.superview)
        for step in 0...2 {
            model.step = step
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                window.appearance = NSAppearance(named: appearance)
                frame.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.15))
                let bitmap = try XCTUnwrap(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
                window.effectiveAppearance.performAsCurrentDrawingAppearance {
                    frame.cacheDisplay(in: frame.bounds, to: bitmap)
                }
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("onboarding-\(step)-\(name).png"))
            }
        }
    }

}
