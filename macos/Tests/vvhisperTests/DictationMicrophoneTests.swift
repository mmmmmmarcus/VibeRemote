import CoreAudio
import XCTest
@testable import vvhisper

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

    func testNativeMicrophoneRatesConvertToStreaming16kHzWithoutChangingDurationOrPitch() throws {
        for rate in [16_000.0, 44_100.0, 48_000.0] {
            let converter = try DictationMicrophoneResampler(sampleRate: rate)
            let input = (0..<Int(rate)).map { Float(0.2 * sin(2 * .pi * 1_000 * Double($0) / rate)) }
            var output: [Float] = []
            // Deliberately split across non-integral conversion boundaries.
            for start in stride(from: 0, to: input.count, by: 1_117) {
                output += converter.append(Array(input[start..<min(start + 1_117, input.count)]))
            }
            output += converter.finish()
            XCTAssertEqual(Double(output.count), 16_000, accuracy: 64, "rate=\(rate)")
            XCTAssertGreaterThan(DictationAudio(samples: output).rms, 0.1)
            let crossings = zip(output, output.dropFirst()).filter { $0 < 0 && $1 >= 0 }.count
            XCTAssertEqual(Double(crossings), 1_000, accuracy: 4, "pitch changed at rate=\(rate)")
        }
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
