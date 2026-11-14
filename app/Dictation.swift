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
    /// Seed ASR only: recognize while Siri is held and type partial text as it arrives,
    /// correcting it as recognition firms up. Off falls back to one transcription on release.
    var seedStreaming = true
    var seedStreamResourceID = SeedStreamFrame.defaultResourceID
    /// Seed ASR only: Volcengine's `enable_ddc` (语义顺滑) drops filler words (嗯, 啊, 那个),
    /// stutters and repeated phrases from the result. Default on (2026-11-12, user's request).
    var seedRemoveFillers = true
    /// Seed ASR only: send the text before the caret as recognition context, so the refinement
    /// knows the topic and the names already in use. Default on (2026-11-12, user's request);
    /// that text leaves the Mac with the audio, which is why it is a setting.
    var seedEditorContext = true
    /// Words dictation should get right; see `DictationDictionary`.
    var dictionary: [DictationDictionaryEntry] = []
    /// A keyboard modifier that dictates like a Siri hold, through the Mac's own microphone.
    var hotkey: DictationHotkey = .none

    private enum Key {
        static let provider = "dictationProvider"
        static let language = "dictationLanguage"
        static let whisperModel = "dictationWhisperModel"
        static let openAIModel = "dictationOpenAIModel"
        static let seedAppID = "dictationSeedAppID"
        static let seedResourceID = "dictationSeedResourceID"
        static let seedStreaming = "dictationSeedStreaming"
        static let seedStreamResourceID = "dictationSeedStreamResourceID"
        static let seedRemoveFillers = "dictationSeedRemoveFillers"
        static let seedEditorContext = "dictationSeedEditorContext"
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
        settings.seedStreaming = defaults.object(forKey: Key.seedStreaming) as? Bool ?? true
        settings.seedStreamResourceID = defaults.string(forKey: Key.seedStreamResourceID).flatMap { $0.isEmpty ? nil : $0 } ?? SeedStreamFrame.defaultResourceID
        settings.seedRemoveFillers = defaults.object(forKey: Key.seedRemoveFillers) as? Bool ?? true
        settings.seedEditorContext = defaults.object(forKey: Key.seedEditorContext) as? Bool ?? true
        settings.dictionary = DictationDictionary.load(from: defaults)
        settings.hotkey = DictationHotkey.load(from: defaults)
        return settings
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(provider.rawValue, forKey: Key.provider)
        defaults.set(language, forKey: Key.language)
        defaults.set(whisperModel, forKey: Key.whisperModel)
        defaults.set(openAIModel, forKey: Key.openAIModel)
        defaults.set(seedAppID.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Key.seedAppID)
        defaults.set(seedResourceID.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Key.seedResourceID)
        defaults.set(seedStreaming, forKey: Key.seedStreaming)
        defaults.set(seedStreamResourceID.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Key.seedStreamResourceID)
        defaults.set(seedRemoveFillers, forKey: Key.seedRemoveFillers)
        defaults.set(seedEditorContext, forKey: Key.seedEditorContext)
        DictationDictionary.save(dictionary, to: defaults)
        defaults.set(hotkey.rawValue, forKey: DictationHotkey.defaultsKey)
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

    /// The Mac's own microphone, for the keyboard hotkey (the remote's microphone only streams
    /// while Siri is physically held). The system input when it is a real microphone, else the
    /// built-in one, else any other input that is not one of the bridge's virtual devices. The
    /// system input setting itself is never changed: the bridge usually points it at its own
    /// virtual device, and switching it back and forth is what the user rejected on 2026-10-31.
    static func macMicrophoneID() -> AudioDeviceID? {
        let virtual = Set(MicrophoneBridgeManager.supportedOutputDeviceNames)
        func usable(_ id: AudioDeviceID) -> Bool { hasInput(id) && !(name(of: id).map(virtual.contains) ?? false) }
        if let current = defaultInput(), usable(current) { return current }
        let devices = allDevices().filter(usable)
        return devices.first(where: { transportType($0) == kAudioDeviceTransportTypeBuiltIn }) ?? devices.first
    }

    private static func defaultInput() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID()
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr && id != 0 ? id : nil
    }

    private static func transportType(_ id: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var type: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &type) == noErr ? type : 0
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
    /// Set before the tap is installed and only read by it afterwards.
    private var onSamples: (@Sendable ([Float]) -> Void)?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: DictationAudio.sampleRate,
                                       channels: 1, interleaved: false)!

    /// `onSamples` receives each tap's 16 kHz mono samples on the render thread, roughly every
    /// 40 ms: the level meter and the streaming session both read them there.
    func start(deviceID: AudioDeviceID, onSamples: (@Sendable ([Float]) -> Void)? = nil) throws {
        self.onSamples = onSamples
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
        onSamples?(Array(chunk))
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

// MARK: - Indicator

/// Turns the recorder's raw RMS into what the indicator shows. The bridge's virtual input is
/// digital silence until the remote's first voice frame lands, so the floor sits well above
/// zero signal. The ceiling comes from real holds (2026-11-09): speech peaked at -7 dBFS, and a
/// -14 ceiling kept ordinary talking pinned at full, so the mic looked static instead of moving
/// with the voice. -6 leaves syllables visibly rising and falling below the top. The floor
/// dropped from -45 to -60 on 2026-11-13 (user's request): the remote is spoken to quietly,
/// whispered holds peaked at -33 to -35 dBFS with syllables lower still, so the mic barely
/// filled. Clips' quietest windows are digital silence (-120), so this does not light up on noise.
enum DictationLevelMeter {
    static let floorDecibels: Float = -60
    static let ceilingDecibels: Float = -6

    static func rms<C: Collection>(_ samples: C) -> Float where C.Element == Float {
        guard !samples.isEmpty else { return 0 }
        return (samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }

    static func decibels(rms: Float) -> Float { 20 * log10(max(rms, 0.000_001)) }

    static func normalized(rms: Float) -> CGFloat {
        let value = (decibels(rms: rms) - floorDecibels) / (ceilingDecibels - floorDecibels)
        return CGFloat(min(1, max(0, value)))
    }

    /// Fast attack, slow release: syllables register at once, and the mic does not flicker
    /// empty between them.
    static func eased(_ current: CGFloat, toward target: CGFloat, elapsed: TimeInterval) -> CGFloat {
        let time = target > current ? 0.035 : 0.18
        return current + (target - current) * CGFloat(1 - exp(-max(0, elapsed) / time))
    }

    /// The quietest 50 ms window of a finished clip: the bridge's background noise, which is
    /// what the meter's floor should sit just above.
    static func floorDecibels(_ samples: [Float], window: Int = 800) -> Float {
        guard samples.count >= window else { return decibels(rms: rms(samples[...])) }
        var floor = Float.greatestFiniteMagnitude
        var start = 0
        while start + window <= samples.count {
            floor = min(floor, rms(samples[start..<(start + window)]))
            start += window
        }
        return decibels(rms: floor)
    }

    /// The loudest 50 ms window of a finished clip, for calibrating the meter from the log.
    static func peakDecibels(_ samples: [Float], window: Int = 800) -> Float {
        guard !samples.isEmpty else { return decibels(rms: 0) }
        var peak: Float = 0
        var start = 0
        while start < samples.count {
            peak = max(peak, rms(samples[start..<min(samples.count, start + window)]))
            start += window
        }
        return decibels(rms: peak)
    }
}

/// The orange twin of the caret cursor. While a hold is recording it stands at the insertion
/// point with a mic that fills with the live input level, so the user can see that VibeRemote
/// is hearing them and where the words will land. While the clip is transcribed, a spinner
/// replaces the mic. Reuses `CaretOverlay`, so it is the same silhouette the user already
/// knows from caret positioning; a Siri press cancels positioning, so the two are never on
/// screen together. An empty editor has no glyphs to measure, so the bubble starts at its
/// leading edge, where the first word will land; see `CaretInsertionPoint`.
@MainActor
final class DictationIndicator {
    private let overlay = CaretOverlay()
    private let insertion = CaretInsertionPoint()
    /// Between `listen` and `hide`: the hold wants a bubble, even before a read has placed one.
    private var active = false
    private var shown = false
    private var glyph: CaretGlyph = .listening
    /// Bumped by every `listen` and `hide`, so a read that lands after the hold moved on is
    /// dropped instead of resurrecting the bubble.
    private var generation = 0
    /// Readings dropped this hold because the editor had not caught up with the typewriter.
    private var staleReads = 0

    /// Also used by an aluminum re-press that arrives while the previous hold is still being
    /// transcribed: the bubble is already up, so it only turns back into a listening mic.
    func listen() {
        glyph = .listening
        if shown {
            overlay.setGlyph(.listening)
            overlay.setLevel(0)
            return
        }
        active = true
        generation += 1
        firstRead(token: generation, attempt: 1)
    }

    /// Some apps drop an accessibility query now and then (ChatGPT answers most within a
    /// millisecond but some take 40–120 ms or report no value), so a failed first read is
    /// retried briefly before the hold is left without a cursor until its first words arrive.
    private func firstRead(token: Int, attempt: Int) {
        insertion.read { [weak self] point in
            guard let self, token == self.generation, self.active, !self.shown else { return }
            if let point { self.place(point); return }
            guard attempt < 4 else {
                rmDebug("🗣 Dictation indicator: no editable caret in the focused element (\(self.insertion.lastFailure ?? "unknown"))")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                MainActor.assumeIsolated { self?.firstRead(token: token, attempt: attempt + 1) }
            }
        }
    }

    func hear(rms: Float) {
        guard shown else { return }
        overlay.setLevel(DictationLevelMeter.normalized(rms: rms))
    }

    func recognize() {
        glyph = .recognizing
        guard shown else { return }
        overlay.setGlyph(.recognizing)
    }

    /// Streaming types while the bubble is up, so it moves with the caret to the end of the
    /// words. If the first read found no caret, the first words can still bring the bubble up.
    /// A failed read keeps the last good position rather than guessing.
    ///
    /// `expected` is where the typewriter has put the caret (UTF-16). Chromium updates its
    /// accessibility tree a little after each keystroke, so a reading can still be at an older
    /// caret. That position is consistent (offset and rectangle from the same tree), so it is
    /// drawn, and `behind` asks the caller to read again at once until it catches up. (Holding
    /// such readings back, as tried first, froze the bubble while words streamed continuously,
    /// because every keystroke restarted the wait: "off after the first word", 2026-11-10.)
    func follow(expected: Int?, behind: @escaping @MainActor @Sendable () -> Void) {
        guard active else { return }
        let token = generation
        insertion.read { [weak self] point in
            guard let self, token == self.generation, self.active else { return }
            // An empty read is retried like a lagging one: right after a keystroke Chromium's
            // value and text markers can disagree, which fails calibration (and calibration is
            // what every later read needs). Without a retry the last keystroke's failed read
            // was final, and the bubble never followed in Claude or ChatGPT (2026-11-10).
            guard let point else { behind(); return }
            self.place(point, expected: expected)
            if let expected, [.glyph, .afterGlyph, .textEnd, .wrappedEnd].contains(point.accuracy), point.offset != expected {
                self.staleReads += 1
                behind()
            }
        }
    }

    /// Each change of line or accuracy this hold, relative to the editor's top-left: offsets,
    /// counts and points only, never text (2026-11-12, finding where the cursor goes after a
    /// line break).
    private var trace: [String] = []

    private func place(_ point: CaretInsertionPoint.Reading, expected: Int? = nil) {
        // Every read whose offset or position changed: accuracy initial, offset/expected, editor
        // length, then the caret relative to the editor's top-left.
        let entry = String(format: "%@%d%@ L%@ @%.0f,%.0f", String(point.accuracy.rawValue.prefix(1)), point.offset,
                           expected.map { "/\($0)" } ?? "", point.shape.split(separator: " ").dropFirst().first.map { String($0.dropLast()) } ?? "?",
                           point.caret.minX - point.editor.minX, point.caret.minY - point.editor.minY)
        if trace.count < 160, trace.last != entry { trace.append(entry) }
        overlay.show(caret: point.caret, editor: point.editor, progress: 1, style: .dictation)
        guard !shown else { return }
        shown = true
        rmDebug("🗣 Dictation indicator shown (\(point.accuracy.rawValue))")
        overlay.setGlyph(glyph)
        overlay.setLevel(0)
    }

    /// Called before the transcript is typed: the caret moves as the words land, and a
    /// bubble left behind at the old position would be pointing at nothing.
    func hide() {
        active = false
        generation += 1
        let timing = insertion.takeTimings()
        let reasons = insertion.takeFailureReasons()
        if !reasons.isEmpty { rmDebug("🗣 Dictation indicator fallbacks: " + reasons) }
        if timing.count > 1 {
            let failed = timing.failed > 0 ? ", \(timing.failed) empty (last: \(insertion.lastFailure ?? "unknown"))" : ""
            rmDebug(String(format: "🗣 Dictation indicator: %d caret reads (%d behind the typewriter%@), mean %.0f ms, slowest %.0f ms",
                           timing.count, staleReads, failed, timing.mean, timing.slowest))
        }
        if !trace.isEmpty {
            rmDebug("🗣 Dictation indicator reads: " + trace.joined(separator: " "))
        }
        trace.removeAll()
        staleReads = 0
        guard shown else { return }
        shown = false
        overlay.hide()
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

    private let indicator = DictationIndicator()
    private var recorder: DictationRecorder?
    /// The streaming side of the hold that is recording, if it streams.
    private var live: DictationLiveHold?
    /// The newest hold's typewriter: the next hold waits for it, so keystrokes never interleave.
    private var lastTypewriter: DictationTypewriter?
    private var lastFollow: TimeInterval = 0
    private var followPending = false
    private var staleRetries = 0
    private var recordingStartedAt = Date.distantPast
    /// The text before the caret when the recording hold began, if Seed may use it.
    private var editorContext: DictationEditorContext.Box?
    /// Seed's accurate pass of the recording hold, fed while it records.
    private var refinement: DictationRefinementStream?
    /// Increments per hold so a slow transcript from an older hold never overwrites a newer
    /// hold's status. Its text is still typed: the user spoke it.
    private var holdCount = 0

    /// The Computer Use bar, supplied by the app delegate, for Auto Computer Use.
    var computerUse: ComputerUseHandoff?

    /// Where one hold's words go: the focused editor (the usual case), the Computer Use bar, or
    /// not yet known while Auto Computer Use asks what has the focus. Shared by `begin`, the
    /// probe's answer and `finish`, which may run in any order relative to each other.
    final class HoldTarget {
        enum Kind { case editor, pending, computerUse }
        var kind: Kind = .editor
        /// What the bar already held when the hold began; dictation adds to it.
        var base = ""
        func joined(_ text: String) -> String {
            guard !base.isEmpty, !text.isEmpty else { return base + text }
            return base.last?.isWhitespace == true ? base + text : base + " " + text
        }
    }
    private var target = HoldTarget()

    /// Short enough that a tap of Siri types nothing.
    static let minimumDuration: TimeInterval = 0.3
    /// After the bridge reports its output drained, the HAL loopback still holds a few
    /// milliseconds that have not reached the input tap yet.
    static let drainGrace: UInt64 = 150_000_000

    /// Where a hold's audio comes from: the remote (Siri held, through the bridge's virtual
    /// device) or the Mac's own microphone (the keyboard hotkey).
    enum Source: Equatable { case remote, macMicrophone }
    private var source: Source = .remote
    /// The source of the hold that is recording, if any: the hotkey only ends or cancels its own.
    var recordingSource: Source? { recorder == nil ? nil : source }

    func begin(source: Source = .remote) {
        guard recorder == nil else { return }
        let settings = DictationSettings.load()
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            fail("Allow VibeRemote to use the microphone, then try again.")
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
        let device: AudioDeviceID
        switch source {
        case .remote:
            guard let id = DictationAudioDevice.inputID() else {
                fail("The VibeRemote audio device is missing. Install the audio driver in Settings › Device.")
                return
            }
            device = id
        case .macMicrophone:
            guard let id = DictationAudioDevice.macMicrophoneID() else {
                fail("No microphone was found on this Mac.")
                return
            }
            device = id
        }
        // Auto Computer Use: a hold into the open, waiting bar goes there at once; otherwise, with
        // the switch on, the focused element decides once the probe below answers.
        let target = HoldTarget()
        if source == .remote, AutoComputerUse.isEnabled, let handoff = computerUse, !handoff.isBusy() {
            if handoff.isComposing() {
                target.kind = .computerUse
                target.base = handoff.text()
            } else {
                target.kind = .pending
            }
        }
        let live = settings.provider == .seedASR && settings.seedStreaming ? startStream(settings) : nil
        switch target.kind {
        case .editor: break
        case .pending: live?.route(.pending)
        case .computerUse: live?.route(.handoff { [weak self] text in self?.computerUse?.show(target.joined(text)) })
        }
        let session = live?.session
        let refinement = settings.provider == .seedASR ? DictationRefinementStream.make() : nil
        let refinementSession = refinement?.session
        let recorder = DictationRecorder()
        do {
            try recorder.start(deviceID: device) { [weak self] samples in
                session?.append(samples)
                refinementSession?.append(samples)
                let rms = DictationLevelMeter.rms(samples)
                Task { @MainActor in self?.indicator.hear(rms: rms) }
            }
        } catch {
            live?.cancel()
            live?.typewriter.stop("recording failed")
            refinement?.cancel()
            fail(error.localizedDescription)
            return
        }
        self.recorder = recorder
        self.live = live
        self.source = source
        self.refinement = refinement
        self.target = target
        editorContext = nil
        if let refinement { startRefinement(refinement, settings: settings) }
        recordingStartedAt = Date()
        holdCount += 1
        phase = .recording
        // The bar shows the words itself; the orange cursor is for the editor they type into.
        if target.kind != .computerUse { indicator.listen() }
        if target.kind == .pending {
            let hold = holdCount
            AutoComputerUse.probeFocusedTextInput { [weak self, weak live] textInput in
                self?.resolve(target, textInput: textInput, live: live, hold: hold)
            }
        }
        rmDebug("🗣 Dictation recording (\(settings.provider.rawValue)\(live == nil ? "" : ", streaming")\(source == .macMicrophone ? ", Mac microphone" : ""))")
    }

    /// The probe's answer: a focused text field keeps the hold an ordinary dictation; anything
    /// else opens Computer Use and sends the words there.
    private func resolve(_ target: HoldTarget, textInput: Bool, live: DictationLiveHold?, hold: Int) {
        guard target.kind == .pending else { return }
        guard !textInput, let handoff = computerUse, !handoff.isBusy() else {
            target.kind = .editor
            live?.route(.typewriter)
            return
        }
        target.kind = .computerUse
        handoff.open()
        if hold == holdCount { indicator.hide() }
        live?.route(.handoff { [weak self] text in self?.computerUse?.show(target.joined(text)) })
        rmDebug("🗣 Auto Computer Use: no text field has the focus, dictating into Computer Use")
    }

    /// An unanswered probe by the time the words are final: dictate as usual.
    private static func settle(_ target: HoldTarget, live: DictationLiveHold?) {
        guard target.kind == .pending else { return }
        target.kind = .editor
        live?.route(.typewriter)
    }

    private func startStream(_ settings: DictationSettings) -> DictationLiveHold? {
        guard let key = DictationKeychain.key(for: .seedASR) else { return nil }
        let liveHold = DictationLiveHold(typewriter: DictationTypewriter(after: lastTypewriter),
                                         dictionary: settings.dictionary)
        let session = SeedStreamingSession { [weak liveHold] event in
            Task { @MainActor in liveHold?.handle(event) }
        }
        liveHold.session = session
        liveHold.typewriter.onEmit = { [weak self] in self?.followCaret() }
        session.start(SeedStreamingSession.request(accessKey: key, appID: settings.seedAppID,
                                                   resourceID: settings.seedStreamResourceID),
                      appID: settings.seedAppID, removeFillers: settings.seedRemoveFillers)
        // No hotwords on the live stream: measured 2026-11-11, they pushed the two-way recognizer
        // into Chinese and garbled more words, while the flash refinement after release did better
        // with them. The refinement replaces the streamed text, so it carries them.
        lastTypewriter = liveHold.typewriter
        return liveHold
    }

    /// The refinement session goes out once the editor context is read (a few ms; audio waits in
    /// the session meanwhile), because its first request carries every hint: the dictionary's
    /// hotwords and the text before the caret. The live stream takes neither (see `startStream`).
    private func startRefinement(_ refinement: DictationRefinementStream, settings: DictationSettings) {
        guard let key = DictationKeychain.key(for: .seedASR), let session = refinement.session else { return }
        let request = SeedStreamingSession.request(accessKey: key, appID: settings.seedAppID,
                                                   resourceID: settings.seedStreamResourceID,
                                                   endpoint: SeedStreamFrame.nostreamEndpoint)
        let begin: @Sendable (String?) -> Void = { text in
            session.start(request, appID: settings.seedAppID,
                          context: DictationDictionary.seedContext(settings.dictionary, editorText: text),
                          removeFillers: settings.seedRemoveFillers)
        }
        if settings.seedEditorContext {
            editorContext = DictationEditorContext.read(then: begin)
        } else {
            begin(nil)
        }
    }

    /// Reads follow each keystroke as soon as the editor can have seen it, at most one per
    /// frame (the reader also keeps only one read in flight and the latest waiting). While a
    /// reading is still behind the typewriter the next read follows a frame later, for up to
    /// ~160 ms after the last keystroke, so the bubble catches up instead of waiting for one.
    private func followCaret() {
        staleRetries = 0
        requestFollow(after: Self.followSettle)
    }

    private func requestFollow(after minimum: TimeInterval) {
        guard !followPending else { return }
        followPending = true
        let sinceLast = ProcessInfo.processInfo.systemUptime - lastFollow
        let delay = max(minimum, Self.followInterval - sinceLast)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.followPending = false
                self.lastFollow = ProcessInfo.processInfo.systemUptime
                self.indicator.follow(expected: self.lastTypewriter?.expectedCaret) { [weak self] in
                    guard let self, self.staleRetries < Self.maximumStaleRetries else { return }
                    self.staleRetries += 1
                    self.requestFollow(after: Self.retryInterval)
                }
            }
        }
    }

    private static let followInterval: TimeInterval = 0.016
    /// Long enough for the posted keystroke to reach the editor, so the first read is usually
    /// already current.
    private static let followSettle: TimeInterval = 0.008
    private static let maximumStaleRetries = 10
    /// Retries after an empty or lagging read wait a little longer than a frame, so the editor
    /// can finish updating its accessibility tree in between (10 retries ≈ 300 ms).
    private static let retryInterval: TimeInterval = 0.03

    /// Drops the hold: nothing is transcribed or typed. The hotkey uses it when the key turns out
    /// to be part of a shortcut (another key pressed while it is held).
    func cancel() {
        guard let recorder else { return }
        self.recorder = nil
        _ = recorder.stop()
        live?.cancel()
        live?.typewriter.stop("hold cancelled")
        live = nil
        refinement?.cancel()
        refinement = nil
        editorContext = nil
        indicator.hide()
        phase = .idle
        rmDebug("🗣 Dictation hold cancelled")
    }

    func end() {
        guard let recorder else { return }
        self.recorder = nil
        let hold = holdCount
        let live = self.live
        self.live = nil
        let source = self.source
        let context = editorContext
        editorContext = nil
        let refinement = self.refinement
        self.refinement = nil
        let target = self.target
        let settings = DictationSettings.load()
        Task { @MainActor in
            // The bridge's loopback lags the remote; the Mac's microphone has nothing to drain.
            if source == .remote { try? await Task.sleep(nanoseconds: Self.drainGrace) }
            let audio = recorder.stop()
            live?.session?.finish()
            refinement?.session?.finish()
            await self.finish(audio, settings: settings, hold: hold, live: live, source: source,
                              editorText: context?.text, refinement: refinement, target: target)
        }
    }

    private func finish(_ audio: DictationAudio, settings: DictationSettings, hold: Int,
                        live: DictationLiveHold?, source: Source = .remote, editorText: String? = nil,
                        refinement: DictationRefinementStream? = nil, target: HoldTarget = HoldTarget()) async {
        // A later hold owns the indicator once it has begun; only the current hold moves it.
        guard audio.duration >= Self.minimumDuration else {
            live?.cancel()
            refinement?.cancel()
            live?.typewriter.stop("hold too short")
            if hold == holdCount { indicator.hide(); phase = .idle }
            return
        }
        guard audio.rms > 0.000_1 else {
            live?.cancel()
            refinement?.cancel()
            live?.typewriter.stop("no audio")
            if hold == holdCount {
                fail(source == .remote ? "No audio arrived. Check that the voice bridge is running."
                                       : "No audio arrived from the Mac's microphone.")
            }
            return
        }
        if hold == holdCount { phase = .transcribing; indicator.recognize() }
        if let live {
            await finishStreaming(live, audio: audio, settings: settings, hold: hold, editorText: editorText,
                                  refinement: refinement, target: target)
            return
        }
        let started = Date()
        do {
            let accurate = try await Self.accurateText(refinement, audio: audio, settings: settings, editorText: editorText)
            let text = Self.finalText(accurate.text, settings: settings)
            let elapsed = Date().timeIntervalSince(started)
            rmDebug(String(format: "🗣 Dictation %@%@: %.1f s audio (peak %.0f dBFS) → %d chars in %.2f s%@",
                           settings.provider.rawValue, refinement == nil ? "" : " via \(accurate.via)", audio.duration,
                           DictationLevelMeter.peakDecibels(audio.samples), text.count, elapsed,
                           Self.hintSummary(settings, editorText: editorText)))
            if hold == holdCount { indicator.hide() }
            guard !text.isEmpty else {
                if hold == holdCount { phase = .finished("No speech recognized.") }
                return
            }
            Self.settle(target, live: nil)
            if target.kind == .computerUse {
                computerUse?.submit(target.joined(text))
                if hold == holdCount { phase = .finished("Sent \(text.count) characters to Computer Use.") }
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

    /// The stream's final result wins; if the stream failed or never answered, the recorded
    /// clip goes through the one-shot flash API instead. Either way the typewriter reconciles
    /// what is already on screen with the answer, so a fallback only replaces the tail that
    /// differs.
    private func finishStreaming(_ live: DictationLiveHold, audio: DictationAudio,
                                 settings: DictationSettings, hold: Int, editorText: String?,
                                 refinement: DictationRefinementStream?, target: HoldTarget) async {
        let released = Date()
        // The one refinement, after release: the accurate recognizer's answer for the whole clip
        // replaces what streamed, and the typewriter corrects what differs. Once it is in, the
        // stream's own final no longer matters. A failed or empty refinement keeps the streamed
        // text; if the stream failed too, there is nothing to type.
        var text: String?
        var route: String
        do {
            let accurate = try await Self.accurateText(refinement, audio: audio, settings: settings, editorText: editorText)
            if accurate.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                route = "stream (refinement empty)"
            } else {
                text = accurate.text
                let streamed = live.latest?.text ?? ""
                route = DictationTyper.normalized(accurate.text) == DictationTyper.normalized(streamed)
                    ? "stream + refined via \(accurate.via) (unchanged)" : "stream + refined via \(accurate.via)"
            }
        } catch {
            route = "stream (refinement failed: \(error.localizedDescription))"
        }
        if text == nil {
            await live.waitForEnd(timeout: 4)
            guard live.succeeded else {
                let reason = live.failure ?? "unknown"
                rmDebug("⚠️ Dictation seedASR failed: stream \(reason), \(route)")
                await live.typewriter.finish(nil)
                if hold == holdCount { fail("Seed ASR did not answer (\(reason)).") }
                return
            }
            text = live.latest?.text ?? ""
        } else {
            live.cancel()
        }
        let final = Self.finalText(text ?? "", settings: settings)
        Self.settle(target, live: live)
        if target.kind == .computerUse {
            // The polished transcript replaces the streamed words in the bar and goes out as the
            // command; nothing is typed into any app. An empty result leaves the bar open.
            live.typewriter.stop("sent to Computer Use")
            if final.isEmpty { computerUse?.show(target.base) } else { computerUse?.submit(target.joined(final)) }
            route += " → Computer Use"
        } else {
            await live.typewriter.finish(final)
        }
        let elapsed = Date().timeIntervalSince(released)
        let firstText = live.firstTextAt.map { String(format: "%.2f s", $0.timeIntervalSince(live.startedAt)) } ?? "none"
        let stopped = live.typewriter.stoppedReason
        rmDebug(String(format: "🗣 Dictation seedASR %@: %.1f s audio (peak %.0f dBFS, floor %.0f dBFS), %d updates, first text %@ → %d chars, %d corrected%@, settled %.2f s after release%@%@",
                       route, audio.duration, DictationLevelMeter.peakDecibels(audio.samples),
                       DictationLevelMeter.floorDecibels(audio.samples), live.partials,
                       firstText, final.count, live.typewriter.deletedCharacters, live.typewriter.correctionMethod, elapsed,
                       stopped.map { ", stopped: \($0)" } ?? "", Self.hintSummary(settings, editorText: editorText)))
        guard hold == holdCount else { return }
        indicator.hide()
        if target.kind == .computerUse {
            phase = .finished(final.isEmpty ? "No speech recognized." : "Sent \(final.count) characters to Computer Use.")
        } else if let stopped {
            phase = .finished("Stopped typing because \(stopped).")
        } else if final.isEmpty {
            phase = .finished("No speech recognized.")
        } else {
            phase = .finished(String(format: "Typed %d characters as you spoke; settled %.1f s after release.",
                                     final.count, elapsed))
        }
    }

    private func fail(_ message: String) {
        indicator.hide()
        phase = .failed(message)
        NSSound.beep()
    }

    /// The accurate recognition of a whole hold: the refinement session's answer when it gave
    /// one (fed during the hold, so it answers ~0.5–1 s after release), otherwise the recorded clip
    /// through the flash API with the same hints. `via` names which, for the log.
    private static func accurateText(_ refinement: DictationRefinementStream?, audio: DictationAudio,
                                     settings: DictationSettings, editorText: String?) async throws -> (text: String, via: String) {
        var via = "flash"
        // Every hold length goes through it (2026-11-12): flash puts a sentence break at each
        // pause longer than ~3 s ("I want is. A way to…"), whatever the grammar, and its
        // `vad_segment_duration` changes nothing, while the streaming-input mode punctuates by
        // meaning across 3–5 s thinking pauses. It may still break once at its 15 s window.
        if let refinement {
            await refinement.waitForEnd(timeout: 4)
            if let answer = refinement.answer { return (answer, "nostream") }
            via = "flash (nostream \(refinement.failure ?? "empty"))"
        }
        let text = try await engine(for: settings, editorText: editorText).transcribe(audio, language: settings.language)
        return (text, via)
    }

    /// Recognized text as it is typed: Seed's filler cleanup (see `DictationFillers` for why the
    /// refinement needs it), then the dictionary, then one line.
    nonisolated static func finalText(_ text: String, settings: DictationSettings) -> String {
        let cleaned = settings.provider == .seedASR && settings.seedRemoveFillers ? DictationFillers.clean(text) : text
        return DictationTyper.normalized(DictationDictionary.apply(settings.dictionary, to: cleaned))
    }

    /// What the Seed request carried besides audio, for the log: lengths and switches, never text.
    private static func hintSummary(_ settings: DictationSettings, editorText: String?) -> String {
        guard settings.provider == .seedASR else { return "" }
        return ", fillers \(settings.seedRemoveFillers ? "removed" : "kept"), context \(editorText?.count ?? 0) chars"
    }

    static func engine(for settings: DictationSettings, editorText: String? = nil) async throws -> any DictationEngine {
        switch settings.provider {
        case .apple:
            return AppleDictationEngine()
        case .whisperKit:
            await WhisperKitDictationEngine.shared.select(model: settings.whisperModel)
            return WhisperKitDictationEngine.shared
        case .openAI:
            guard let key = DictationKeychain.key(for: .openAI) else { throw DictationError("Add your OpenAI key in Settings › Dictation.") }
            return OpenAIDictationEngine(apiKey: key, model: settings.openAIModel,
                                         prompt: DictationDictionary.openAIPrompt(settings.dictionary))
        case .seedASR:
            guard let key = DictationKeychain.key(for: .seedASR) else { throw DictationError("Add your Seed ASR key in Settings › Dictation.") }
            return SeedASRDictationEngine(accessKey: key, appID: settings.seedAppID, resourceID: settings.seedResourceID,
                                          context: DictationDictionary.seedContext(settings.dictionary, editorText: editorText),
                                          removeFillers: settings.seedRemoveFillers)
        }
    }
}

// MARK: - Editor context

/// The text already standing before the caret when a hold begins, for Seed ASR's dialog context
/// (2026-11-12, user's request, modeled on Doubao IME, which knows the field it types into).
/// The recognizer uses it to pick between words that sound alike: the topic, the names and
/// terms already in the message. Read once per hold, off the main thread, through the same
/// frontmost-app fallback the caret reader needs for ChatGPT. Never logged; only its length is.
enum DictationEditorContext {
    /// Volcengine allows 800 tokens of context. A CJK character can cost a token by itself, and
    /// the dictionary's hotwords share the field, so keep well under it.
    static let characterLimit = 500

    /// The last `characterLimit` characters, trimmed, or nil when nothing is left.
    static func trimmed(_ text: String) -> String? {
        let tail = String(text.suffix(characterLimit)).trimmingCharacters(in: .whitespacesAndNewlines)
        return tail.isEmpty ? nil : tail
    }

    /// The text before the caret (or before the selection) in `value`, at a UTF-16 location,
    /// or nil when the location does not fall inside it.
    static func textBefore(location: Int, in value: String) -> String? {
        guard location > 0, location <= value.utf16.count,
              let end = String.Index(String.Index(utf16Offset: location, in: value), within: value) else { return nil }
        return trimmed(String(value[..<end]))
    }

    /// One read result, filled in on a background queue and read after release.
    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: String?
        var text: String? { lock.lock(); defer { lock.unlock() }; return stored }
        fileprivate func set(_ text: String?) { lock.lock(); stored = text; lock.unlock() }
    }

    /// Reads off the main thread; `then` runs on that background queue once the box is filled
    /// (at once, with nil, when VibeRemote itself is in front).
    static func read(then: (@Sendable (String?) -> Void)? = nil) -> Box {
        let box = Box()
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              pid != ProcessInfo.processInfo.processIdentifier else { then?(nil); return box }
        DispatchQueue.global(qos: .userInitiated).async {
            let text = textBeforeCaret(pid: pid)
            box.set(text)
            then?(text)
        }
        return box
    }

    private static func textBeforeCaret(pid: pid_t) -> String? {
        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
        }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.1)
        guard let raw = attribute(application, kAXFocusedUIElementAttribute),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeBitCast(raw, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, 0.1)
        // Never a password field, and only text editors: other focused controls have no message.
        guard attribute(element, kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole,
              let role = attribute(element, kAXRoleAttribute) as? String,
              [kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole].contains(role),
              let value = attribute(element, kAXValueAttribute) as? String, value.utf16.count <= 200_000 else { return nil }
        // ChatGPT's composer reports its placeholder as the value while empty.
        if let placeholder = attribute(element, kAXPlaceholderValueAttribute) as? String,
           placeholder.trimmingCharacters(in: .whitespacesAndNewlines) == value.trimmingCharacters(in: .whitespacesAndNewlines) {
            return nil
        }
        var range = CFRange()
        if let rawRange = attribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(rawRange) == AXValueGetTypeID(),
           AXValueGetValue(unsafeBitCast(rawRange, to: AXValue.self), .cfRange, &range) {
            return textBefore(location: range.location, in: value)
        }
        return trimmed(value)
    }
}
