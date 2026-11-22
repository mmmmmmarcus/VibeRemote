import XCTest
import AppKit
@testable import vvhisper

final class DictationNoticeTests: XCTestCase {
    func testActionableFailuresAndProviderTextPrivacy() {
        let cases = [
            ("Accessibility permission is missing", "DICT-ACCESS"),
            ("Microphone access is off for vvhisper", "DICT-MIC-PERMISSION"),
            ("No audio arrived from the Mac's microphone.", "DICT-AUDIO"),
            ("Seed ASR did not answer (error 401: secret-private-response).", "DICT-CREDENTIALS"),
            ("HTTP 429 quota exceeded", "DICT-SERVICE-LIMIT"),
            ("focus moved to another field", "DICT-INSERT"),
            ("Server returned secret-private-response", "DICT-RECOGNITION"),
        ]
        for (detail, code) in cases {
            let notice = DictationNotice.failure(detail)
            XCTAssertEqual(notice.code, code)
            XCTAssertFalse(notice.message.contains("secret-private-response"))
        }
        XCTAssertTrue(DictationNotice.failure("Accessibility permission is missing").accessibilityPermission)
        XCTAssertFalse(DictationNotice.failure("No audio").accessibilityPermission)
        XCTAssertEqual(DictationNotice.polishing.code, "DICT-POLISH")
    }

    @MainActor
    func testFeedbackPanelCannotTakeTypingFocus() {
        let panel = DictationNoticePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
    }
}
