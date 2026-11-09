import AppKit
import AVFoundation
import CoreAudio
import Speech

// VibeRemote Dictation: Siri held = record, Siri released (after the bridge drains) = turn the
// clip into text and type it into the focused app. The mechanism mirrors mapping Siri to a
// third-party dictation app — the remote still streams audio only while Siri is physically
// held — but VibeRemote records the bridge's own virtual device and runs the speech service
// itself, so no other app or shortcut is involved. Transcripts are never logged.

/// The user's dictation choices. Keys live in the Keychain, everything else in defaults.
struct DictationSettings: Equatable, Sendable {
    var provider: DictationProvider = .apple
    /// A BCP-47 identifier, or empty for automatic.
    var language = ""
    var whisperModel = WhisperModelCatalog.defaultModel
    var openAIModel = OpenAIDictationEngine.defaultModel
    /// Only the older Volcengine console issues an App ID; new-console keys leave it empty.
    var seedAppID = ""
    var seedResourceID = SeedASRDictationEngine.defaultResourceID

    private enum Key {
        static let provider = "dictationProvider"
        static let language = "dictationLanguage"
        static let whisperModel = "dictationWhisperModel"
        static let openAIModel = "dictationOpenAIModel"
        static let seedAppID = "dictationSeedAppID"
        static let seedResourceID = "dictationSeedResourceID"
    }

    static func load(from defaults: UserDefaults = .standard) -> DictationSettings {
        var settings = DictationSettings()
        if let raw = defaults.string(forKey: Key.provider), let provider = DictationProvider(rawValue: raw) {
            settings.provider = provider
        }
        settings.language = defaults.string(forKey: Key.language) ?? ""
        settings.whisperModel = defaults.string(forKey: Key.whisperModel).flatMap { $0.isEmpty ? nil : $0 } ?? WhisperModelCatalog.defaultModel
        settings.openAIModel = defaults.string(forKey: Key.openAIModel).flatMap { $0.isEmpty ? nil : $0 } ?? OpenAIDictationEngine.defaultModel
        settings.seedAppID = defaults.string(forKey: Key.seedAppID) ?? ""
        settings.seedResourceID = defaults.string(forKey: Key.seedResourceID).flatMap { $0.isEmpty ? nil : $0 } ?? SeedASRDictationEngine.defaultResourceID
        return settings
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(provider.rawValue, forKey: Key.provider)
        defaults.set(language, forKey: Key.language)
        defaults.set(whisperModel, forKey: Key.whisperModel)
        defaults.set(openAIModel, forKey: Key.openAIModel)
        defaults.set(seedAppID.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Key.seedAppID)
        defaults.set(seedResourceID.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Key.seedResourceID)
    }
}

/// Bring-your-own keys, one Keychain item per cloud service, never in defaults or logs.
enum DictationKeychain {
    private static let account = "api-key"

    private static func service(for provider: DictationProvider) -> String? {
        switch provider {
        case .openAI: return "com.viberemote.dictation.openai"
        case .seedASR: return "com.viberemote.dictation.seedasr"
        case .apple, .whisperKit: return nil
        }
    }

    static func key(for provider: DictationProvider) -> String? {
        guard let service = service(for: provider) else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    @discardableResult
    static func setKey(_ key: String?, for provider: DictationProvider) -> Bool {
        guard let service = service(for: provider) else { return false }
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(match as CFDictionary)
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return true }
        var add = match
        add[kSecValueData as String] = Data(trimmed.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}

// MARK: - Recording

/// Finds the bridge's virtual input: the same device names, in the same order, the bridge
/// plays into (`MicrophoneBridgeManager.supportedOutputDeviceNames`).
enum DictationAudioDevice {
    static func inputID() -> AudioDeviceID? {
        let devices = allDevices()
        for name in MicrophoneBridgeManager.supportedOutputDeviceNames {
            if let id = devices.first(where: { self.name(of: $0) == name && hasInput($0) }) { return id }
        }
        return nil
    }

    private static func allDevices() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var devices = Array(repeating: AudioDeviceID(), count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else { return [] }
        return devices
    }

    private static func name(of id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var name = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &name) { AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0) }
        return status == noErr ? name as String : nil
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                 mScope: kAudioObjectPropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }
}

/// Records one hold from the virtual device, resampled to 16 kHz mono as it arrives.
/// The engine runs only between Siri down and the end of the hold, so the system's
/// microphone indicator is on only while the user is actually dictating.
final class DictationRecorder: @unchecked Sendable {
    /// A dropped release must not record forever.
    static let maximumDuration: TimeInterval = 300

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    // Touched only by the tap, which AVAudioEngine calls serially on its render thread.
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: DictationAudio.sampleRate,
                                       channels: 1, interleaved: false)!

    func start(deviceID: AudioDeviceID) throws {
        let input = engine.inputNode
        guard let unit = input.audioUnit else { throw DictationError("Could not open the VibeRemote input.") }
        var device = deviceID
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { throw DictationError("Could not select the VibeRemote input (\(status)).") }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let converter = AVAudioConverter(from: format, to: target) else {
            throw DictationError("The VibeRemote input has no usable audio format.")
        }
        self.converter = converter
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            self?.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw DictationError("Could not start recording: \(error.localizedDescription)")
        }
    }

    func stop() -> DictationAudio {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock(); defer { lock.unlock() }
        return DictationAudio(samples: samples)
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        guard let converter, buffer.frameLength > 0 else { return }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        // `.noDataNow` (not end of stream) keeps the resampler's filter state between taps.
        _ = converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, output.frameLength > 0, let channel = output.floatChannelData?[0] else { return }
        let chunk = UnsafeBufferPointer(start: channel, count: Int(output.frameLength))
        lock.lock(); defer { lock.unlock() }
        guard Double(samples.count) < Self.maximumDuration * DictationAudio.sampleRate else { return }
        samples.append(contentsOf: chunk)
    }
}

// MARK: - Typing

/// Types text into whatever has keyboard focus, as Unicode keyboard events — the same way
/// the skill-picker trigger is typed. Never the clipboard: the user's pasteboard stays theirs.
enum DictationTyper {
    /// CGEvent carries at most 20 UTF-16 units per event; split on character boundaries so
    /// an emoji or a combining sequence never straddles two events.
    static func chunks(_ text: String, limit: Int = 20) -> [String] {
        var result: [String] = []
        var current = ""
        for character in text {
            if current.utf16.count + character.utf16.count > limit, !current.isEmpty {
                result.append(current)
                current = ""
            }
            current.append(character)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// A single line: dictation types into chat composers, where a newline could submit.
    static func normalized(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor
    static func type(_ text: String) async {
        for chunk in chunks(text) {
            RemoteInputHandler.makeKeyEvent(keyCode: 0, flags: [], keyDown: true, text: chunk)?.post(tap: .cghidEventTap)
            RemoteInputHandler.makeKeyEvent(keyCode: 0, flags: [], keyDown: false, text: chunk)?.post(tap: .cghidEventTap)
            try? await Task.sleep(nanoseconds: 4_000_000)
        }
    }
}

// MARK: - Controller

/// One hold at a time: begin on Siri down, end once the bridge has drained after release.
@MainActor
final class DictationController: ObservableObject {
    static let shared = DictationController()

    enum Phase: Equatable {
        case idle
        case recording
        case transcribing
        case finished(String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    private var recorder: DictationRecorder?
    private var recordingStartedAt = Date.distantPast
    /// Increments per hold so a slow transcript from an older hold never overwrites a newer
    /// hold's status. Its text is still typed: the user spoke it.
    private var holdCount = 0

    /// Short enough that a tap of Siri types nothing.
    static let minimumDuration: TimeInterval = 0.3
    /// After the bridge reports its output drained, the HAL loopback still holds a few
    /// milliseconds that have not reached the input tap yet.
    static let drainGrace: UInt64 = 150_000_000

    func begin() {
        guard recorder == nil else { return }
        let settings = DictationSettings.load()
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            fail("Allow VibeRemote to use the microphone, then hold Siri again.")
            return
        default:
            fail("Microphone access is off for VibeRemote. Turn it on in System Settings › Privacy & Security › Microphone.")
            return
        }
        if settings.provider == .apple, SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            SFSpeechRecognizer.requestAuthorization { _ in }
        }
        if settings.provider.needsAPIKey, DictationKeychain.key(for: settings.provider) == nil {
            fail("Add your \(settings.provider.title) key in Settings › Dictation.")
            return
        }
        guard let device = DictationAudioDevice.inputID() else {
            fail("The VibeRemote audio device is missing. Install the audio driver in Settings › Remote.")
            return
        }
        let recorder = DictationRecorder()
        do {
            try recorder.start(deviceID: device)
        } catch {
            fail(error.localizedDescription)
            return
        }
        self.recorder = recorder
        recordingStartedAt = Date()
        holdCount += 1
        phase = .recording
        rmDebug("🗣 Dictation recording (\(settings.provider.rawValue))")
    }

    func end() {
        guard let recorder else { return }
        self.recorder = nil
        let hold = holdCount
        let settings = DictationSettings.load()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.drainGrace)
            let audio = recorder.stop()
            await self.finish(audio, settings: settings, hold: hold)
        }
    }

    private func finish(_ audio: DictationAudio, settings: DictationSettings, hold: Int) async {
        guard audio.duration >= Self.minimumDuration else {
            if hold == holdCount { phase = .idle }
            return
        }
        guard audio.rms > 0.000_1 else {
            if hold == holdCount { fail("No audio arrived. Check that the voice bridge is running.") }
            return
        }
        if hold == holdCount { phase = .transcribing }
        let started = Date()
        do {
            let engine = try await Self.engine(for: settings)
            let text = DictationTyper.normalized(try await engine.transcribe(audio, language: settings.language))
            let elapsed = Date().timeIntervalSince(started)
            rmDebug(String(format: "🗣 Dictation %@: %.1f s audio → %d chars in %.2f s",
                           settings.provider.rawValue, audio.duration, text.count, elapsed))
            guard !text.isEmpty else {
                if hold == holdCount { phase = .finished("No speech recognized.") }
                return
            }
            await DictationTyper.type(text)
            if hold == holdCount {
                phase = .finished(String(format: "Typed %d characters with %@ in %.1f s.",
                                         text.count, settings.provider.title, elapsed))
            }
        } catch {
            rmDebug("⚠️ Dictation \(settings.provider.rawValue) failed: \(error.localizedDescription)")
            if hold == holdCount { fail(error.localizedDescription) }
        }
    }

    private func fail(_ message: String) {
        phase = .failed(message)
        NSSound.beep()
    }

    static func engine(for settings: DictationSettings) async throws -> any DictationEngine {
        switch settings.provider {
        case .apple:
            return AppleDictationEngine()
        case .whisperKit:
            await WhisperKitDictationEngine.shared.select(model: settings.whisperModel)
            return WhisperKitDictationEngine.shared
        case .openAI:
            guard let key = DictationKeychain.key(for: .openAI) else { throw DictationError("Add your OpenAI key in Settings › Dictation.") }
            return OpenAIDictationEngine(apiKey: key, model: settings.openAIModel)
        case .seedASR:
            guard let key = DictationKeychain.key(for: .seedASR) else { throw DictationError("Add your Seed ASR key in Settings › Dictation.") }
            return SeedASRDictationEngine(accessKey: key, appID: settings.seedAppID, resourceID: settings.seedResourceID)
        }
    }
}
