#if DEBUG
import Foundation

/// Explicit --verify-haptics fixture, restricted to the app's synthetic test field.
/// Counts API starts/completions, not physical vibration perception. No text logs.
enum HapticDeviceVerification {
    struct Request: Codable {
        let id: UUID
        let createdAt: Date
        var observeTouches = false
        var fixture: String { "haptic-check-\(id.uuidString)" }
        var isFresh: Bool { (0..<20).contains(Date().timeIntervalSince(createdAt)) }
    }
    struct Report: Codable {
        let id: UUID
        let requested: Int
        let customStarts: Int
        let customCompletions: Int
        let fallbacks: Int
        let errorCode: Int?
        let elapsed: TimeInterval
        var expectedRequests = 80
        var passed: Bool { requested == expectedRequests && customStarts == requested && customCompletions == requested && fallbacks == 0 && errorCode == nil }
    }
    @MainActor final class Burst {
        private var timer: Timer?
        func start(request: Request, feedback: KeyboardHaptics, stillValid: @escaping @MainActor @Sendable () -> Bool) {
            cancel()
            let starts = feedback.verificationCustomStarts
            let completions = feedback.verificationCustomCompletions
            let fallbacks = feedback.verificationFallbacks
            let requests = feedback.verificationRequests
            let began = ProcessInfo.processInfo.systemUptime
            var requested = 0
            var finishedAt: TimeInterval?
            let timer = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard request.isFresh, stillValid() else { self.cancel(); return }
                    if request.observeTouches {
                        requested = feedback.verificationRequests - requests
                        if requested >= 24, finishedAt == nil { finishedAt = ProcessInfo.processInfo.systemUptime }
                    } else if requested < 80 {
                        feedback.tap(); requested += 1
                        if requested == 80 { finishedAt = ProcessInfo.processInfo.systemUptime }
                    }
                    if let finishedAt, ProcessInfo.processInfo.systemUptime - finishedAt >= 0.5 {
                        let report = Report(id: request.id, requested: requested,
                            customStarts: feedback.verificationCustomStarts - starts,
                            customCompletions: feedback.verificationCustomCompletions - completions,
                            fallbacks: feedback.verificationFallbacks - fallbacks,
                            errorCode: feedback.verificationErrorCode, elapsed: finishedAt - began,
                            expectedRequests: request.observeTouches ? 24 : 80)
                        try? VoiceIPC.write(report, to: "haptic-check-result.json")
                        self.cancel()
                    }
                }
            }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        func cancel() { timer?.invalidate(); timer = nil }
        isolated deinit { timer?.invalidate() }
    }
}
#endif
