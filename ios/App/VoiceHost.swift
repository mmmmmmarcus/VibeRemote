import AVFoundation
import Foundation

/// Setup only. This app never activates an audio session or keeps an idle mic open.
@MainActor final class VoiceHost {
    static let shared = VoiceHost()
    var onChange: (() -> Void)?
    private(set) var status = "Preparing voice input."
    private(set) var enabled = false
    private(set) var enabling = false

    func enable() {
        guard !enabling else { return }
        do { try VoiceConfiguration.migrateHostConfiguration() }
        catch { enabled = false; status = error.localizedDescription; onChange?(); return }
        guard SeedKeychain.read()?.isEmpty == false else { enabled = false; status = "Speech recognition is unavailable in this build."; onChange?(); return }
        enabling = true
        AVAudioApplication.requestRecordPermission { granted in
            Task { @MainActor in
                VoiceConfiguration.defaults.set(granted, forKey: "voiceMicrophoneAllowed")
                self.enabling = false; self.enabled = granted
                self.status = granted ? "Dictate directly in the keyboard." : "Allow microphone access in Settings."
                self.onChange?()
            }
        }
    }
}
