import XCTest
@testable import VibeRemote

final class RemoteConnectionRecoveryTests: XCTestCase {
    @MainActor
    func testUnresolvedOrDeniedAuthorizationNeverQueriesBluetooth() async {
        let queried = expectation(description: "Bluetooth must remain untouched")
        queried.isInverted = true
        let probe = RemoteConnectionRecoveryProbe(read: { queried.fulfill(); return [] })
        for state in [BluetoothAccessState.notDetermined, .denied, .restricted] {
            probe.refresh(authorization: state) { _ in XCTFail("Unauthorized result delivered") }
        }
        await fulfillment(of: [queried], timeout: 0.05)
    }

    @MainActor
    func testBlockedQueryLeavesMainActorResponsiveAndCoalescesWatchdogs() async {
        let entered = expectation(description: "Background Bluetooth query entered")
        let delivered = expectation(description: "Single connection snapshot delivered")
        let release = DispatchSemaphore(value: 0)
        let probe = RemoteConnectionRecoveryProbe(read: {
            XCTAssertFalse(Thread.isMainThread)
            entered.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 2), .success)
            return ["60:BE:C4:02:EB:CC"]
        })
        for _ in 0..<10 {
            probe.refresh(authorization: .allowed) { addresses in
                XCTAssertTrue(Thread.isMainThread)
                XCTAssertEqual(addresses, ["60:BE:C4:02:EB:CC"])
                delivered.fulfill()
            }
        }
        await fulfillment(of: [entered], timeout: 1)
        // The main actor can release a query that is still blocked in its worker.
        release.signal()
        await fulfillment(of: [delivered], timeout: 1)
    }

    @MainActor
    func testTopologyChangeOrShutdownDiscardsInFlightSnapshot() async {
        let entered = expectation(description: "Background query entered")
        let returned = expectation(description: "Background query returned")
        let stale = expectation(description: "Stale connections must not reopen HID")
        stale.isInverted = true
        let release = DispatchSemaphore(value: 0)
        let probe = RemoteConnectionRecoveryProbe(read: {
            entered.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 2), .success)
            returned.fulfill()
            return ["60:BE:C4:02:EB:CC"]
        })
        probe.refresh(authorization: .allowed) { _ in stale.fulfill() }
        await fulfillment(of: [entered], timeout: 1)
        probe.invalidate()
        // Invalidation cannot cancel IOBluetooth; a later tick must not pile up reads.
        probe.refresh(authorization: .allowed) { _ in stale.fulfill() }
        release.signal()
        await fulfillment(of: [returned], timeout: 1)
        await fulfillment(of: [stale], timeout: 0.05)
    }
}
