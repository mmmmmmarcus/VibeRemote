import ApplicationServices
import XCTest
@testable import VibeRemote

final class AutoComputerUseTests: XCTestCase {
    /// Only editable text that takes a caret keeps a hold as dictation; anything else (a list,
    /// a button, a web page, nothing at all) sends it to Computer Use.
    func testOnlyAFocusedTextInputWithASelectionCountsAsATextField() {
        for role in [kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole] {
            XCTAssertTrue(AutoComputerUse.isTextInput(role: role, hasSelection: true))
            XCTAssertFalse(AutoComputerUse.isTextInput(role: role, hasSelection: false), "no caret, no dictation")
        }
        for role in [kAXButtonRole, kAXListRole, "AXWebArea", kAXGroupRole] {
            XCTAssertFalse(AutoComputerUse.isTextInput(role: role, hasSelection: true))
        }
        XCTAssertFalse(AutoComputerUse.isTextInput(role: nil, hasSelection: true))
        XCTAssertFalse(UserDefaults(suiteName: "AutoComputerUseTests.\(UUID().uuidString)")!.bool(forKey: AutoComputerUse.enabledKey),
                       "off unless switched on")
    }

    /// Dictating into a bar that already holds words adds to them.
    @MainActor
    func testDictationAddsToWhatTheBarAlreadyHolds() {
        let target = DictationController.HoldTarget()
        XCTAssertEqual(target.joined("open the log"), "open the log")
        target.base = "In Safari"
        XCTAssertEqual(target.joined("open the log"), "In Safari open the log")
        XCTAssertEqual(target.joined(""), "In Safari")
        target.base = "In Safari "
        XCTAssertEqual(target.joined("open"), "In Safari open")
    }

    /// While the probe has not answered, partials are kept, not typed; once routed, the latest
    /// one goes to its target at once and later ones follow.
    @MainActor
    func testPartialsWaitForTheRouteThenFollowIt() {
        let hold = DictationLiveHold(typewriter: DictationTypewriter(after: nil))
        hold.route(.pending)
        hold.handle(.partial(SeedStreamResult(text: "open the", definiteUtterances: 0)))
        var shown: [String] = []
        hold.route(.handoff { shown.append($0) })
        XCTAssertEqual(shown, ["open the"])
        hold.handle(.partial(SeedStreamResult(text: "open the deploy log", definiteUtterances: 0)))
        XCTAssertEqual(shown, ["open the", "open the deploy log"])
        XCTAssertEqual(hold.typewriter.expectedCaret, nil, "nothing was typed into any app")
    }
}
