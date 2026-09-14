import HelperProtocol
import XCTest
@testable import VibeRemote

final class ModelTests: XCTestCase {
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
