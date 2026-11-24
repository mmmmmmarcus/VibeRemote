import UIKit
import CoreHaptics

/// One short transient per tap, shared by Settings preview and the keyboard.
/// Haptics-only mode leaves the host's microphone/audio session alone.
@MainActor final class KeyboardHaptics {
    private var strength = 0.45
    private var sharpness = 0.7
    private var engine: CHHapticEngine?
    private var players: KeyboardHapticPlayers?
    private var confirmationPlayers: KeyboardHapticPlayers?
    private var retiredPlayers: [KeyboardHapticPlayers] = []
    private var fallback = UIImpactFeedbackGenerator(style: .rigid)
    private var ready = false
    private var starting = false
    private var active = false
    private var generation = 0
    private var retryAfter: TimeInterval = 0
    #if DEBUG
    private(set) var verificationPlayedCustomFeedback = false
    private(set) var verificationErrorCode: Int?
    private(set) var verificationCustomStarts = 0
    private(set) var verificationCustomCompletions = 0
    private(set) var verificationFallbacks = 0
    private(set) var verificationRequests = 0
    #endif

    func configure(_ preferences: KeyboardPreferences) {
        let intensity = KeyboardPreferences.normalizedStrength(preferences.hapticStrength)
        let crispness = KeyboardPreferences.normalizedSharpness(preferences.hapticSharpness)
        guard intensity != strength || crispness != sharpness else { return }
        strength = intensity; sharpness = crispness
        // Already-playing taps keep their original settings until completion.
        if let players { players.retire(); retiredPlayers.append(players) }
        retiredPlayers.removeAll { !$0.isPlaying }
        players = nil
        if let confirmationPlayers { confirmationPlayers.retire(); retiredPlayers.append(confirmationPlayers) }
        confirmationPlayers = nil
        fallback = UIImpactFeedbackGenerator(style: sharpness < 0.34 ? .soft : sharpness < 0.67 ? .light : .rigid)
        if strength == 0 { stop() }
    }
    func prepare() {
        guard strength > 0 else { return }
        active = true
        if !ready { fallback.prepare() }
        guard !ready, !starting, ProcessInfo.processInfo.systemUptime >= retryAfter,
              CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        do {
            if engine == nil {
                let engine = try CHHapticEngine()
                engine.playsHapticsOnly = true; engine.isAutoShutdownEnabled = true
                let generation = generation
                engine.stoppedHandler = { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.generation == generation else { return }
                        self.invalidateEngine()
                    }
                }
                engine.resetHandler = { [weak self] in
                    Task { @MainActor in
                        guard let self, self.generation == generation else { return }
                        self.invalidateEngine()
                        if self.active { self.prepare() }
                    }
                }
                self.engine = engine
            }
            starting = true
            let generation = generation
            engine?.start { [weak self] error in
                let succeeded = error == nil
                let errorCode = (error as NSError?)?.code
                Task { @MainActor in
                    guard let self, self.generation == generation else { return }
                    self.starting = false; self.ready = succeeded && self.active
                    #if DEBUG
                    self.verificationErrorCode = errorCode
                    #endif
                    if !succeeded { self.retryAfter = ProcessInfo.processInfo.systemUptime + 3 }
                    if self.ready { try? self.preparePlayers() }
                }
            }
        } catch {
            retryAfter = ProcessInfo.processInfo.systemUptime + 3
            #if DEBUG
            verificationErrorCode = (error as NSError).code
            #endif
        }
    }
    func tap(confirmation: Bool = false) {
        guard strength > 0 else { return }
        #if DEBUG
        verificationRequests += 1
        #endif
        if ready {
            do {
                try preparePlayers(confirmation: confirmation)
                if try (confirmation ? confirmationPlayers : players)?.play() == true {
                    #if DEBUG
                    verificationPlayedCustomFeedback = true
                    verificationCustomStarts += 1
                    #endif
                    return
                }
            } catch {
                invalidateEngine()
                #if DEBUG
                verificationErrorCode = (error as NSError).code
                #endif
            }
        }
        // A cold/interrupted engine must never delay a key or replay a late tap.
        #if DEBUG
        verificationFallbacks += 1
        #endif
        fallback.impactOccurred(intensity: CGFloat(confirmation ? min(1, strength * 1.55) : strength)); prepare()
    }
    func stop() {
        active = false
        invalidateEngine()
    }
    private func invalidateEngine() {
        generation += 1; ready = false; starting = false
        players?.cancel(); confirmationPlayers?.cancel(); confirmationPlayers = nil
        retiredPlayers.forEach { $0.cancel() }; retiredPlayers.removeAll()
        players = nil
        let oldEngine = engine; engine = nil
        oldEngine?.stoppedHandler = { _ in }; oldEngine?.resetHandler = {}
        oldEngine?.stop(completionHandler: nil)
    }
    private func preparePlayers(confirmation: Bool = false) throws {
        guard (confirmation ? confirmationPlayers : players) == nil, let engine else { return }
        let pattern = try Self.pattern(strength: confirmation ? min(1, strength * 1.55) : strength,
                                       sharpness: confirmation ? min(1, sharpness + 0.18) : sharpness)
        let generation = generation
        let players = KeyboardHapticPlayers(makePlayer: {
            let player = try engine.makeAdvancedPlayer(with: pattern)
            return KeyboardHapticPlayers.Player(start: { completion in
                player.completionHandler = completion
                try player.start(atTime: CHHapticTimeImmediate)
            }, clearCompletion: { player.completionHandler = { _ in } })
        }, completed: { [weak self] errorCode in
            guard let self, self.generation == generation else { return }
            self.retiredPlayers.removeAll { !$0.isPlaying }
            #if DEBUG
            if let errorCode { self.verificationErrorCode = errorCode }
            else { self.verificationCustomCompletions += 1 }
            #endif
            // Do not replay an asynchronously failed tap after the finger moved on.
            if errorCode != nil { self.invalidateEngine() }
        })
        try players.prepare()
        if confirmation { confirmationPlayers = players } else { self.players = players }
    }
    static func pattern(strength: Double, sharpness: Double) throws -> CHHapticPattern {
        let event = CHHapticEvent(eventType: .hapticTransient, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: Float(KeyboardPreferences.normalizedStrength(strength))),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: Float(KeyboardPreferences.normalizedSharpness(sharpness)))
        ], relativeTime: 0)
        return try CHHapticPattern(events: [event], parameters: [])
    }
}

/// A player stays occupied until Core Haptics acknowledges completion. Restarting
/// one shared player can interrupt an earlier tap, particularly with two thumbs.
/// Bound resource use and fall back immediately if every voice is occupied.
@MainActor final class KeyboardHapticPlayers {
    struct Player {
        let start: (@escaping @Sendable (Error?) -> Void) throws -> Void
        let clearCompletion: () -> Void
    }
    private struct Voice {
        let player: Player
        var playback: UUID?
    }
    private var voices: [Voice] = []
    private let capacity: Int
    private let makePlayer: () throws -> Player
    private let completed: (Int?) -> Void
    private var retired = false
    var isPlaying: Bool { voices.contains { $0.playback != nil } }

    init(capacity: Int = 8, makePlayer: @escaping () throws -> Player,
         completed: @escaping (Int?) -> Void = { _ in }) {
        self.capacity = capacity; self.makePlayer = makePlayer; self.completed = completed
    }
    func prepare() throws {
        guard !retired else { return }
        while voices.count < capacity { voices.append(Voice(player: try makePlayer())) }
    }
    func play() throws -> Bool {
        guard !retired, let index = voices.firstIndex(where: { $0.playback == nil }) else { return false }
        let playback = UUID()
        voices[index].playback = playback
        do {
            try voices[index].player.start { [weak self] error in
                let code = (error as NSError?)?.code
                Task { @MainActor in self?.finish(index: index, playback: playback, errorCode: code) }
            }
            return true
        } catch {
            voices[index].playback = nil
            voices[index].player.clearCompletion()
            throw error
        }
    }
    /// Retain in-flight voices until their callbacks arrive, then release them.
    func retire() {
        retired = true
        if voices.allSatisfy({ $0.playback == nil }) { voices.removeAll() }
    }
    func cancel() {
        retired = true
        voices.forEach { $0.player.clearCompletion() }
        voices.removeAll()
    }
    private func finish(index: Int, playback: UUID, errorCode: Int?) {
        guard voices.indices.contains(index), voices[index].playback == playback else { return }
        voices[index].playback = nil
        voices[index].player.clearCompletion()
        completed(errorCode)
        if retired && voices.allSatisfy({ $0.playback == nil }) { voices.removeAll() }
    }
}
