import AppKit
import AVFoundation
import CoreAudio
import SwiftUI

/// Settings › Dictation: whether Siri runs vvhisper's own dictation, which speech service
/// it uses, and the user's own keys for the cloud ones. Reads and writes the same defaults
/// and Keychain items `DictationController` reads at the start of every hold.
@MainActor
final class DictationSettingsStore: ObservableObject {
    /// Settings and the menu edit one live value, so either surface cannot save a stale input.
    static let shared = DictationSettingsStore()
    @Published var settings = DictationSettings.load() {
        didSet { if settings != oldValue { settings.save() } }
    }
    @Published private(set) var savedKeys: Set<DictationProvider> = DictationSettingsStore.loadSavedKeys()
    @Published private(set) var microphone = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published private(set) var whisperProgress: Double?
    @Published private(set) var whisperError: String?
    @Published private(set) var whisperRevision = 0
    /// The inputs the hotkey can record, kept current while the pane is open.
    @Published private(set) var microphones: [DictationAudioDevice.Microphone] = []
    /// What "Same as System" records right now.
    @Published private(set) var systemMicrophone: DictationAudioDevice.Microphone?
    private var deviceWatcher: AudioDeviceWatcher?

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
        refreshMicrophones()
    }

    func refreshMicrophones() {
        microphones = DictationAudioDevice.microphones()
        systemMicrophone = DictationAudioDevice.macMicrophone(choice: nil)
        if deviceWatcher == nil {
            deviceWatcher = AudioDeviceWatcher { [weak self] in
                MainActor.assumeIsolated { self?.refreshMicrophones() }
            }
        }
    }

    /// The picker's selection: a device UID, or "" for Same as System.
    var hotkeyMicrophoneUID: String {
        get { settings.hotkeyMicrophone?.uid ?? "" }
        set {
            guard !newValue.isEmpty else { settings.hotkeyMicrophone = nil; return }
            let name = microphones.first(where: { $0.uid == newValue })?.name ?? settings.hotkeyMicrophone?.name ?? ""
            settings.hotkeyMicrophone = DictationMicrophoneChoice(uid: newValue, name: name)
        }
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

/// Calls back on main whenever an audio device appears or goes away, or the system input
/// changes, so the hotkey's microphone list never shows a stale device.
final class AudioDeviceWatcher: @unchecked Sendable {
    private static let selectors = [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice]
    private let block: AudioObjectPropertyListenerBlock

    init(onChange: @escaping @Sendable () -> Void) {
        block = { _, _ in onChange() }
        for selector in Self.selectors {
            var address = Self.address(selector)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        }
    }

    deinit {
        for selector in Self.selectors {
            var address = Self.address(selector)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }
}

struct DictationPane: View {
    /// Read only: the profiles whose Siri is set to Dictation. The Siri button's own choice in
    /// Settings › Controls is the one switch (per profile), so this pane carries no second toggle.
    let profiles: [String]
    /// Every profile resolves Siri to Dictation, so naming them adds nothing.
    var everywhere = false
    @ObservedObject private var store = DictationSettingsStore.shared
    @ObservedObject private var soundcore = SoundcoreManager.shared
    @State private var keyDraft = ""
    @State private var polishKeyDraft = ""
    @State private var hasPolishKey = DictationKeychain.polishKey() != nil

    /// The remote's voice comes straight from the voice helper; only the hotkey, which records
    /// the Mac's own microphone, needs Microphone access.
    private var needsMicrophone: Bool {
        store.microphone != .authorized && store.settings.hotkey != .none && !soundcore.useForHotkey
    }

    var body: some View {
        SettingsPane(title: "Dictation") {
            if needsMicrophone {
                Section {
                    if needsMicrophone {
                        SettingsRow(title: "Microphone Access", statusDot: .red) {
                            Button(store.microphone == .notDetermined ? "Allow…" : "Open Settings…",
                                   action: store.requestMicrophone)
                        }
                    }
                }
            }
            // The service and everything that belongs to it, in one group (2026-11-11).
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
                    if store.settings.provider == .seedASR {
                        // Seed's current stream/refinement paths use its default bilingual
                        // model. The shared single-language preference is for other engines.
                        Text("Chinese + English")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("settings.dictation.bilingualLanguage")
                    } else {
                        Picker("", selection: $store.settings.language) {
                            ForEach(DictationLanguage.choices, id: \.id) { Text($0.title).tag($0.id) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .accessibilityIdentifier("settings.dictation.language")
                    }
                }
                providerRows
            } header: {
                Text("Service")
            }
            Section {
                Toggle("Sentence Punctuation", isOn: $store.settings.sentencePunctuation)
                    .accessibilityIdentifier("settings.dictation.sentencePunctuation")
            } footer: {
                Text("Add ending punctuation to a single short sentence. Longer or multi-sentence dictation keeps its punctuation.")
            }
            Section {
                Toggle("Polish Dictation", isOn: $store.settings.polishDictation)
                    .accessibilityIdentifier("settings.dictation.polish")
                if store.settings.polishDictation {
                    SettingsRow(title: "Volcengine Ark API Key") {
                        SecureField(hasPolishKey ? "Saved — enter to replace" : "Required for polishing", text: $polishKeyDraft)
                            .textFieldStyle(.roundedBorder)
                        Button("Save") {
                            DictationKeychain.setPolishKey(polishKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines))
                            hasPolishKey = DictationKeychain.polishKey() != nil
                            polishKeyDraft = ""
                        }.disabled(polishKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if !hasPolishKey {
                        Text("Add an API key to enable polishing. Dictation keeps the original transcript until then.")
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("Correct grammar and spelling while preserving your meaning. Uses Seed 2.0 Mini with thinking disabled; requires a Volcengine Ark API key.")
            }
            Section {
                SettingsRow(title: "Hotkey") {
                    Picker("", selection: $store.settings.hotkey) {
                        ForEach(DictationHotkey.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier("settings.dictation.hotkey")
                }
                SettingsRow(title: "Microphone") {
                    Picker("", selection: Binding(get: {
                        soundcore.useForHotkey ? "__soundcore__" : store.hotkeyMicrophoneUID
                    }, set: { value in
                        soundcore.useForHotkey = value == "__soundcore__"
                        if value != "__soundcore__" { store.hotkeyMicrophoneUID = value }
                    })) {
                        Text(systemMicrophoneTitle).tag("")
                        ForEach(store.microphones, id: \.uid) { Text($0.name).tag($0.uid) }
                        Text(soundcore.ready ? "Soundcore Work" : "Soundcore Work (Not Connected)").tag("__soundcore__")
                        if let missing = missingMicrophone {
                            Text("\(missing.name) (Not Connected)").tag(missing.uid)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier("settings.dictation.hotkeyMicrophone")
                }
            } header: {
                Text("Voice Input")
            }
        }
        .onAppear(perform: store.refresh)
        .onChange(of: store.settings.provider) { keyDraft = "" }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.refresh()
        }
    }

    private var systemMicrophoneTitle: String {
        store.systemMicrophone.map { "Same as System (\($0.name))" } ?? "Same as System"
    }

    /// A chosen microphone that is not plugged in or paired right now, kept selectable so the
    /// choice survives until it comes back.
    private var missingMicrophone: DictationMicrophoneChoice? {
        guard let choice = store.settings.hotkeyMicrophone,
              !store.microphones.contains(where: { $0.uid == choice.uid }) else { return nil }
        return choice
    }

    /// The chosen service's own settings, inside the Service group.
    @ViewBuilder private var providerRows: some View {
        switch store.settings.provider {
        case .apple:
            EmptyView()
        case .whisperKit:
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
        case .openAI:
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
        case .seedASR:
            keyRow(provider: .seedASR, prompt: "API key or Access Token")
            SettingsRow(title: "Streaming Output") {
                Toggle("", isOn: $store.settings.seedStreaming)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            SettingsRow(title: "Remove Filler Words") {
                Toggle("", isOn: $store.settings.seedRemoveFillers)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            SettingsRow(title: "Use Text Before the Cursor") {
                Toggle("", isOn: $store.settings.seedEditorContext)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

        }
    }

    private func keyRow(provider: DictationProvider, prompt: String) -> some View {
        let saved = store.savedKeys.contains(provider)
        return SettingsRow(title: "API Key") {
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
}


/// Settings › Dictation › Dictionary: words dictation should get right. Each row is the word as it
/// should be written plus, optionally, the spellings recognizers produce instead. Edits save through
/// `DictationSettingsStore` like every other Dictation setting.
private struct DictionarySection: View {
    @Binding var entries: [DictationDictionaryEntry]
    let provider: DictationProvider

    var body: some View {
        Section {
            ForEach($entries) { $entry in
                HStack(spacing: SettingsMetrics.md) {
                    TextField("Word", text: $entry.word, prompt: Text("Word"))
                        .textFieldStyle(.roundedBorder)
                    Button {
                        entries.removeAll { $0.id == entry.id }
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(entry.word.isEmpty ? "word" : entry.word)")
                }
            }
            Button {
                entries.append(DictationDictionaryEntry(word: ""))
            } label: {
                Label("Add Word", systemImage: "plus")
            }
            .accessibilityIdentifier("settings.dictation.addWord")
        } header: {
            Text("Dictionary")
        }
    }
}

struct DictionaryPane: View {
    @ObservedObject private var store = DictationSettingsStore.shared
    var body: some View {
        SettingsPane(title: "Dictionary") {
            DictionarySection(entries: $store.settings.dictionary, provider: store.settings.provider)
        }
    }
}
