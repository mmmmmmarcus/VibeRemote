import HelperProtocol
import XCTest
@testable import VibeRemote

final class ModelTests: XCTestCase {
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
        XCTAssertFalse(MicrophoneBridgeManager.shouldRecoverPacketLoggerAfterBluetoothConnection(
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

    func testMuteButtonTypesSlashAndActsAsModifier() {
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
}
