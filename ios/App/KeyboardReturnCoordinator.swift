import UIKit

/// Only an authenticated, fresh keyboard activation can request a local return.
@MainActor
final class KeyboardReturnCoordinator {
    private var task: Task<Void, Never>?
    private var generation = UUID()

    func activate(_ request: VoiceActivationRequest, in scene: UIWindowScene) {
        cancel()
        let currentGeneration = generation
        Self.record("waiting-for-foreground")
        task = Task { @MainActor [weak scene] in
            var activated = false
            var recordedReady = false
            defer {
                if self.generation == currentGeneration { VVClearKeyboardHandoff(); self.task = nil }
            }
            while !Task.isCancelled, request.isFresh(), let scene {
                // URL delivery can precede foreground activation. Starting an
                // audio recording session during that interval can be rejected.
                if !activated, scene.activationState == .foregroundActive {
                    activated = true
                    VoiceHost.shared.enable()
                    Self.record("waiting-for-microphone")
                }
                if activated, !VoiceHost.shared.enabled, !VoiceHost.shared.enabling {
                    Self.record("microphone-not-ready")
                    return
                }
                if activated, VoiceHost.shared.enabled,
                   VoiceIPC.read("ready.json", as: VoiceReadiness.self)?.isFresh == true,
                   scene.activationState == .foregroundActive {
                    #if DEBUG
                    if !recordedReady {
                        recordedReady = true
                        Self.record("microphone-ready-waiting-for-host")
                    }
                    var resolved = request
                    if resolved.returnDestination == nil {
                        resolved.returnBundleIdentifier = VVKeyboardHostObservedSince(request.createdAt)
                    }
                    if let destination = resolved.returnDestination {
                        do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                        guard !Task.isCancelled, request.isFresh(), VoiceHost.shared.enabled,
                              scene.activationState == .foregroundActive,
                              VoiceIPC.read("ready.json", as: VoiceReadiness.self)?.isFresh == true else { return }
                        Self.record(VVReturnToKeyboardHost(destination) ? "return-accepted" : "return-rejected")
                        return // A rejected launch never causes a retry loop.
                    }
                    #else
                    return // Release activates the microphone; returning is manual.
                    #endif
                }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
            if !Task.isCancelled { Self.record("handoff-expired") }
        }
    }

    func cancel() {
        if task != nil { Self.record("handoff-cancelled") }
        generation = UUID()
        task?.cancel()
        task = nil
    }

    private static func record(_ stage: String) {
        #if DEBUG
        // One overwritten diagnostic, with no app identity, text, audio or key.
        let values = ["stage": stage, "time": String(Date().timeIntervalSince1970), "observer": VVKeyboardHandoffDiagnostic()]
        if let data = try? JSONEncoder().encode(values) {
            try? data.write(to: URL.documentsDirectory.appendingPathComponent("handoff-debug.json"), options: .atomic)
        }
        #endif
    }
}
