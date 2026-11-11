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

    private enum Key {
        static let provider = "dictationProvider"
        static let language = "dictationLanguage"
        static let whisperModel = "dictationWhisperModel"
        static let openAIModel = "dictationOpenAIModel"
        static let seedAppID = "dictationSeedAppID"
        static let seedResourceID = "dictationSeedResourceID"
        static let seedStreaming = "dictationSeedStreaming"
        static let seedStreamResourceID = "dictationSeedStreamResourceID"
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
/// with the voice. -6 leaves syllables visibly rising and falling below the top.
enum DictationLevelMeter {
    static let floorDecibels: Float = -45
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
            self.place(point)
            if let expected, [.glyph, .textEnd].contains(point.accuracy), point.offset != expected {
                self.staleReads += 1
                behind()
            }
        }
    }

    private func place(_ point: CaretInsertionPoint.Reading) {
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
        if timing.count > 1 {
            let failed = timing.failed > 0 ? ", \(timing.failed) empty (last: \(insertion.lastFailure ?? "unknown"))" : ""
            rmDebug(String(format: "🗣 Dictation indicator: %d caret reads (%d behind the typewriter%@), mean %.0f ms, slowest %.0f ms",
                           timing.count, staleReads, failed, timing.mean, timing.slowest))
        }
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
        let live = settings.provider == .seedASR && settings.seedStreaming ? startStream(settings) : nil
        let session = live?.session
        let recorder = DictationRecorder()
        do {
            try recorder.start(deviceID: device) { [weak self] samples in
                session?.append(samples)
                let rms = DictationLevelMeter.rms(samples)
                Task { @MainActor in self?.indicator.hear(rms: rms) }
            }
        } catch {
            live?.cancel()
            live?.typewriter.stop("recording failed")
            fail(error.localizedDescription)
            return
        }
        self.recorder = recorder
        self.live = live
        recordingStartedAt = Date()
        holdCount += 1
        phase = .recording
        indicator.listen()
        rmDebug("🗣 Dictation recording (\(settings.provider.rawValue)\(live == nil ? "" : ", streaming"))")
    }

    private func startStream(_ settings: DictationSettings) -> DictationLiveHold? {
        guard let key = DictationKeychain.key(for: .seedASR) else { return nil }
        let liveHold = DictationLiveHold(typewriter: DictationTypewriter(after: lastTypewriter))
        let session = SeedStreamingSession { [weak liveHold] event in
            Task { @MainActor in liveHold?.handle(event) }
        }
        liveHold.session = session
        liveHold.typewriter.onEmit = { [weak self] in self?.followCaret() }
        session.start(SeedStreamingSession.request(accessKey: key, appID: settings.seedAppID,
                                                   resourceID: settings.seedStreamResourceID),
                      appID: settings.seedAppID)
        lastTypewriter = liveHold.typewriter
        return liveHold
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

    func end() {
        guard let recorder else { return }
        self.recorder = nil
        let hold = holdCount
        let live = self.live
        self.live = nil
        let settings = DictationSettings.load()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.drainGrace)
            let audio = recorder.stop()
            live?.session?.finish()
            await self.finish(audio, settings: settings, hold: hold, live: live)
        }
    }

    private func finish(_ audio: DictationAudio, settings: DictationSettings, hold: Int,
                        live: DictationLiveHold?) async {
        // A later hold owns the indicator once it has begun; only the current hold moves it.
        guard audio.duration >= Self.minimumDuration else {
            live?.cancel()
            live?.typewriter.stop("hold too short")
            if hold == holdCount { indicator.hide(); phase = .idle }
            return
        }
        guard audio.rms > 0.000_1 else {
            live?.cancel()
            live?.typewriter.stop("no audio")
            if hold == holdCount { fail("No audio arrived. Check that the voice bridge is running.") }
            return
        }
        if hold == holdCount { phase = .transcribing; indicator.recognize() }
        if let live {
            await finishStreaming(live, audio: audio, settings: settings, hold: hold)
            return
        }
        let started = Date()
        do {
            let engine = try await Self.engine(for: settings)
            let text = DictationTyper.normalized(try await engine.transcribe(audio, language: settings.language))
            let elapsed = Date().timeIntervalSince(started)
            rmDebug(String(format: "🗣 Dictation %@: %.1f s audio (peak %.0f dBFS) → %d chars in %.2f s",
                           settings.provider.rawValue, audio.duration,
                           DictationLevelMeter.peakDecibels(audio.samples), text.count, elapsed))
            if hold == holdCount { indicator.hide() }
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

    /// The stream's final result wins; if the stream failed or never answered, the recorded
    /// clip goes through the one-shot flash API instead. Either way the typewriter reconciles
    /// what is already on screen with the answer, so a fallback only replaces the tail that
    /// differs.
    private func finishStreaming(_ live: DictationLiveHold, audio: DictationAudio,
                                 settings: DictationSettings, hold: Int) async {
        let released = Date()
        await live.waitForEnd(timeout: 4)
        var text = live.succeeded ? (live.latest?.text ?? "") : nil
        var route = text == nil ? "flash fallback (\(live.failure ?? "unknown"))" : "stream"
        if text != nil {
            // The one refinement, after release: the stream ran its fast pass only, so the whole
            // clip goes once to the accurate flash recognizer and the typewriter corrects what
            // differs. A failed or empty refinement keeps the streamed text already on screen.
            let streamed = text ?? ""
            do {
                let refined = try await Self.engine(for: settings).transcribe(audio, language: settings.language)
                if refined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    route = "stream (refinement empty)"
                } else {
                    text = refined
                    route = DictationTyper.normalized(refined) == DictationTyper.normalized(streamed)
                        ? "stream + refined (unchanged)" : "stream + refined"
                }
            } catch {
                route = "stream (refinement failed: \(error.localizedDescription))"
            }
        }
        if text == nil {
            do {
                text = try await Self.engine(for: settings).transcribe(audio, language: settings.language)
            } catch {
                rmDebug("⚠️ Dictation seedASR fallback failed: \(error.localizedDescription)")
                await live.typewriter.finish(nil)
                if hold == holdCount { fail(error.localizedDescription) }
                return
            }
        }
        let final = DictationTyper.normalized(text ?? "")
        await live.typewriter.finish(final)
        let elapsed = Date().timeIntervalSince(released)
        let firstText = live.firstTextAt.map { String(format: "%.2f s", $0.timeIntervalSince(live.startedAt)) } ?? "none"
        let stopped = live.typewriter.stoppedReason
        rmDebug(String(format: "🗣 Dictation seedASR %@: %.1f s audio (peak %.0f dBFS, floor %.0f dBFS), %d updates, first text %@ → %d chars, %d corrected, settled %.2f s after release%@",
                       route, audio.duration, DictationLevelMeter.peakDecibels(audio.samples),
                       DictationLevelMeter.floorDecibels(audio.samples), live.partials,
                       firstText, final.count, live.typewriter.deletedCharacters, elapsed,
                       stopped.map { ", stopped: \($0)" } ?? ""))
        guard hold == holdCount else { return }
        indicator.hide()
        if let stopped {
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
