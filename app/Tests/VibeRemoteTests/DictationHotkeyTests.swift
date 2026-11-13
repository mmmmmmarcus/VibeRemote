import XCTest
import Carbon.HIToolbox
import CoreGraphics
@testable import VibeRemote

final class DictationHotkeyTests: XCTestCase {
    private let option = CGEventFlags.maskAlternate.rawValue
    private let command = CGEventFlags.maskCommand.rawValue

    func testHoldAloneDictatesAndReleaseEnds() {
        var gate = DictationHotkeyGate()
        let key = DictationHotkey.rightOption
        XCTAssertEqual(gate.flagsChanged(keyCode: kVK_RightOption, flags: option | key.deviceMask, hotkey: key), .begin)
        XCTAssertTrue(gate.held)
        XCTAssertEqual(gate.flagsChanged(keyCode: kVK_RightOption, flags: 0, hotkey: key), .end)
        XCTAssertFalse(gate.held)
    }

    func testTheOtherSideOfTheSameModifierIsIgnored() {
        var gate = DictationHotkeyGate()
        // Left Option sets the same generic Option flag, but its own device bit.
        XCTAssertEqual(gate.flagsChanged(keyCode: kVK_Option, flags: option | DictationHotkey.leftOption.deviceMask,
                                         hotkey: .rightOption), .none)
        XCTAssertFalse(gate.held)
    }

    func testAShortcutCancelsInsteadOfTyping() {
        var gate = DictationHotkeyGate()
        let key = DictationHotkey.rightOption
        XCTAssertEqual(gate.flagsChanged(keyCode: kVK_RightOption, flags: option | key.deviceMask, hotkey: key), .begin)
        // Option+← while held: a shortcut, so the hold is dropped once and its release types nothing.
        XCTAssertEqual(gate.keyDown(), .cancel)
        XCTAssertEqual(gate.keyDown(), .none)
        XCTAssertEqual(gate.flagsChanged(keyCode: kVK_RightOption, flags: 0, hotkey: key), .none)
        // Another modifier joining also makes it a chord.
        XCTAssertEqual(gate.flagsChanged(keyCode: kVK_RightOption, flags: option | key.deviceMask, hotkey: key), .begin)
        XCTAssertEqual(gate.flagsChanged(keyCode: kVK_Shift, flags: option | key.deviceMask | CGEventFlags.maskShift.rawValue,
                                         hotkey: key), .cancel)
    }

    func testPressedWhileAnotherModifierIsDownNeverStarts() {
        var gate = DictationHotkeyGate()
        let key = DictationHotkey.rightCommand
        XCTAssertEqual(gate.flagsChanged(keyCode: kVK_RightCommand, flags: command | key.deviceMask | option, hotkey: key), .none)
        XCTAssertEqual(gate.flagsChanged(keyCode: kVK_RightCommand, flags: option, hotkey: key), .none)
    }

    func testChoosingNoneDuringAHoldCancelsIt() {
        var gate = DictationHotkeyGate()
        let key = DictationHotkey.leftControl
        XCTAssertEqual(gate.flagsChanged(keyCode: kVK_Control, flags: CGEventFlags.maskControl.rawValue | key.deviceMask,
                                         hotkey: key), .begin)
        XCTAssertEqual(gate.flagsChanged(keyCode: kVK_Control, flags: 0, hotkey: .none), .cancel)
    }

    func testEveryHotkeyHasADistinctKeyAndSideBit() {
        let keys = DictationHotkey.allCases.filter { $0 != .none }
        XCTAssertEqual(Set(keys.compactMap(\.keyCode)).count, keys.count)
        XCTAssertEqual(Set(keys.map(\.deviceMask)).count, keys.count)
        XCTAssertNil(DictationHotkey.none.keyCode)
    }

    func testHotkeyRoundTripsWithDictationSettings() throws {
        let suite = "DictationHotkeyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(DictationSettings.load(from: defaults).hotkey, .none)
        var settings = DictationSettings.load(from: defaults)
        settings.hotkey = .rightControl
        settings.save(to: defaults)
        XCTAssertEqual(DictationSettings.load(from: defaults).hotkey, .rightControl)
    }
}
