import HelperProtocol
import AppKit
import Carbon.HIToolbox
import XCTest
@testable import VibeRemote

final class ModelTests: XCTestCase {
    func testRapidModeClicksSurviveDelayedHIDReopening() {
        var correlation = RemoteMediaEventCorrelation()
        var presses = RemoteModeSwitchPressTracker()
        var mode = RemoteInteractionMode.touch
        var pendingToggles = 0
        // Three actual clicks arrive while HID opening blocks the main loop. Capture
        // ingestion runs ahead of deferred NX delivery, as in the observed failure.
        let edges: [(Double, Bool)] = [(10, true), (10.075, false), (10.2, true),
                                      (10.275, false), (10.4, true), (10.475, false)]
        for (time, down) in edges {
            correlation.record(button: "playPause", pressed: down, sender: 79, now: time)
        }
        for (time, down) in edges {
            let source = correlation.resolve(button: "playPause", pressed: down, repeating: false, now: time + 0.04)
            XCTAssertEqual(source, 79)
            if let source, presses.handle(device: source, button: "playPause", pressed: down, enabled: true) {
                pendingToggles += 1
            }
        }
        // Apply each release against the then-current mode; never capture a stale target.
        for _ in 0..<pendingToggles { mode = mode.toggled }
        XCTAssertEqual(pendingToggles, 3)
        XCTAssertEqual(mode, .audio)
        XCTAssertNil(correlation.resolve(button: "playPause", pressed: true, repeating: false, now: 10.6))
    }

    func testPassiveModeKeyOwnershipDoesNotDependOnHIDQuarantine() {
        XCTAssertTrue(RemoteModeSwitchMapping.usesPassiveCapture(generation: .aluminumClickpad, packetLogger: true, mediaTap: true))
        XCTAssertTrue(RemoteModeSwitchMapping.usesPassiveCapture(generation: .unknown, packetLogger: true, mediaTap: true))
        XCTAssertFalse(RemoteModeSwitchMapping.usesPassiveCapture(generation: .glassTouchSurface, packetLogger: true, mediaTap: true))
        XCTAssertFalse(RemoteModeSwitchMapping.usesPassiveCapture(generation: .aluminumClickpad, packetLogger: false, mediaTap: true))
        XCTAssertFalse(RemoteModeSwitchMapping.usesPassiveCapture(generation: .aluminumClickpad, packetLogger: true, mediaTap: false))
    }

    func testPacketLoggerButtonMasksSourceAndReplayFiltering() throws {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let now = try XCTUnwrap(f.date(from: "2026-09-20 15:45:27.400"))
        func line(_ mask: String, label: String = "Marcus Siri Remot", handle: String = "4E", stamp: String = "15:45:27.330") -> String {
            "Sep 20 \(stamp)  \(label)  0x00\(handle)  RECV  \(handle) 20 09 00 05 00 04 00 1B 39 00 \(mask)"
        }
        var parser = PacketLoggerButtonParser()
        func feed(_ value: String) -> [PacketLoggerButtonParser.Edge] {
            parser.events(line: value, allowedLabels: ["Marcus Siri Remot"], now: now)
        }
        XCTAssertTrue(feed(line("00 01", label: "Keyboard")).isEmpty)
        XCTAssertTrue(feed(line("00 01", stamp: "15:44:27.330")).isEmpty)
        XCTAssertTrue(feed(line("00 01", stamp: "15:46:27.330")).isEmpty)
        XCTAssertTrue(feed(line("00 01").replacingOccurrences(of: "1B 39", with: "1B 23")).isEmpty)
        XCTAssertTrue(feed(line("00 01").replacingOccurrences(of: "09 00", with: "08 00")).isEmpty)
        XCTAssertTrue(feed(line("00 01") + " ZZ").isEmpty)
        // Main-loop delivery can lag the actual packet during HID reopening. The NX
        // matcher still uses the original event time, not a widened matching window.
        var delayed = PacketLoggerButtonParser()
        XCTAssertEqual(delayed.events(line: line("00 01"), allowedLabels: ["Marcus Siri Remot"], now: now.addingTimeInterval(1)).count, 1)
        XCTAssertTrue(delayed.events(line: line("00 00"), allowedLabels: ["Marcus Siri Remot"], now: now.addingTimeInterval(4)).isEmpty)
        let play = feed(line("00 01"))
        XCTAssertEqual(play.map(\.button), ["playPause"])
        XCTAssertEqual(play.map(\.pressed), [true])
        XCTAssertEqual(play.first?.sender, 0x4f)
        XCTAssertTrue(feed(line("00 01")).isEmpty) // duplicate packet
        XCTAssertEqual(feed(line("80 01")).map(\.button), ["mute"])
        XCTAssertEqual(feed(line("80 00")).map(\.pressed), [false]) // play released, mute held
        XCTAssertEqual(feed(line("00 00")).map(\.button), ["mute"])
        XCTAssertTrue(feed(line("00 00")).isEmpty)
        XCTAssertTrue(feed(line("00 00", handle: "4F")).isEmpty) // another device's orphan release
        XCTAssertEqual(feed(line("00 01", handle: "4F")).first?.sender, 0x50)
    }

    func testPacketCorrelationRejectsLaterOrExpiredObservations() {
        var c = RemoteMediaEventCorrelation()
        c.record(button: "playPause", pressed: true, sender: 1, now: 10.1)
        XCTAssertNil(c.resolve(button: "playPause", pressed: true, repeating: false, now: 10))
        XCTAssertEqual(c.resolve(button: "playPause", pressed: true, repeating: false, now: 10.15), 1)
        XCTAssertNil(c.resolve(button: "playPause", pressed: true, repeating: true, now: 16))
    }

    func testRemoteMediaCorrelationKeepsBothEdgesAndForwardsUnrelatedKeys() {
        var correlation = RemoteMediaEventCorrelation()
        // Source-less events without a remote observation belong to the OS, not our toggle.
        XCTAssertNil(correlation.resolve(button: "playPause", pressed: true, repeating: false, now: 1))
        correlation.record(button: "playPause", pressed: true, sender: 42, now: 2)
        correlation.record(button: "playPause", pressed: false, sender: 42, now: 2.02)
        XCTAssertNil(correlation.resolve(button: "mute", pressed: true, repeating: false, now: 2.06))
        XCTAssertEqual(correlation.resolve(button: "playPause", pressed: true, repeating: false, now: 2.06), 42)
        XCTAssertEqual(correlation.resolve(button: "playPause", pressed: true, repeating: true, now: 2.07), 42)
        XCTAssertEqual(correlation.resolve(button: "playPause", pressed: false, repeating: false, now: 2.08), 42)
        XCTAssertNil(correlation.resolve(button: "playPause", pressed: true, repeating: true, now: 2.09))
        // A consumed marker cannot swallow another device's ordinary press.
        XCTAssertNil(correlation.resolve(button: "playPause", pressed: true, repeating: false, now: 2.1))
        correlation.record(button: "mute", pressed: true, sender: 43, now: 3)
        XCTAssertNil(correlation.resolve(button: "mute", pressed: true, repeating: false, now: 3.3))
    }

    func testModeSwitchMappingsPreserveDefaultsAndOnlyAllowPlayAndMute() throws {
        let suite = "VibeRemoteTests.ModeSwitch.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(RemoteModeSwitchMapping.load(from: defaults), [])
        defaults.set(["siri", "playPause", "mute", "back"], forKey: RemoteModeSwitchMapping.defaultsKey)
        XCTAssertEqual(RemoteModeSwitchMapping.load(from: defaults), ["playPause", "mute"])
        for generation in [RemoteGeneration.glassTouchSurface, .aluminumClickpad] {
            let baseline = generation.action(for: "playPause", defaultAction: .launchAgentClient, siriAction: .rightOpt)
            XCTAssertEqual(RemoteModeSwitchMapping.action(button: "playPause", defaultAction: baseline, enabled: []), baseline)
            XCTAssertEqual(RemoteModeSwitchMapping.action(button: "playPause", defaultAction: baseline, enabled: ["playPause"]), .toggleInteractionMode)
        }
        XCTAssertEqual(RemoteModeSwitchMapping.action(button: "siri", defaultAction: .rightOpt, enabled: ["siri"]), .rightOpt)
        XCTAssertFalse(ButtonAction.toggleInteractionMode.isAssignableToSiriButton)
        XCTAssertEqual(RemoteInteractionMode.audio.toggled, .touch)
        XCTAssertEqual(RemoteInteractionMode.touch.toggled, .audio)
    }

    func testModeSwitchFiresOnceOnCompletePressAndClearsAcrossModes() {
        var tracker = RemoteModeSwitchPressTracker()
        XCTAssertFalse(tracker.handle(device: 1, button: "mute", pressed: false, enabled: true))
        XCTAssertFalse(tracker.handle(device: 1, button: "mute", pressed: true, enabled: true))
        XCTAssertFalse(tracker.handle(device: 1, button: "mute", pressed: true, enabled: true))
        XCTAssertFalse(tracker.handle(device: 2, button: "mute", pressed: false, enabled: true))
        XCTAssertTrue(tracker.handle(device: 1, button: "mute", pressed: false, enabled: true))
        XCTAssertFalse(tracker.handle(device: 1, button: "mute", pressed: false, enabled: true))
        XCTAssertFalse(tracker.handle(device: 1, button: "playPause", pressed: true, enabled: true))
        tracker.reset()
        XCTAssertFalse(tracker.handle(device: 1, button: "playPause", pressed: false, enabled: true))
        XCTAssertFalse(tracker.handle(device: 1, button: "mute", pressed: true, enabled: false))
        XCTAssertFalse(tracker.handle(device: 1, button: "mute", pressed: false, enabled: true))
    }
    func testIdleDisconnectReconnectRecoversUnchangedHIDServices() {
        let first = "60:BE:C4:02:EB:CC"
        let second = "48:A9:1C:91:77:5C"
        // Discovery retains the same IDs across closeConnection; no remove/add callbacks.
        let discovered = [1: first, 2: first, 3: second]
        var opened: Set<Int> = [1, 2, 3]
        var idle = RemoteIdleTracker()
        idle.synchronize(deviceKeys: [first, second], now: 0)
        idle.recordActivity(deviceKey: second, now: 899)
        XCTAssertEqual(idle.takeDueDisconnects(now: 900, timeout: 900), [first])
        opened.subtract([1, 2])
        // The half-second GATT shutdown must finish before any reconciliation can reopen.
        XCTAssertEqual(RemoteInterfaceRecovery.missingInterfaces(
            discovered: discovered, opened: opened, connectedAddresses: [first, second],
            disconnectingAddresses: [first]
        ), [])
        // Cached HID services alone must never reconnect a sleeping remote.
        XCTAssertEqual(RemoteInterfaceRecovery.missingInterfaces(
            discovered: discovered, opened: opened, connectedAddresses: [second],
            disconnectingAddresses: []
        ), [])
        // Bluetooth reconnect (or the watchdog after a missed notification) restores only
        // the released remote. The other remote keeps its handles and held-button state.
        let recovered = RemoteInterfaceRecovery.missingInterfaces(
            discovered: discovered, opened: opened,
            connectedAddresses: ["60-be-c4-02-eb-cc", second], disconnectingAddresses: []
        )
        XCTAssertEqual(recovered, [1, 2])
        opened.formUnion(recovered)
        XCTAssertEqual(RemoteInterfaceRecovery.missingInterfaces(
            discovered: discovered, opened: opened, connectedAddresses: [first, second],
            disconnectingAddresses: []
        ), [])
    }

    func testHIDRecoveryWithNoOpenHandlesRetriesFailedOpenAndIgnoresWiredSerial() {
        let address = "60:BE:C4:02:EB:CC"
        let discovered = [1: address, 2: address, 3: "DJ7YK3PPJ90M"]
        XCTAssertEqual(RemoteInterfaceRecovery.missingInterfaces(
            discovered: discovered, opened: [], connectedAddresses: [address],
            disconnectingAddresses: []
        ), [1, 2])
        // One failed open is retried, even though the other interface now makes isConnected true.
        XCTAssertEqual(RemoteInterfaceRecovery.missingInterfaces(
            discovered: discovered, opened: [1], connectedAddresses: [address],
            disconnectingAddresses: []
        ), [2])
        XCTAssertNil(RemoteInterfaceRecovery.bluetoothAddress("DJ7YK3PPJ90M"))
        XCTAssertNil(RemoteInterfaceRecovery.bluetoothAddress("junk60:BE:C4:02:EB:CC"))
    }

    func testTouchGestureDoesNotClickAfterMovingOrChangingContactCount() {
        var gesture = RemoteTouchGesture()
        XCTAssertNil(gesture.frame(count: 1, x: 0.5, y: 0.5, time: 1))
        XCTAssertEqual(gesture.frame(count: 0, x: 0, y: 0, time: 1.1), .click)
        XCTAssertNil(gesture.frame(count: 1, x: 0.5, y: 0.5, time: 2))
        XCTAssertNotNil(gesture.frame(count: 1, x: 0.6, y: 0.5, time: 2.1))
        XCTAssertNil(gesture.frame(count: 0, x: 0, y: 0, time: 2.2))
        XCTAssertNil(gesture.frame(count: 2, x: 0.5, y: 0.5, time: 3))
        XCTAssertNil(gesture.frame(count: 1, x: 0.5, y: 0.5, time: 3.1))
        XCTAssertNil(gesture.frame(count: 0, x: 0, y: 0, time: 3.2))
        XCTAssertNil(gesture.frame(count: 1, x: 0.1, y: 0.1, time: 4))
        XCTAssertNil(gesture.frame(count: 1, x: 0.9, y: 0.9, time: 4.1))
        XCTAssertNil(gesture.frame(count: 0, x: 0, y: 0, time: 4.2))
    }

    func testRemoteIdleTimeoutOptionsAndDefault() {
        XCTAssertEqual(RemoteIdleTimeout.defaultValue, .fiveMinutes)
        XCTAssertEqual(RemoteIdleTimeout.fiveMinutes.interval, 300)
        XCTAssertEqual(RemoteIdleTimeout.fifteenMinutes.interval, 900)
        XCTAssertEqual(RemoteIdleTimeout.thirtyMinutes.interval, 1_800)
        XCTAssertNil(RemoteIdleTimeout.never.interval)
        XCTAssertEqual(Set(RemoteIdleTimeout.allCases.map(\.title)).count, 4)
    }

    func testBothRemoteFamiliesUseIdleManagementAndPreserveSavedTimeout() throws {
        XCTAssertTrue(RemoteGeneration.glassTouchSurface.supportsIdleConnectionManagement)
        XCTAssertTrue(RemoteGeneration.aluminumClickpad.supportsIdleConnectionManagement)
        XCTAssertFalse(RemoteGeneration.unknown.supportsIdleConnectionManagement)
        let suite = "VibeRemoteTests.IdleTimeout.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(RemoteIdleTimeout.load(from: defaults), .fiveMinutes)
        defaults.set(0, forKey: "firstGenerationIdleTimeoutSeconds")
        XCTAssertEqual(RemoteIdleTimeout.load(from: defaults), .never)
        defaults.set(900, forKey: "firstGenerationIdleTimeoutSeconds")
        XCTAssertEqual(RemoteIdleTimeout.load(from: defaults), .fifteenMinutes)
        defaults.set(123, forKey: "firstGenerationIdleTimeoutSeconds")
        XCTAssertEqual(RemoteIdleTimeout.load(from: defaults), .fiveMinutes)
    }

    func testRemoteIdleTrackerResetsAndEmitsOnce() {
        var tracker = RemoteIdleTracker()
        tracker.synchronize(deviceKeys: ["old-a", "new-b"], now: 100)
        tracker.recordActivity(deviceKey: "new-b", now: 200)
        // More HID collections for either remote must not extend the other's deadline.
        tracker.synchronize(deviceKeys: ["old-a", "new-b"], now: 350)

        XCTAssertEqual(tracker.takeDueDisconnects(now: 399, timeout: 300), [])
        XCTAssertEqual(tracker.takeDueDisconnects(now: 400, timeout: 300), ["old-a"])
        XCTAssertFalse(tracker.shouldKeepAlive(deviceKey: "old-a"))
        XCTAssertTrue(tracker.shouldKeepAlive(deviceKey: "new-b"))
        XCTAssertEqual(tracker.takeDueDisconnects(now: 500, timeout: 300), ["new-b"])
        XCTAssertEqual(tracker.takeDueDisconnects(now: 900, timeout: 300), [])

        tracker.recordActivity(deviceKey: "old-a", now: 1_000)
        XCTAssertTrue(tracker.shouldKeepAlive(deviceKey: "old-a"))
        XCTAssertEqual(tracker.takeDueDisconnects(now: 1_299, timeout: 300), [])
        XCTAssertEqual(tracker.takeDueDisconnects(now: 1_300, timeout: 300), ["old-a"])

        tracker.reset(now: 2_000)
        XCTAssertTrue(tracker.shouldKeepAlive(deviceKey: "old-a"))
        XCTAssertTrue(tracker.shouldKeepAlive(deviceKey: "new-b"))
        XCTAssertEqual(tracker.takeDueDisconnects(now: 9_000, timeout: nil), [])

        tracker.synchronize(deviceKeys: [], now: 9_000)
        XCTAssertTrue(tracker.isEmpty)
    }

    func testBothGenerationsWaitForOutputDrainWithBoundedTimeout() {
        XCTAssertEqual(
            RemoteInputHandler.voiceTailReleaseTimeout(
                action: .rightOpt,
                button: "siri",
                generation: .glassTouchSurface
            ),
            4
        )
        XCTAssertEqual(RemoteInputHandler.voiceTailReleaseTimeout(
            action: .rightOpt,
            button: "siri",
            generation: .aluminumClickpad
        ), 3)
        XCTAssertNil(RemoteInputHandler.voiceTailReleaseTimeout(
            action: .enterKey,
            button: "siri",
            generation: .glassTouchSurface
        ))
        XCTAssertNil(RemoteInputHandler.voiceTailReleaseTimeout(
            action: .rightOpt,
            button: "tv",
            generation: .glassTouchSurface
        ))
    }

    func testConnectionInputGateIsPerRemoteAndExtendsAcrossInterfaces() {
        var gate = RemoteConnectionInputGate()
        gate.arm(deviceKey: "old", now: 10)
        XCTAssertTrue(gate.isBlocked(deviceKey: "old", now: 11.99))
        XCTAssertFalse(gate.isBlocked(deviceKey: "new", now: 11))

        // A second interface belonging to the same physical remote arrives later.
        gate.arm(deviceKey: "old", now: 11.5)
        XCTAssertTrue(gate.isBlocked(deviceKey: "old", now: 13.49))
        XCTAssertFalse(gate.isBlocked(deviceKey: "old", now: 13.5))

        gate.arm(deviceKey: "old", now: 20)
        gate.arm(deviceKey: "new", now: 20.5)
        gate.removeAll()
        XCTAssertFalse(gate.isBlocked(deviceKey: "old", now: 20.6))
        XCTAssertFalse(gate.isBlocked(deviceKey: "new", now: 20.6))
    }

    func testVolumeSuppressionCoversHoldReleaseAndMissingRelease() {
        var state = RemoteVolumeSuppression()
        let start = Date(timeIntervalSince1970: 100)
        state.update(button: "volumeUp", pressed: true, now: start)
        XCTAssertTrue(state.contains("volumeUp", now: start.addingTimeInterval(5)))
        XCTAssertFalse(state.contains("volumeDown", now: start.addingTimeInterval(5)))
        state.update(button: "volumeDown", pressed: true, now: start.addingTimeInterval(4))
        state.update(button: "volumeUp", pressed: false, now: start.addingTimeInterval(5))
        XCTAssertTrue(state.contains("volumeUp", now: start.addingTimeInterval(5.4)))
        XCTAssertFalse(state.contains("volumeUp", now: start.addingTimeInterval(5.6)))
        XCTAssertTrue(state.isActive(now: start.addingTimeInterval(6)))
        XCTAssertFalse(state.isActive(now: start.addingTimeInterval(35)))
        state = RemoteVolumeSuppression()
        state.update(button: "volumeDown", pressed: false, now: start)
        XCTAssertFalse(state.isActive(now: start))
    }

    func testBridgeRetriesBackOffAndResetAfterRecovery() {
        var schedule = BridgeRetrySchedule()
        let start = Date(timeIntervalSince1970: 100)
        XCTAssertTrue(schedule.isDue(now: start))
        schedule.recordAttempt(now: start)
        XCTAssertFalse(schedule.isDue(now: start.addingTimeInterval(2)))
        XCTAssertTrue(schedule.isDue(now: start.addingTimeInterval(3)))
        schedule.recordAttempt(now: start.addingTimeInterval(3))
        XCTAssertEqual(schedule.nextAttempt, start.addingTimeInterval(9))
        for _ in 0..<10 { schedule.recordAttempt(now: start) }
        XCTAssertEqual(schedule.nextAttempt, start.addingTimeInterval(60))
        schedule.reset()
        XCTAssertTrue(schedule.isDue(now: start))
    }

    func testDisconnectedBadgeTakesPriorityOverBridgeStartup() {
        XCTAssertEqual(RemoteStatusBadge(remoteConnected: false, bridgeRunning: false), .disconnected)
        XCTAssertEqual(RemoteStatusBadge(remoteConnected: false, bridgeRunning: true), .disconnected)
        XCTAssertEqual(RemoteStatusBadge(remoteConnected: true, bridgeRunning: false), .starting)
        XCTAssertEqual(RemoteStatusBadge(remoteConnected: true, bridgeRunning: true), .none)
    }

    @MainActor
    func testStatusBadgesKeepTheRemoteCanvasAndTemplateTint() throws {
        let original = MenuBarManager.makeRemoteIcon()
        for badge in [RemoteStatusBadge.starting, .disconnected] {
            let icon = MenuBarManager.makeRemoteIcon(badge: badge)
            XCTAssertEqual(icon.size, original.size)
            XCTAssertTrue(icon.isTemplate)
            XCTAssertNotNil(icon.tiffRepresentation)
            if let output = ProcessInfo.processInfo.environment["VIBEREMOTE_ICON_RENDER"] {
                let native = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(icon.tiffRepresentation)))
                try XCTUnwrap(native.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "\(output)-\(badge)-native.png"))
                let preview = NSImage(size: NSSize(width: 180, height: 200), flipped: false) { rect in
                    NSColor.white.setFill()
                    rect.fill()
                    icon.draw(in: NSRect(x: 20, y: 20, width: icon.size.width * 8, height: icon.size.height * 8))
                    return true
                }
                let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(preview.tiffRepresentation)))
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: "\(output)-\(badge).png"))
            }
        }
    }

    @MainActor
    func testDisconnectedBadgeStaysCircularAtMenuBarScales() throws {
        // Render the production drawing path at 1x and Retina size, without SF Symbol
        // typographic alignment metadata or the 8x preview hiding a native-size defect.
        for scale: CGFloat in [1, 2] {
            let side = 8 * scale
            let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
                MenuBarManager.drawDisconnectedBadge(in: rect)
                return true
            }
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
            let width = bitmap.pixelsWide
            let height = bitmap.pixelsHigh
            func alpha(_ x: Int, _ y: Int) -> CGFloat {
                bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0
            }
            XCTAssertEqual(width, height)
            // A stretched/cropped circle fills the corners. A circle touches each edge
            // near the middle while retaining transparent space in all four corners.
            for (x, y) in [(0, 0), (width - 1, 0), (0, height - 1), (width - 1, height - 1)] {
                XCTAssertLessThan(alpha(x, y), 0.1)
            }
            for (x, y) in [(0, height / 2), (width - 1, height / 2), (width / 2, 0), (width / 2, height - 1)] {
                XCTAssertGreaterThan(alpha(x, y), 0.4)
            }
        }
    }

    @MainActor
    func testSettingsNativeControlsAndWindowLifetime() throws {
        _ = NSApplication.shared
        var chosenAction: ButtonAction?
        var chosenModeSwitch: String?
        var resets = 0
        let controller = SettingsWindowController(
            snapshot: RemoteSettingsSnapshot(connected: true, batteryPercent: 59, siriAction: .rightOpt),
            setSiriAction: { chosenAction = $0 },
            resetSiriAction: { resets += 1 },
            setModeSwitch: { button, enabled in chosenModeSwitch = enabled ? button : nil }
        )
        let window = try XCTUnwrap(controller.window)
        let frame = try XCTUnwrap(window.contentView?.superview)
        frame.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(descendants)
        }
        // The toolbar's native More menu also uses a pop-up internally. Count only
        // remote mappings so this assertion describes the settings content.
        let mappingKeys = Set(remoteButtonDescriptors.map(\.key))
        let controls = descendants(frame).compactMap { $0 as? NSPopUpButton }
            .filter { mappingKeys.contains($0.identifier?.rawValue ?? "") }
        XCTAssertEqual(controls.count, 8)
        let siri = try XCTUnwrap(controls.first { $0.identifier?.rawValue == "siri" })
        XCTAssertEqual(siri.numberOfItems, ButtonAction.allCases.filter(\.isAssignableToSiriButton).count)
        XCTAssertNil(siri.item(withTitle: ButtonAction.shiftEnterOrModifier.settingsTitle))
        XCTAssertNil(siri.item(withTitle: ButtonAction.agentClientOrSlash.settingsTitle))
        siri.selectItem(withTitle: ButtonAction.rightCmd.settingsTitle)
        NSApp.sendAction(try XCTUnwrap(siri.action), to: siri.target, from: siri)
        XCTAssertEqual(chosenAction, .rightCmd)
        let power = try XCTUnwrap(controls.first { $0.identifier?.rawValue == "power" })
        XCTAssertEqual(power.itemTitles, [ButtonAction.enterKey.actionDescription])
        XCTAssertEqual((power.cell as? NSPopUpButtonCell)?.menuItem?.title, ButtonAction.enterKey.settingsTitle)
        NSApp.sendAction(try XCTUnwrap(power.action), to: power.target, from: power)
        XCTAssertEqual(chosenAction, .rightCmd, "Fixed mappings must not change the Siri mapping")
        for key in ["playPause", "mute"] {
            let control = try XCTUnwrap(controls.first { $0.identifier?.rawValue == key })
            XCTAssertEqual(control.numberOfItems, 2)
            control.selectItem(withTitle: ButtonAction.toggleInteractionMode.settingsTitle)
            NSApp.sendAction(try XCTUnwrap(control.action), to: control.target, from: control)
            XCTAssertEqual(chosenModeSwitch, key)
        }

        controller.update(RemoteSettingsSnapshot(connected: true, batteryPercent: 59, siriAction: .rightOpt, generation: .glassTouchSurface))
        frame.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let oldControls = descendants(frame).compactMap { $0 as? NSPopUpButton }
        XCTAssertEqual(Set(oldControls.compactMap { $0.identifier?.rawValue }), Set(["back", "select", "tv", "siri", "playPause", "volumeUp", "volumeDown"]))
        let tv = try XCTUnwrap(controls.first { $0.identifier?.rawValue == "tv" })
        let playPause = try XCTUnwrap(controls.first { $0.identifier?.rawValue == "playPause" })
        XCTAssertEqual(tv.titleOfSelectedItem, ButtonAction.shiftEnterOrModifier.actionDescription)
        XCTAssertEqual(playPause.titleOfSelectedItem, ButtonAction.agentClientOrSlash.settingsTitle)
        XCTAssertEqual((tv.cell as? NSPopUpButtonCell)?.menuItem?.title, ButtonAction.shiftEnterOrModifier.settingsTitle)
        XCTAssertEqual((playPause.cell as? NSPopUpButtonCell)?.menuItem?.title, ButtonAction.agentClientOrSlash.settingsTitle)

        let more = try XCTUnwrap(window.toolbar?.items.first { $0.itemIdentifier.rawValue == "VibeRemote.MoreSettings" } as? NSMenuToolbarItem)
        let reset = try XCTUnwrap(more.menu.items.first { $0.identifier?.rawValue == "VibeRemote.ResetSettings" })
        XCTAssertTrue(reset.isEnabled)
        NSApp.sendAction(try XCTUnwrap(reset.action), to: reset.target, from: reset)
        XCTAssertEqual(resets, 1)
        controller.update(RemoteSettingsSnapshot(connected: false, batteryPercent: nil, siriAction: .spaceKey))
        XCTAssertFalse(reset.isEnabled)
        XCTAssertTrue(more.isEnabled, "The menu must remain accessible when Reset is unavailable")

        // Optional offscreen render for visual comparison. It never orders a window
        // onto the user's desktop or starts any HID/audio services.
        if let output = ProcessInfo.processInfo.environment["VIBEREMOTE_SETTINGS_RENDER"] {
            for generation in [RemoteGeneration.glassTouchSurface, .aluminumClickpad] {
            controller.update(RemoteSettingsSnapshot(connected: true, batteryPercent: 59, siriAction: .rightOpt, generation: generation))
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                window.appearance = NSAppearance(named: appearance)
                frame.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                let bitmap = try XCTUnwrap(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
                window.effectiveAppearance.performAsCurrentDrawingAppearance {
                    frame.cacheDisplay(in: frame.bounds, to: bitmap)
                }
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: "\(output)-\(generation == .glassTouchSurface ? "first" : "new")-\(name).png"))
            }
            }
        }
        window.close()
        XCTAssertTrue(controller.window === window)
        XCTAssertFalse(window.isReleasedWhenClosed)
    }

    func testSettingsArtworkAndButtonLayoutsRemainGenerationSpecific() throws {
        let old = RemoteSettingsLayout(generation: .glassTouchSurface)
        let newer = RemoteSettingsLayout(generation: .aluminumClickpad)
        XCTAssertNotEqual(old.resourceName, newer.resourceName)
        for layout in [old, newer] {
            XCTAssertNotNil(SettingsAssets.bundle.url(forResource: layout.resourceName, withExtension: "png"))
        }
        XCTAssertEqual(old.left.map(\.key), ["back", "siri", "playPause"])
        XCTAssertEqual(old.right.map(\.key), ["select", "tv", "volumeUp", "volumeDown"])
        XCTAssertEqual(old.left.map(\.centerY), Array(old.right.dropFirst()).map(\.centerY))
        XCTAssertTrue(newer.left.contains { $0.key == "mute" })
        XCTAssertTrue(newer.right.contains { $0.key == "power" })
    }

    func testSettingsNeverShowAStaleBatteryAsAConnection() {
        var snapshot = RemoteSettingsSnapshot(connected: false, batteryPercent: 59, siriAction: .spaceKey)
        XCTAssertEqual(snapshot.connectionText, "DISCONNECTED")
        snapshot.connected = true
        XCTAssertEqual(snapshot.connectionText, "CONNECTED 59%")
        snapshot.batteryPercent = nil
        XCTAssertEqual(snapshot.connectionText, "CONNECTED — BATTERY UNKNOWN")
        snapshot.batteryPercent = 101
        XCTAssertEqual(snapshot.connectionText, "CONNECTED — BATTERY UNKNOWN")
        snapshot.batteryPercent = 0
        XCTAssertEqual(snapshot.connectionText, "CONNECTED 0%")
    }

    func testSettingsShipTheRemoteArtwork() throws {
        let artwork = try XCTUnwrap(Bundle.module.url(forResource: "SiriRemote", withExtension: "png"))
        let data = try Data(contentsOf: artwork)
        XCTAssertEqual(Array(data.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
    }

    func testSettingsFindResourcesInsideAnInstalledAppLayout() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("SettingsTest.app")
        let resources = app.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let info = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "com.viberemote.settings-test", "CFBundlePackageType": "APPL"],
            format: .xml,
            options: 0
        )
        try info.write(to: app.appendingPathComponent("Contents/Info.plist"))
        try FileManager.default.copyItem(
            at: Bundle.module.bundleURL,
            to: resources.appendingPathComponent("VibeRemote_VibeRemote.bundle")
        )
        let appBundle = try XCTUnwrap(Bundle(url: app))
        let installedResources = try XCTUnwrap(SettingsAssets.bundledResources(in: appBundle))
        XCTAssertNotNil(installedResources.url(forResource: "SiriRemote", withExtension: "png"))
        XCTAssertTrue(installedResources.bundlePath.hasPrefix(app.path))
    }

    func testRemoteInputStatesExposeDistinctMenuStatus() {
        XCTAssertEqual(RemoteInputState.permissionRequired.menuTitle, "Input: Permission Required...")
        XCTAssertEqual(RemoteInputState.starting.menuTitle, "Input: Starting...")
        XCTAssertEqual(RemoteInputState.waitingForRemote.menuTitle, "Input: Waiting for Remote")
        XCTAssertEqual(RemoteInputState.ready.menuTitle, "Input: Ready")
        XCTAssertEqual(RemoteInputState.unavailable.menuTitle, "Input: Unavailable")
        XCTAssertEqual(RemoteControlState.permissionRequired.menuTitle, "Control: Permission Required...")
        XCTAssertEqual(RemoteControlState.starting.menuTitle, "Control: Checking Permission...")
        XCTAssertEqual(RemoteControlState.ready.menuTitle, "Control: Ready")
        XCTAssertFalse(BluetoothAccessState.notDetermined.allowsBatteryLookup)
        XCTAssertFalse(BluetoothAccessState.denied.allowsBatteryLookup)
        XCTAssertTrue(BluetoothAccessState.allowed.allowsBatteryLookup)
    }

    func testOnlyPushToTalkActionsRequireReleaseEvents() {
        XCTAssertTrue(ButtonAction.spaceKey.requiresHold)
        XCTAssertTrue(ButtonAction.rightCmd.requiresHold)
        XCTAssertTrue(ButtonAction.rightOpt.requiresHold)
        XCTAssertFalse(ButtonAction.enterKey.requiresHold)
        XCTAssertFalse(ButtonAction.none.requiresHold)
    }

    func testOnlyKnownVendorUsagesMapToSiri() {
        XCTAssertEqual(RemoteInputHandler.identifyButton(page: 0xFF00, usage: 0x01), "siri")
        XCTAssertEqual(RemoteInputHandler.identifyButton(page: 0xFF00, usage: 0x03), "siri")
        XCTAssertNil(RemoteInputHandler.identifyButton(page: 0xFF00, usage: 0x04))
        XCTAssertNil(RemoteInputHandler.identifyButton(page: 0xFF00, usage: 0xFFFF))
        XCTAssertEqual(RemoteInputHandler.identifyButton(page: 0x0C, usage: 0xCD), "playPause")
    }

    func testOnlyDedicatedConsumerUsageIsTreatedAsAudioInterface() {
        XCTAssertTrue(RemoteInputHandler.isAudioInterface(usagePage: 0x0C, usage: 0x04))
        XCTAssertFalse(RemoteInputHandler.isAudioInterface(usagePage: 0x0C, usage: 0x01))
        XCTAssertFalse(RemoteInputHandler.isAudioInterface(usagePage: 0xFF00, usage: 0x04))
    }

    func testHIDReportReferenceParserReadsIDAndType() {
        let dataResult = RemoteHIDChannel.reportReference(from: Data([0xFA, 0x01]))
        XCTAssertEqual(dataResult?.id, 0xFA)
        XCTAssertEqual(dataResult?.type, 0x01)

        let numberResult = RemoteHIDChannel.reportReference(
            from: [NSNumber(value: 0xFF), NSNumber(value: 0x03)]
        )
        XCTAssertEqual(numberResult?.id, 0xFF)
        XCTAssertEqual(numberResult?.type, 0x03)
        XCTAssertNil(RemoteHIDChannel.reportReference(from: Data([0xFA])))
    }

    func testSystemHIDPeripheralIdentifierParser() {
        let expected = UUID(uuidString: "3D2B7941-3990-833B-35B2-4335A86F0832")!
        XCTAssertEqual(
            RemoteHIDChannel.peripheralIdentifier(
                from: "3D2B7941-3990-833B-35B2-4335A86F0832"
            ),
            expected
        )
        XCTAssertEqual(RemoteHIDChannel.peripheralIdentifier(from: expected), expected)
        XCTAssertNil(RemoteHIDChannel.peripheralIdentifier(from: "not-a-uuid"))
    }

    func testButtonAndAudioCollectionsRemainVisibleToAppleRemoteDrivers() {
        XCTAssertTrue(RemoteInputHandler.requiresSharedSystemAccess(usagePage: 0x0C, usage: 0x01))
        XCTAssertTrue(RemoteInputHandler.requiresSharedSystemAccess(usagePage: 0x0C, usage: 0x04))
        XCTAssertFalse(RemoteInputHandler.requiresSharedSystemAccess(usagePage: 0x0D, usage: 0x01))
        XCTAssertFalse(RemoteInputHandler.requiresSharedSystemAccess(usagePage: 0xFF00, usage: 0x0B))
    }

    func testDirectHIDReportLinePreservesMetadataAndBytes() {
        let line = MicrophoneBridgeManager.directHIDReportLine(
            reportID: 0xFF,
            data: Data([0xFF, 0x1B, 0x35, 0x00])
        )
        XCTAssertEqual(
            line,
            "HID REPORT id=FF length=4 data=FF 1B 35 00\n"
        )
    }

    func testBluetoothConnectionRecoveryOnlyUsesCurrentPromptFreePacketLoggerBridge() {
        let currentVersion = HelperConstants.packetLoggerCaptureMinimumVersion
        XCTAssertTrue(MicrophoneBridgeManager.shouldRecoverPacketLoggerAfterBluetoothConnection(
            enginePreference: "packetlogger",
            bridgeRunning: true,
            helperReady: true,
            helperVersion: currentVersion
        ))
        XCTAssertFalse(MicrophoneBridgeManager.shouldRecoverPacketLoggerAfterBluetoothConnection(
            enginePreference: nil,
            bridgeRunning: true,
            helperReady: true,
            helperVersion: currentVersion
        ))
        XCTAssertTrue(MicrophoneBridgeManager.shouldRecoverPacketLoggerAfterBluetoothConnection(
            enginePreference: "packetlogger",
            bridgeRunning: false,
            helperReady: true,
            helperVersion: currentVersion
        ))
        XCTAssertFalse(MicrophoneBridgeManager.shouldRecoverPacketLoggerAfterBluetoothConnection(
            enginePreference: "packetlogger",
            bridgeRunning: true,
            helperReady: false,
            helperVersion: currentVersion
        ))
        XCTAssertFalse(MicrophoneBridgeManager.shouldRecoverPacketLoggerAfterBluetoothConnection(
            enginePreference: "packetlogger",
            bridgeRunning: true,
            helperReady: true,
            helperVersion: currentVersion - 1
        ))
    }

    func testRemoteIdentityPrefersConcreteProductNameOverLegacyProductID() {
        XCTAssertTrue(RemoteDetector.matchesSiriRemote(
            vendorID: 0x004C,
            productID: 0x0314,
            productName: "Marcus Siri Remote"
        ))
        XCTAssertFalse(RemoteDetector.matchesSiriRemote(
            vendorID: 0x004C,
            productID: 0x0269,
            productName: "Marcus Magic Mouse"
        ))
        XCTAssertTrue(RemoteDetector.matchesSiriRemote(
            vendorID: 0x004C,
            productID: 0x0315,
            productName: nil
        ))
    }

    func testSkillPickerUsesTheFocusedAppAndPreservesUnknownAppBehavior() {
        let codex = RemoteInputHandler.skillPickerTrigger(for: "com.openai.codex")
        XCTAssertEqual(codex.text, "$")
        XCTAssertEqual(codex.keyCode, kVK_ANSI_4)
        XCTAssertEqual(codex.flags, .maskShift)
        for bundleID in ["com.anthropic.claudefordesktop", "com.apple.Safari", "com.apple.Terminal", "com.openai.codex.other", nil] {
            let trigger = RemoteInputHandler.skillPickerTrigger(for: bundleID)
            XCTAssertEqual(trigger.text, "/")
            XCTAssertEqual(trigger.keyCode, kVK_ANSI_Slash)
            XCTAssertTrue(trigger.flags.isEmpty)
        }
    }

    func testSkillPickerKeyEventsCarryExactASCIITextAndMatchingRelease() throws {
        for bundleID in ["com.openai.codex", "com.anthropic.claudefordesktop"] {
            let trigger = RemoteInputHandler.skillPickerTrigger(for: bundleID)
            for keyDown in [true, false] {
                // Construct only; never inject test keystrokes into the user's desktop.
                let event = try XCTUnwrap(RemoteInputHandler.makeKeyEvent(
                    keyCode: trigger.keyCode, flags: trigger.flags, keyDown: keyDown, text: trigger.text
                ))
                var characters = [UniChar](repeating: 0, count: 8)
                var length = 0
                event.keyboardGetUnicodeString(maxStringLength: characters.count, actualStringLength: &length, unicodeString: &characters)
                XCTAssertEqual(String(utf16CodeUnits: characters, count: length), trigger.text)
                XCTAssertEqual(event.type, keyDown ? .keyDown : .keyUp)
                XCTAssertEqual(event.flags, trigger.flags)
                XCTAssertEqual(event.getIntegerValueField(.keyboardEventKeycode), Int64(trigger.keyCode))
            }
        }
        // Existing saved assignments must survive the updated visible description.
        XCTAssertEqual(ButtonAction(rawValue: "Slash: Skill Picker / Hold: Modifier"), .slashOrModifier)
    }

    func testMuteButtonOpensSkillPickerAndActsAsModifier() {
        let mute = remoteButtonDescriptors.first { $0.key == "mute" }
        XCTAssertEqual(mute?.defaultAction, .slashOrModifier)
        // The tap/modifier split is timed on release, not a held-key action.
        XCTAssertFalse(ButtonAction.slashOrModifier.requiresHold)
        XCTAssertEqual(mute?.supportsHold, false)
        // The 2nd-gen remote reports mute as Consumer 0xE2 (the standard usage). Without
        // this mapping the HID marker is never set, the media-key interceptor lets the
        // event through, and the button mutes the system instead of acting as our key.
        XCTAssertEqual(RemoteInputHandler.identifyButton(page: 0x0C, usage: 0xE2), "mute")
    }

    func testModifierChordTableCoversBackAndPlayPauseOnly() {
        // The physical Back button reports as "back" or "menu" depending on the remote;
        // both must clear the input or the chord silently degrades to plain Backspace.
        XCTAssertEqual(RemoteInputHandler.modifierChord(for: "back"), .clearInput)
        XCTAssertEqual(RemoteInputHandler.modifierChord(for: "menu"), .clearInput)
        XCTAssertEqual(RemoteInputHandler.modifierChord(for: "playPause"), .escape)
        for descriptor in remoteButtonDescriptors where !["back", "menu", "playPause"].contains(descriptor.key) {
            XCTAssertNil(RemoteInputHandler.modifierChord(for: descriptor.key), descriptor.key)
        }
    }

    func testEveryRemoteButtonDescriptorHasAUniqueKeyAndValidHoldDefault() {
        let keys = remoteButtonDescriptors.map(\.key)
        XCTAssertEqual(Set(keys).count, keys.count)
        XCTAssertTrue(remoteButtonDescriptors.allSatisfy {
            !$0.defaultAction.requiresHold || $0.supportsHold
        })
        XCTAssertTrue(Set(["back", "nextTrack", "prevTrack"]).isSubset(of: Set(keys)))
    }

    func testBatteryParserFindsRemoteAndIgnoresOtherDevices() throws {
        let remoteJSON = try XCTUnwrap(
            """
            {"SPBluetoothDataType":[{"device_connected":[{"Office Siri Remote":{"device_batteryLevelMain":"87%"}}]}]}
            """.data(using: .utf8)
        )
        XCTAssertEqual(RemoteBatteryReader.batteryPercent(fromSystemProfilerJSON: remoteJSON), 87)

        let keyboardJSON = try XCTUnwrap(
            """
            {"SPBluetoothDataType":[{"device_connected":[{"Keyboard":{"device_batteryLevelMain":"42%"}}]}]}
            """.data(using: .utf8)
        )
        XCTAssertNil(RemoteBatteryReader.batteryPercent(fromSystemProfilerJSON: keyboardJSON))
        XCTAssertNil(RemoteBatteryReader.batteryPercent(fromSystemProfilerJSON: Data("not json".utf8)))
    }

    // MARK: - PacketLogger bridge (shared with the privileged helper)

    func testPacketLoggerAppBundleDerivationRequiresOriginalStructure() {
        XCTAssertEqual(
            PacketLoggerBridge.appBundlePath(
                forExecutablePath: "/Applications/Tools/PacketLogger.app/Contents/Resources/packetlogger"
            ),
            "/Applications/Tools/PacketLogger.app"
        )
        // Anything outside PacketLogger.app/Contents/Resources must be rejected: the root
        // supervisor equates this app path with "what codesign validates".
        XCTAssertNil(PacketLoggerBridge.appBundlePath(forExecutablePath: "/usr/local/bin/packetlogger"))
        XCTAssertNil(
            PacketLoggerBridge.appBundlePath(
                forExecutablePath: "/tmp/Fake.app/Contents/Resources/packetlogger"
            )
        )
        XCTAssertNil(
            PacketLoggerBridge.appBundlePath(
                forExecutablePath: "/tmp/PacketLogger.app/Contents/MacOS/packetlogger"
            )
        )
    }

    func testSupervisorCommandBindsIdentityAndEscapesPaths() {
        let token = "0AC81F8B-6A21-4A29-B7E4-1D5A3F9C2E10"
        let command = PacketLoggerBridge.supervisorCommand(
            packetLogger: "/Apps/PacketLogger.app/Contents/Resources/packetlogger",
            packetLoggerApp: "/Apps/PacketLogger.app",
            helperSource: "/Apps/PacketLogger.app/Contents/Library/LaunchServices/com.apple.bluetooth.PacketLoggerHelper",
            userHelper: "/Users/o'brien/VibeRemoteVoiceBridge",
            runtimeDirectory: "/Users/o'brien/Library/Application Support/VibeRemote/MicrophoneBridge",
            ownerPID: 4321,
            ownerUID: 501,
            supervisorToken: token
        )
        // The app verifies the supervisor by finding this exact assignment in ps output.
        XCTAssertTrue(command.contains("viberemote_supervisor_token=\(token)"))
        XCTAssertTrue(command.contains("owner_pid=4321"))
        XCTAssertTrue(command.contains("expected_uid=501"))
        // Paths with shell metacharacters must arrive single-quote escaped.
        XCTAssertTrue(command.contains("runtime='/Users/o'\\''brien/Library/Application Support/VibeRemote/MicrophoneBridge'"))
        // Runtime file paths are derived from the shared names, inside the runtime directory.
        XCTAssertTrue(command.contains("/MicrophoneBridge/\(PacketLoggerBridge.RuntimeFile.voiceFIFO)'"))
        XCTAssertTrue(command.contains("/MicrophoneBridge/\(PacketLoggerBridge.RuntimeFile.stopSignal)'"))
    }

    func testSupervisorCommandKeepsThePlatformLandmineWorkarounds() {
        let command = PacketLoggerBridge.supervisorCommand(
            packetLogger: "/Apps/PacketLogger.app/Contents/Resources/packetlogger",
            packetLoggerApp: "/Apps/PacketLogger.app",
            helperSource: "/dev/null",
            userHelper: "/tmp/helper",
            runtimeDirectory: "/tmp/runtime",
            ownerPID: 1000,
            ownerUID: 501,
            supervisorToken: UUID().uuidString
        )
        // Each of these looked like an impossible bridge before it was found; losing any one
        // of them silently breaks live capture again (see AGENTS.md).
        XCTAssertTrue(command.contains("0<> \"$stdin_keepalive\""), "PacketLogger stdin must never reach EOF")
        XCTAssertTrue(command.contains("supervisor_pid=$(exec /bin/sh -c 'echo $PPID')"), "PPID probe needs exec")
        XCTAssertTrue(command.contains("'Last UsedPacket Priority Set' -int 3"), "priority 3 selects local live capture")
        // Root-side signature validation must stay ahead of any system mutation.
        XCTAssertTrue(command.contains("validate_packetlogger || fail"))
        XCTAssertTrue(command.contains("validate_helper \"$helper_source\" || fail"))
    }

    func testSupervisorInitializesAParseableHelperPlist() throws {
        let command = PacketLoggerBridge.supervisorCommand(
            packetLogger: "/Applications/PacketLogger.app/Contents/Resources/packetlogger",
            packetLoggerApp: "/Applications/PacketLogger.app",
            helperSource: "/tmp/helper", userHelper: "/tmp/voice",
            runtimeDirectory: "/tmp/runtime", ownerPID: 1000, ownerUID: 501,
            supervisorToken: UUID().uuidString
        )
        let lines = command.components(separatedBy: "\n")
        let seed = try XCTUnwrap(lines.first { $0.contains("<dict/></plist>") })
        let populate = try XCTUnwrap(lines.first { $0.contains("-c 'Clear dict'") })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "set -e\ntemp_plist=\"$1/helper.plist\"\n" + seed + "\n" + populate, "test", directory.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let data = try Data(contentsOf: directory.appendingPathComponent("helper.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["Label"] as? String, "com.apple.bluetooth.PacketLoggerHelper")
        XCTAssertEqual(plist["ProgramArguments"] as? [String], ["/Library/PrivilegedHelperTools/com.apple.bluetooth.PacketLoggerHelper"])
        XCTAssertEqual(plist["MachServices"] as? [String: Bool], ["com.apple.bluetooth.PacketLoggerHelper": true])
    }

    // MARK: - Siri Remote generations

    private func interface(
        deviceKey: String = "48:a9:1c:91:77:5c",
        transport: String? = "Bluetooth Low Energy",
        usagePage: Int = 0x0C,
        usage: Int = 0x01,
        maxInput: Int = 2,
        maxFeature: Int = 1,
        hardwareRevision: String? = nil
    ) -> RemoteInterfaceDescriptor {
        RemoteInterfaceDescriptor(
            deviceKey: deviceKey,
            productName: "Siri Remote",
            productID: 0x026D,
            transport: transport,
            usagePage: usagePage,
            usage: usage,
            maxInputReportSize: maxInput,
            maxFeatureReportSize: maxFeature,
            hardwareRevision: hardwareRevision
        )
    }

    func testReportSizeFallbackWhenHardwareRevisionIsUnavailable() {
        // Both families are sold as "Siri Remote" and both have shipped as product 0x026D, so
        // report sizes remain a fallback when hardware revision is unavailable.
        let clickpad = [
            interface(usagePage: 0x0C, usage: 0x04, maxInput: 209, maxFeature: 209),
            interface(usagePage: 0x0C, usage: 0x01, maxInput: 2, maxFeature: 209),
        ]
        XCTAssertEqual(RemoteGeneration.classify(interfaces: clickpad), .aluminumClickpad)

        let touchSurface = [
            interface(usagePage: 0x0C, usage: 0x01, maxInput: 2, maxFeature: 1),
            interface(usagePage: 0x01, usage: 0x06, maxInput: 20, maxFeature: 1),
        ]
        XCTAssertEqual(RemoteGeneration.classify(interfaces: touchSurface), .glassTouchSurface)

        XCTAssertEqual(RemoteGeneration.classify(interfaces: []), .unknown)
    }

    func testConfirmedGlassRemoteWithLargeProxyReports() {
        let old = interface(maxInput: 209, maxFeature: 209, hardwareRevision: "0A00")
        XCTAssertEqual(RemoteGeneration.classify(interfaces: [old]), .glassTouchSurface)
        let newer = interface(deviceKey: "newer", maxInput: 209, maxFeature: 209)
        let both = RemoteGeneration.classifyAll(interfaces: [newer, old])
        XCTAssertEqual(both[old.deviceKey], .glassTouchSurface)
        XCTAssertEqual(both[newer.deviceKey], .aluminumClickpad)
        XCTAssertEqual(both[old.deviceKey]?.action(for: "select", defaultAction: .enterKey, siriAction: .rightOpt), .enterKey)
        let otherProduct = RemoteInterfaceDescriptor(
            deviceKey: "other", productName: "Siri Remote", productID: 0x0315,
            transport: old.transport, usagePage: 0x0C, usage: 1,
            maxInputReportSize: 209, maxFeatureReportSize: 209, hardwareRevision: "0A00"
        )
        XCTAssertEqual(RemoteGeneration.classify(interfaces: [otherProduct]), .aluminumClickpad)
        XCTAssertEqual(RemoteGeneration.classify(interfaces: [
            interface(transport: "USB", maxInput: 209, hardwareRevision: "0A00")
        ]), .unknown)
        XCTAssertFalse(RemoteInputHandler.shouldSniffAudio(
            descriptor: old, generation: .glassTouchSurface, hasDedicatedAudioCollection: true
        ))
    }

    func testRemoteAttachedOverLightningIsNeverTheActiveRemote() {
        // A 1st-gen remote plugged in to charge enumerates as a single vendor-page interface
        // with a 1-byte report and no buttons. It must not displace a paired remote, and on
        // its own it must not look like a usable remote either.
        let cabled = interface(
            deviceKey: "DJ7YK3PPJ90M",
            transport: "USB",
            usagePage: 0xFF00,
            usage: 0x0B,
            maxInput: 1,
            maxFeature: 39
        )
        XCTAssertEqual(RemoteGeneration.classify(interfaces: [cabled]), .unknown)

        let paired = interface(usagePage: 0x0C, usage: 0x04, maxInput: 209, maxFeature: 209)
        XCTAssertEqual(RemoteGeneration.primary(interfaces: [cabled, paired]), .aluminumClickpad)

        let pairedOldRemote = interface(deviceKey: "aa:bb:cc:dd:ee:ff", maxInput: 20)
        XCTAssertEqual(
            RemoteGeneration.primary(interfaces: [cabled, pairedOldRemote]),
            .glassTouchSurface
        )

        // Both remotes paired at once: each keeps its own generation, so a press on either
        // resolves against the right button profile no matter which one the menu shows.
        let byDevice = RemoteGeneration.classifyAll(interfaces: [cabled, paired, pairedOldRemote])
        XCTAssertEqual(byDevice["48:a9:1c:91:77:5c"], .aluminumClickpad)
        XCTAssertEqual(byDevice["aa:bb:cc:dd:ee:ff"], .glassTouchSurface)
        XCTAssertEqual(byDevice["DJ7YK3PPJ90M"], .unknown)
    }

    func testFirstGenerationProfileRehomesTheMissingMuteButton() {
        // The mute button's two jobs move onto TV and Play/Pause.
        let overrides = RemoteGeneration.glassTouchSurface.buttonActionOverrides
        XCTAssertEqual(overrides["tv"], .shiftEnterOrModifier)
        XCTAssertEqual(overrides["playPause"], .agentClientOrSlash)
        XCTAssertNil(overrides["select"]) // Both generations keep the baseline Enter action.
        XCTAssertEqual(RemoteGeneration.glassTouchSurface.absentButtonKeys, ["mute", "power"])
        XCTAssertTrue(RemoteGeneration.aluminumClickpad.buttonActionOverrides.isEmpty)
        XCTAssertTrue(RemoteGeneration.unknown.buttonActionOverrides.isEmpty)

        // The chords the mute button armed must still resolve, now from the TV button.
        XCTAssertEqual(RemoteInputHandler.modifierChord(for: "menu"), .clearInput)
        XCTAssertEqual(RemoteInputHandler.modifierChord(for: "playPause"), .escape)
        XCTAssertNil(RemoteInputHandler.modifierChord(for: "tv"))

        // None of the replacements may become a held-key action; all resolve on release.
        XCTAssertFalse(ButtonAction.shiftEnterOrModifier.requiresHold)
        XCTAssertFalse(ButtonAction.agentClientOrSlash.requiresHold)
    }

    func testOnlyPhysicalSiriButtonFollowsTheSiriSettingOnBothGenerations() {
        for action in ButtonAction.allCases where action.isAssignableToSiriButton {
            for generation in RemoteGeneration.allCases {
                XCTAssertEqual(generation.action(for: "siri", defaultAction: .spaceKey, siriAction: action), action)
                XCTAssertEqual(
                    generation.action(for: "select", defaultAction: .enterKey, siriAction: action),
                    .enterKey
                )
                XCTAssertEqual(generation.action(for: "navUp", defaultAction: .upKey, siriAction: action), .upKey)
            }
        }
    }

    func testCompositeActionsAreNeverOfferedForTheSiriButton() {
        // The Siri submenu lists every ButtonAction case. A composite action must not appear
        // there: they are assigned by the generation profile.
        for action in ButtonAction.allCases where action.isAssignableToSiriButton {
            XCTAssertNotEqual(action, .shiftEnterOrModifier)
            XCTAssertNotEqual(action, .agentClientOrSlash)
        }
        XCTAssertTrue(ButtonAction.spaceKey.isAssignableToSiriButton)
        XCTAssertTrue(ButtonAction.rightCmd.isAssignableToSiriButton)
        XCTAssertTrue(ButtonAction.none.isAssignableToSiriButton)
    }

    func testOnlyTheOlderRemoteSniffsOrdinaryInterfacesForAudio() {
        // The 2nd/3rd-gen remote publishes audio on one dedicated collection, so widening the
        // net there would pipe button reports into the voice helper.
        let large = interface(usagePage: 0x0D, usage: 0x01, maxInput: 209, maxFeature: 209)
        XCTAssertFalse(RemoteInputHandler.shouldSniffAudio(
            descriptor: large,
            generation: .aluminumClickpad
        ))
        XCTAssertTrue(RemoteInputHandler.shouldSniffAudio(
            descriptor: interface(maxInput: 20),
            generation: .glassTouchSurface
        ))
        // Button-sized reports can never hold a 20 ms Opus frame.
        XCTAssertFalse(RemoteInputHandler.shouldSniffAudio(
            descriptor: interface(maxInput: 4),
            generation: .glassTouchSurface
        ))
    }

    func testFirstGenerationButtonUsagesAreMapped() {
        // The 1st-gen remote predates the 2nd-gen HID descriptor and reports its six buttons
        // with the generic Consumer media usages.
        XCTAssertEqual(RemoteInputHandler.identifyButton(page: 0x0C, usage: 0x46), "menu")
        XCTAssertEqual(RemoteInputHandler.identifyButton(page: 0x0C, usage: 0x89), "tv")
        XCTAssertEqual(RemoteInputHandler.identifyButton(page: 0x0C, usage: 0xB0), "playPause")
        XCTAssertEqual(RemoteInputHandler.identifyButton(page: 0x0C, usage: 0xCF), "siri")
        // Unrelated usages stay unmapped so nothing else on the vendor pages is seized.
        XCTAssertNil(RemoteInputHandler.identifyButton(page: 0x0C, usage: 0x77))
    }
}
