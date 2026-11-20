import AVFoundation
import Foundation
import Security

@MainActor
final class VoiceHost {
    static let shared = VoiceHost()
    var onChange: (() -> Void)?
    private(set) var status = "Open vvhisper to prepare voice input."
    private(set) var enabled = false
    private(set) var enabling = false
    private var activationGeneration = 0
    private var engine: AVAudioEngine?
    private var timer: Timer?
    private var lifetime: VoiceSessionLifetime?
    private var activeID: UUID?
    private var handledID: UUID?
    private var finishing = false
    private var polishing = false
    private var translate = false
    private var pendingRecognized: String?
    private let polisher = DictationPolishSession()
    private var polishSettings = DictationPolishSettings()
    private var outputSettings = DictationOutputSettings()
    private var polishKey: String?
    private var recordingStart = Date()
    private var finalDeadline = Date.distantFuture
    private var stream: SeedStreamingSession?
    private var refinement: SeedStreamingSession?
    private var latest = ""
    private var liveFinal: String?
    private var refinedFinal: String?
    private var latestRefined = ""
    private var relay = AudioRelay()
    private var observer: NSObjectProtocol?
    private var lastHeartbeat = Date.distantPast
    private var lastLevelPublished = Date.distantPast

    init() {
        observer = NotificationCenter.default.addObserver(forName: AVAudioSession.didBecomeInactiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in guard self?.enabled == true else { return }; self?.stop(message: "Voice input paused. Open vvhisper to continue.") }
        }
    }

    func enable() {
        guard !enabled, !enabling else { return }
        guard let key = SeedKeychain.read(), !key.isEmpty else { status = "Add your Seed API key first."; onChange?(); return }
        activationGeneration += 1
        let generation = activationGeneration
        enabling = true; status = "Preparing Voice Input…"; onChange?()
        AVAudioApplication.requestRecordPermission { granted in
            Task { @MainActor in
                guard self.enabling, self.activationGeneration == generation else { return }
                guard granted else { self.enabling = false; self.status = "Allow microphone access in Settings."; self.onChange?(); return }
                do { try self.startEngine() }
                catch { self.stop(message: error.localizedDescription) }
            }
        }
    }

    private func startEngine() throws {
        guard !enabled else { return }
        let audio = AVAudioSession.sharedInstance()
        // Measurement mode disables output dynamics and lowers other apps’ playback.
        // Keep media mixing and stereo Bluetooth; never request ducking or voice processing.
        try audio.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP])
        // Keep keyboard feedback available while the host microphone is armed.
        try audio.setAllowHapticsAndSystemSoundsDuringRecording(true)
        try audio.setActive(true)
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let source = input.outputFormat(forBus: 0)
        guard source.sampleRate > 0, source.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: source, to: target) else { throw DictationError("Microphone is unavailable.") }
        let relay = self.relay
        input.installTap(onBus: 0, bufferSize: 2048, format: source) { buffer, _ in
            // The engine stays active during the bounded ready session. Idle audio is discarded.
            guard let capture = relay.capture else { return }
            let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 16_000 / source.sampleRate) + 32)
            guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var supplied = false
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, state in
                if supplied { state.pointee = .noDataNow; return nil }
                supplied = true; state.pointee = .haveData; return buffer
            }
            guard error == nil, let samples = converted.floatChannelData?[0], converted.frameLength > 0 else { return }
            relay.append(Array(UnsafeBufferPointer(start: samples, count: Int(converted.frameLength))), generation: capture)
        }
        do { try engine.start() }
        catch { input.removeTap(onBus: 0); try? audio.setActive(false); throw error }
        self.engine = engine; enabled = true; enabling = false
        lifetime = VoiceSessionLifetime(startedAt: Date(), minutes: KeyboardPreferences.load().voiceSessionMinutes)
        status = "Ready — return to your app and hold a letter key."
        VoiceIPC.remove("command.json"); VoiceIPC.remove("reply.json"); VoiceIPC.remove(VoiceLevel.filename)
        lastHeartbeat = .distantPast
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        onChange?()
    }

    func stop(message: String = "Open vvhisper to prepare voice input.") {
        activationGeneration += 1; enabling = false
        if let id = activeID {
            if let pendingRecognized { publish(VoiceReply(id: id, text: outputSettings.finalize(pendingRecognized), isFinal: true, notice: "\(translate ? "Translation" : "Polishing") interrupted; kept the transcript.")) }
            else { publish(VoiceReply(id: id, text: "", isFinal: true, error: message)) }
        }
        clearHold()
        timer?.invalidate(); timer = nil
        engine?.inputNode.removeTap(onBus: 0); engine?.stop(); engine = nil
        enabled = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        enabled = false; status = message
        lifetime = nil
        try? VoiceIPC.write(VoiceReadiness(ready: false, expiresAt: Date()), to: "ready.json")
        onChange?()
    }

    func updateSessionDuration(minutes: Int) {
        guard enabled else { return }
        lifetime?.minutes = KeyboardPreferences.normalizedSessionMinutes(minutes)
        lastHeartbeat = .distantPast
        tick() // Shortening an elapsed session stops capture immediately.
    }

    private func tick() {
        guard enabled else { return }
        if let reply = VoiceIPC.read("reply.json", as: VoiceReply.self), Date().timeIntervalSince(reply.updatedAt) > 15 { VoiceIPC.remove("reply.json") }
        guard engine?.isRunning == true else { stop(message: "Microphone stopped. Open vvhisper to continue."); return }
        guard let lifetime, !lifetime.hasExpired(at: Date()) else { stop(message: "Voice session ended. Open vvhisper to continue."); return }
        if Date().timeIntervalSince(lastHeartbeat) > 0.4 {
            lastHeartbeat = Date()
            do { try VoiceIPC.write(VoiceReadiness(ready: true, expiresAt: lifetime.expiresAt), to: "ready.json") }
            catch { stop(message: "Cannot share the voice session with the keyboard."); return }
        }
        defer { publishLevel() }

        if let command = VoiceIPC.read("command.json", as: VoiceCommand.self) {
            if command.id == activeID {
                if command.phase == .cancel { clearHold(); status = "Ready"; onChange?() }
                else if command.phase == .finish, !finishing { translate = command.translate == true; finish() }
                else if !finishing && (Date().timeIntervalSince(command.updatedAt) > 1.5 || Date().timeIntervalSince(recordingStart) > 120) {
                    publish(VoiceReply(id: command.id, text: "", isFinal: true, error: "Recording stopped because the keyboard was closed or the hold expired.")); clearHold()
                }
            } else if command.id != handledID, command.phase != .cancel, abs(Date().timeIntervalSince(command.updatedAt)) < 1 {
                if activeID != nil { clearHold() }
                if command.phase == .recording { begin(id: command.id) }
                else if command.phase == .finish {
                    handledID = command.id
                    publish(VoiceReply(id: command.id, text: "", isFinal: true, error: nil))
                }
            }
        }
        if finishing, !polishing, Date() > finalDeadline { complete(text: refinedFinal ?? liveFinal ?? latest) }
    }

    private func publishLevel() {
        guard let id = activeID, !finishing, let sample = relay.level,
              sample.updatedAt > lastLevelPublished else { return }
        lastLevelPublished = sample.updatedAt
        try? VoiceIPC.write(VoiceLevel(id: id, value: sample.value, updatedAt: sample.updatedAt), to: VoiceLevel.filename)
    }

    private func begin(id: UUID) {
        guard let key = SeedKeychain.read() else { return }
        activeID = id; handledID = id; finishing = false; latest = ""; liveFinal = nil; refinedFinal = nil; latestRefined = ""
        polishSettings = .load(); polishKey = ArkPolishKeychain.read()
        outputSettings = .load()
        recordingStart = Date(); status = "Listening…"
        let appID = UserDefaults.standard.string(forKey: "seedAppID") ?? ""
        let live = SeedStreamingSession { [weak self] event in Task { @MainActor in self?.event(event, id: id, accurate: false) } }
        let accurate = SeedStreamingSession { [weak self] event in Task { @MainActor in self?.event(event, id: id, accurate: true) } }
        stream = live; refinement = accurate
        live.start(SeedStreamingSession.request(accessKey: key, appID: appID, resourceID: ""), appID: appID, removeFillers: true)
        accurate.start(SeedStreamingSession.request(accessKey: key, appID: appID, resourceID: "", endpoint: SeedStreamFrame.nostreamEndpoint), appID: appID, removeFillers: true)
        lastLevelPublished = .distantPast
        relay.set([live, accurate]); onChange?()
    }

    private func finish() {
        guard !finishing else { return }
        relay.set([]); VoiceIPC.remove(VoiceLevel.filename); finishing = true; finalDeadline = Date().addingTimeInterval(5)
        stream?.finish(); refinement?.finish(); status = "Transcribing…"; onChange?()
        if let refinedFinal { complete(text: refinedFinal) }
    }

    private func event(_ event: SeedStreamingSession.Event, id: UUID, accurate: Bool) {
        guard activeID == id, !polishing else { return }
        switch event {
        case .partial(let result):
            if accurate { latestRefined = result.text }
            else { latest = result.text; publish(VoiceReply(id: id, text: result.text, isFinal: false, error: nil)) }
        case .final(let result):
            if accurate { refinedFinal = result?.text ?? latestRefined }
            else { liveFinal = result?.text ?? latest }
            if finishing, let refinedFinal { complete(text: refinedFinal) }
        case .failed(let error):
            if accurate { refinement = nil }
            else { stream = nil }
            if stream == nil && refinement == nil {
                publish(VoiceReply(id: id, text: "", isFinal: true, error: "Seed ASR: \(error)")); clearHold(); status = "Recognition failed"; onChange?()
            }
        }
    }
    private func complete(text: String) {
        guard let id = activeID, !polishing else { return }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            publish(VoiceReply(id: id, text: "", isFinal: true, error: nil))
            clearHold(); status = "Ready"; onChange?(); return
        }
        polishing = true; pendingRecognized = clean
        relay.set([]); stream?.cancel(); refinement?.cancel(); stream = nil; refinement = nil
        // Publish the recognized text as pending marked text, not a final commit.
        publish(VoiceReply(id: id, text: clean, isFinal: false, polishing: true))
        status = translate ? "Translating…" : "Polishing…"; onChange?()
        polisher.start(text: clean, settings: polishSettings, key: polishKey, translate: translate) { [weak self] result in
            guard let self, self.activeID == id, self.polishing else { return }
            // A cancellation/new hold may have reached IPC before the next timer tick.
            guard let command = VoiceIPC.read("command.json", as: VoiceCommand.self),
                  command.id == id, command.phase == .finish else { self.clearHold(); return }
            self.publish(VoiceReply(id: id, text: self.outputSettings.finalize(result.text), isFinal: true, notice: result.notice))
            self.clearHold(); self.status = result.notice ?? "Ready"; self.onChange?()
        }
    }
    private func publish(_ reply: VoiceReply) { try? VoiceIPC.write(reply, to: "reply.json") }
    private func clearHold() {
        relay.set([]); VoiceIPC.remove(VoiceLevel.filename); stream?.cancel(); refinement?.cancel(); stream = nil; refinement = nil
        polisher.cancel(); pendingRecognized = nil; polishing = false; polishKey = nil
        activeID = nil; finishing = false; translate = false
    }
}

/// Audio-thread access and hold boundaries share a lock, so no idle/pre-hold samples leak.
final class AudioRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [SeedStreamingSession] = []
    private var generation = UUID()
    private var meter: (value: Double, updatedAt: Date)?
    var level: (value: Double, updatedAt: Date)? { lock.lock(); defer { lock.unlock() }; return meter }
    var capture: UUID? { lock.lock(); defer { lock.unlock() }; return sessions.isEmpty ? nil : generation }
    func set(_ value: [SeedStreamingSession]) { lock.lock(); sessions = value; generation = UUID(); meter = nil; lock.unlock() }
    func append(_ samples: [Float], generation: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard self.generation == generation, !sessions.isEmpty else { return }
        meter = (VoiceLevel.measure(samples), Date())
        for session in sessions { session.append(samples) }
    }
}

enum SeedKeychain {
    static func read() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.vvhisper.ios.seed", kSecAttrAccount as String: "api-key", kSecReturnData as String: true]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ value: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.vvhisper.ios.seed", kSecAttrAccount as String: "api-key"]
        let data = Data(value.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecItemNotFound {
            let status = SecItemAdd((query.merging([kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]) { _, new in new }) as CFDictionary, nil)
            guard status == errSecSuccess else { throw DictationError("Could not save API key (\(status)).") }
        } else if update != errSecSuccess { throw DictationError("Could not update API key (\(update)).") }
    }
    static func importDevelopmentConfiguration() {
        #if DEBUG
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("seed-development.json")
        guard let data = try? Data(contentsOf: url) else { return }
        defer { try? FileManager.default.removeItem(at: url) }
        if let config = try? JSONDecoder().decode([String: String].self, from: data), let key = config["apiKey"] {
            do { try save(key); UserDefaults.standard.set(config["appID"] ?? "", forKey: "seedAppID") } catch { }
        }
        #endif
    }
}
