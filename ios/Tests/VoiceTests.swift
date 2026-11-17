import XCTest
@testable import vvhisper

final class VoiceTests: XCTestCase {
    func testHapticStrengthHasOffAndClampedSteppedValues() {
        XCTAssertEqual(KeyboardPreferences.normalizedStrength(-1), 0)
        XCTAssertEqual(KeyboardPreferences.normalizedStrength(0), 0)
        XCTAssertEqual(KeyboardPreferences.normalizedStrength(0.46), 0.45)
        XCTAssertEqual(KeyboardPreferences.normalizedStrength(2), 1)
        XCTAssertEqual(KeyboardPreferences.normalizedStrength(.nan), 0.45)
    }
    func testTapAndHoldAreExclusive() {
        var gate = HoldGate(); gate.press(at: 0)
        XCTAssertFalse(gate.advance(to: 0.2)); XCTAssertTrue(gate.release())
        gate.press(at: 1); XCTAssertTrue(gate.advance(to: 1.5)); XCTAssertFalse(gate.advance(to: 2)); XCTAssertFalse(gate.release())
    }
    func testCancelNeverTypes() {
        var gate = HoldGate(); gate.press(at: 0); gate.cancel(); XCTAssertFalse(gate.release()); XCTAssertFalse(gate.advance(to: 1))
    }
    func testSeedFraming() throws {
        XCTAssertEqual(Array(SeedStreamFrame.audio(Data([1, 2]), last: true)), [0x11,0x22,0,0,0,0,0,2,1,2])
        XCTAssertThrowsError(try SeedStreamFrame.parse(Data([0x11,0x90,0,0,0,0,0,20])))
        let payload = Data("{\"result\":{\"text\":\"Hello 世界\"}}".utf8)
        XCTAssertEqual(SeedStreamResult.parse(payload)?.text, "Hello 世界")
    }
    func testReadinessExpires() {
        XCTAssertFalse(VoiceReadiness(ready: true, updatedAt: Date().addingTimeInterval(-3), expiresAt: Date().addingTimeInterval(100)).isFresh)
        XCTAssertFalse(VoiceReadiness(ready: true, expiresAt: Date().addingTimeInterval(-1)).isFresh)
        XCTAssertTrue(VoiceReadiness(ready: true, expiresAt: Date().addingTimeInterval(100)).isFresh)
    }
    func testVoiceActivationRequiresFreshMatchingRequest() {
        let now = Date()
        let request = VoiceActivationRequest(createdAt: now)
        XCTAssertTrue(request.accepts(request.url, at: now.addingTimeInterval(1)))
        XCTAssertFalse(request.accepts(request.url, at: now.addingTimeInterval(10)))
        XCTAssertFalse(request.accepts(request.url, at: now.addingTimeInterval(-1)))
        XCTAssertFalse(request.accepts(VoiceActivationRequest(createdAt: now).url, at: now))
        XCTAssertFalse(request.accepts(URL(string: "vvhisper://voice")!, at: now))
        XCTAssertFalse(request.accepts(URL(string: "vvhisper://other?request=\(request.id.uuidString)")!, at: now))
        XCTAssertFalse(request.accepts(URL(string: request.url.absoluteString + "&request=\(request.id.uuidString)")!, at: now))
    }
    func testReturnDestinationAllowsSystemHostsButRejectsSelfAndMalformedValues() {
        for value in ["com.apple.Preferences", "com.apple.mobilenotes", "net.whatsapp.WhatsApp"] {
            XCTAssertEqual(VoiceActivationRequest(returnBundleIdentifier: value).returnDestination, value)
        }
        for value in ["", "com.vvhisper.ios", "com.vvhisper.ios.keyboard", "com.apple.springboard", "(null)", "https://example.com", "com.example.app\n", String(repeating: "a", count: 256) + ".app"] {
            XCTAssertNil(VoiceActivationRequest(returnBundleIdentifier: value).returnDestination)
        }
        XCTAssertNil(VoiceActivationRequest().returnDestination)
    }
}
