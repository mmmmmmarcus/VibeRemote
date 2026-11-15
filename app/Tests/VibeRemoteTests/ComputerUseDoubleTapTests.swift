import XCTest
@testable import VibeRemote

final class ComputerUseDoubleTapTests: XCTestCase {
    func testTwoShortTapsOpenOnce() {
        var gate = ComputerUseDoubleTap()
        XCTAssertFalse(gate.update(down: true, now: 0))
        XCTAssertFalse(gate.update(down: false, now: 0.1))
        XCTAssertFalse(gate.update(down: true, now: 0.2))
        XCTAssertTrue(gate.update(down: false, now: 0.3))
        XCTAssertFalse(gate.update(down: false, now: 0.31))
        XCTAssertFalse(gate.update(down: true, now: 0.4))
        XCTAssertFalse(gate.update(down: false, now: 0.5))
    }
    func testHoldAndSlowTapsDoNotOpen() {
        var gate = ComputerUseDoubleTap()
        _ = gate.update(down: true, now: 0)
        XCTAssertFalse(gate.update(down: false, now: 1))
        XCTAssertFalse(gate.shortRelease)
        _ = gate.update(down: true, now: 1.1)
        XCTAssertFalse(gate.update(down: false, now: 1.2))
        _ = gate.update(down: true, now: 2)
        XCTAssertFalse(gate.update(down: false, now: 2.1))
    }
    func testInterruptionAndRepeatedDownDoNotFabricateTaps() {
        var gate = ComputerUseDoubleTap()
        _ = gate.update(down: true, now: 0)
        _ = gate.update(down: true, now: 0.2)
        XCTAssertFalse(gate.update(down: false, now: 0.3))
        XCTAssertFalse(gate.shortRelease)
        _ = gate.update(down: true, now: 1)
        _ = gate.update(down: false, now: 1.1)
        gate.reset()
        _ = gate.update(down: true, now: 1.2)
        XCTAssertFalse(gate.update(down: false, now: 1.3))
    }
}
