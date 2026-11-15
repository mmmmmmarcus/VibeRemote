import CoreAudio
import XCTest
@testable import VibeRemote

final class DictationMicrophoneTests: XCTestCase {
    private let builtIn = DictationAudioDevice.Microphone(id: 10, uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone", builtIn: true)
    private let headset = DictationAudioDevice.Microphone(id: 20, uid: "AA-BB-CC:input", name: "AirPods", builtIn: false)
    private let usb = DictationAudioDevice.Microphone(id: 30, uid: "USB-1", name: "Yeti", builtIn: false)

    /// Same as System follows the system input; when that is the bridge's own device (not in
    /// the list), it takes the built-in microphone.
    func testSameAsSystemFollowsTheSystemInputUnlessItIsTheBridge() {
        let all = [builtIn, headset, usb]
        XCTAssertEqual(DictationAudioDevice.resolve(choice: nil, available: all, systemInput: 20), headset)
        XCTAssertEqual(DictationAudioDevice.resolve(choice: nil, available: all, systemInput: 99), builtIn)
        XCTAssertEqual(DictationAudioDevice.resolve(choice: nil, available: all, systemInput: nil), builtIn)
        XCTAssertEqual(DictationAudioDevice.resolve(choice: nil, available: [usb], systemInput: 99), usb)
        XCTAssertNil(DictationAudioDevice.resolve(choice: nil, available: [], systemInput: 99))
    }

    /// A chosen device wins over the system input, by UID; a disconnected one falls back.
    func testChosenMicrophoneWinsAndFallsBackWhenDisconnected() {
        let choice = DictationMicrophoneChoice(uid: "USB-1", name: "Yeti")
        XCTAssertEqual(DictationAudioDevice.resolve(choice: choice, available: [builtIn, headset, usb], systemInput: 20), usb)
        XCTAssertEqual(DictationAudioDevice.resolve(choice: choice, available: [builtIn, headset], systemInput: 20), headset)
        XCTAssertEqual(DictationAudioDevice.resolve(choice: choice, available: [builtIn, headset], systemInput: 99), builtIn)
    }

    func testHotkeyMicrophoneChoiceIsSavedAndCleared() throws {
        let suite = "DictationMicrophoneTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertNil(DictationSettings.load(from: defaults).hotkeyMicrophone)
        var settings = DictationSettings()
        settings.hotkeyMicrophone = DictationMicrophoneChoice(uid: "USB-1", name: "Yeti")
        settings.save(to: defaults)
        XCTAssertEqual(DictationSettings.load(from: defaults).hotkeyMicrophone, settings.hotkeyMicrophone)
        settings.hotkeyMicrophone = nil
        settings.save(to: defaults)
        XCTAssertNil(DictationSettings.load(from: defaults).hotkeyMicrophone)
    }
}
