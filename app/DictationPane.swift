import AppKit
import AVFoundation
import SwiftUI

/// Settings › Dictation: whether Siri runs VibeRemote's own dictation, which speech service
/// it uses, and the user's own keys for the cloud ones. Reads and writes the same defaults
/// and Keychain items `DictationController` reads at the start of every hold.
@MainActor
final class DictationSettingsStore: ObservableObject {
    @Published var settings = DictationSettings.load() {
        didSet { if settings != oldValue { settings.save() } }
    }
    @Published private(set) var savedKeys: Set<DictationProvider> = DictationSettingsStore.loadSavedKeys()
    @Published private(set) var microphone = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published private(set) var whisperProgress: Double?
    @Published private(set) var whisperError: String?
    @Published private(set) var whisperRevision = 0

    private static func loadSavedKeys() -> Set<DictationProvider> {
        Set(DictationProvider.allCases.filter { $0.needsAPIKey && DictationKeychain.key(for: $0) != nil })
    }

    var whisperInstalled: Bool {
        _ = whisperRevision
        return WhisperModelCatalog.installedFolder(for: settings.whisperModel) != nil
    }

    func saveKey(_ key: String, for provider: DictationProvider) {
        DictationKeychain.setKey(key, for: provider)
        savedKeys = Self.loadSavedKeys()
    }

    func refresh() {
        microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        savedKeys = Self.loadSavedKeys()
        whisperRevision += 1
    }

    func requestMicrophone() {
        if microphone == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                Task { @MainActor in self.refresh() }
            }
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    func downloadWhisperModel() {
        guard whisperProgress == nil else { return }
        let model = settings.whisperModel
        whisperProgress = 0
        whisperError = nil
        Task {
            do {
                try await WhisperKitDictationEngine.shared.prepare(model: model) { fraction in
                    Task { @MainActor in self.whisperProgress = fraction }
                }
            } catch {
                whisperError = error.localizedDescription
            }
            whisperProgress = nil
            whisperRevision += 1
        }
    }
}

struct DictationPane: View {
    /// Read only: the profiles whose Siri is set to Dictation. The Siri button's own choice in
    /// Settings › Controls is the one switch (per profile), so this pane carries no second toggle.
    let profiles: [String]
    /// Every profile resolves Siri to Dictation, so naming them adds nothing.
    var everywhere = false
    @StateObject private var store = DictationSettingsStore()
    @ObservedObject private var controller = DictationController.shared
    @State private var keyDraft = ""

    private var usage: String {
        guard !profiles.isEmpty else {
            return "Siri holds the key your own dictation app listens for. To have VibeRemote transcribe instead, choose Dictation for the Siri button in the Controls pane."
        }
        let scope = everywhere ? "" : " Siri uses it in: \(ListFormatter.localizedString(byJoining: profiles))."
        return "Hold Siri and speak. VibeRemote turns what you say into text and types it where your cursor is.\(scope)"
    }

    var body: some View {
        SettingsPane(title: "Dictation") {
            Section {
                if store.microphone != .authorized {
                    SettingsRow(title: "Microphone Access",
                                subtitle: "VibeRemote records the remote's microphone from its own audio device.",
                                statusDot: .red) {
                        Button(store.microphone == .notDetermined ? "Allow…" : "Open Settings…",
                               action: store.requestMicrophone)
                    }
                }
            } footer: {
                Text(usage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                SettingsRow(title: "Service") {
                    Picker("", selection: $store.settings.provider) {
                        ForEach(DictationProvider.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier("settings.dictation.provider")
                }
                SettingsRow(title: "Language") {
                    Picker("", selection: $store.settings.language) {
                        ForEach(DictationLanguage.choices, id: \.id) { Text($0.title).tag($0.id) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            } header: {
                Text("Service")
            } footer: {
                Text(serviceFooter)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            providerSection
            Section("Last Dictation") {
                SettingsRow(title: "Status") {
                    Text(statusText)
                        .foregroundStyle(statusIsError ? Color.red : .secondary)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onAppear(perform: store.refresh)
        .onChange(of: store.settings.provider) { keyDraft = "" }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.refresh()
        }
    }

    private var serviceFooter: String {
        switch store.settings.provider {
        case .apple: return "Runs on this Mac with Apple's speech model. It downloads its language the first time you dictate. Automatic uses your Mac's language."
        case .whisperKit: return "Runs OpenAI's Whisper on this Mac. Download a model once; nothing leaves your Mac."
        case .openAI: return "Sends each recording to OpenAI with your own API key."
        case .seedASR: return "Sends each recording to ByteDance's Volcengine (Doubao Seed ASR) with your own key. Strong on Chinese and mixed Chinese–English."
        }
    }

    @ViewBuilder private var providerSection: some View {
        switch store.settings.provider {
        case .apple:
            EmptyView()
        case .whisperKit:
            Section("WhisperKit") {
                SettingsRow(title: "Model") {
                    Picker("", selection: $store.settings.whisperModel) {
                        ForEach(WhisperModelCatalog.models, id: \.id) { Text($0.title).tag($0.id) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                SettingsRow(title: "Download", subtitle: store.whisperError) {
                    if let progress = store.whisperProgress {
                        ProgressView(value: progress)
                            .frame(width: 140)
                    } else if store.whisperInstalled {
                        Text("Installed").foregroundStyle(.secondary)
                    } else {
                        Button("Download", action: store.downloadWhisperModel)
                    }
                }
            }
        case .openAI:
            Section("OpenAI") {
                keyRow(provider: .openAI, prompt: "sk-…")
                SettingsRow(title: "Model") {
                    Picker("", selection: $store.settings.openAIModel) {
                        ForEach(modelChoices(OpenAIDictationEngine.models, keeping: store.settings.openAIModel), id: \.self) {
                            Text($0).tag($0)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
        case .seedASR:
            Section {
                keyRow(provider: .seedASR, prompt: "API key or Access Token")
                SettingsRow(title: "Type While Speaking",
                            subtitle: "Words appear as you talk without being rewritten; when you let go, the whole clip is recognized once more and the text is refined.") {
                    Toggle("", isOn: $store.settings.seedStreaming)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                SettingsRow(title: "App ID") {
                    TextField("", text: $store.settings.seedAppID, prompt: Text("Older console only"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                }
            } header: {
                Text("Seed ASR")
            } footer: {
                Text("Create an API key for Doubao speech recognition in the Volcengine console. Keys from the older console are an Access Token plus its App ID.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func keyRow(provider: DictationProvider, prompt: String) -> some View {
        let saved = store.savedKeys.contains(provider)
        return SettingsRow(title: "API Key", subtitle: saved ? "Saved in Keychain" : nil) {
            HStack(spacing: SettingsMetrics.md) {
                SecureField("", text: $keyDraft, prompt: Text(saved ? "Replace key" : prompt))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .onSubmit { saveKey(provider) }
                Button("Save") { saveKey(provider) }.disabled(keyDraft.isEmpty)
            }
        }
    }

    private func saveKey(_ provider: DictationProvider) {
        guard !keyDraft.isEmpty else { return }
        store.saveKey(keyDraft, for: provider)
        keyDraft = ""
    }

    /// A saved model missing from the list (renamed, or set elsewhere) stays selectable.
    private func modelChoices(_ models: [String], keeping selected: String) -> [String] {
        models.contains(selected) ? models : models + [selected]
    }

    private var statusText: String {
        switch controller.phase {
        case .idle: return "Hold Siri to dictate."
        case .recording: return "Listening…"
        case .transcribing: return "Transcribing…"
        case .finished(let message), .failed(let message): return message
        }
    }

    private var statusIsError: Bool {
        if case .failed = controller.phase { return true }
        return false
    }
}
