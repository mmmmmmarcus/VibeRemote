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
}
