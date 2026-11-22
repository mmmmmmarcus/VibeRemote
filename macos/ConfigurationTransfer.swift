import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
enum MacConfiguration {
    static let sync: ConfigurationSync = {
        let value = ConfigurationSync(defaults: .standard, read: { role in
            switch role {
            case .seedASR: return try DictationKeychain.configurationKey(service: "com.viberemote.dictation.seedasr")
            case .polishing: return try DictationKeychain.configurationKey(service: "com.viberemote.dictation.ark")
            case .polishDictation: return String(DictationSettings.load().polishDictation)
            case .sentencePunctuation: return String(DictationSettings.load().sentencePunctuation)
            }
        }, write: { role, value in
            switch role {
            case .seedASR: guard DictationKeychain.setKey(value, for: .seedASR) else { throw ConfigurationError.storage }
            case .polishing: guard DictationKeychain.setPolishKey(value) else { throw ConfigurationError.storage }
            case .polishDictation, .sentencePunctuation:
                guard let value, ["true", "false"].contains(value) else { throw ConfigurationError.storage }
                UserDefaults.standard.set(value == "true", forKey: role == .polishDictation ? "dictationPolish" : "dictationSentencePunctuation")
            }
        })
        value.didApply = {
            DictationSettingsStore.shared.settings = DictationSettings.load()
            DictationSettingsStore.shared.refresh()
        }
        return value
    }()
}

struct ConfigurationTransferSection: View {
    @ObservedObject private var sync = MacConfiguration.sync
    @State private var includeKeys = false
    @State private var working = false
    @State private var message: String?
    var body: some View {
        Section("Sync and Transfer") {
            Text(sync.status).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Create Sync File…") { exportFile(link: true) }
                Button("Link Existing File…") { openFile(link: true) }
            }.disabled(working || sync.busy)
            if sync.enabled {
                HStack {
                    Button("Sync Now") { sync.refresh() }
                    Button("Disconnect File") { sync.disconnect() }
                }.disabled(working || sync.busy)
            }
            if sync.hasConflict {
                HStack {
                    Button("Keep This Device") { sync.refresh(resolution: .local) }
                    Button("Keep File Values") { sync.refresh(resolution: .file) }
                }.disabled(working || sync.busy)
            }
            Text("Choose the same encrypted file in iCloud Drive on each device. Syncs ASR and polishing keys, Polish Dictation and Sentence Punctuation. Keep a copy of your password; it cannot be recovered.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Include API keys in encrypted export", isOn: $includeKeys)
            HStack {
                Button("Export Encrypted JSON…") { exportFile(link: false) }
                Button("Import Encrypted JSON…") { openFile(link: false) }
            }.disabled(working || sync.busy)
            if working { ProgressView().controlSize(.small) }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
    }
    private func password(creating: Bool) -> String? {
        let alert = NSAlert()
        alert.messageText = creating ? "Protect your configuration" : "Unlock configuration"
        alert.informativeText = creating
            ? "Choose a long, unique password (at least 8 characters). You’ll need the same password on your other devices."
            : "Enter this file’s password. Linking remembers it only in this device’s local Keychain."
        let stack = NSStackView(); stack.orientation = .vertical; stack.spacing = 8
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "Password"; stack.addArrangedSubview(field)
        let confirmation = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        if creating { confirmation.placeholderString = "Confirm password"; stack.addArrangedSubview(confirmation) }
        stack.frame = NSRect(x: 0, y: 0, width: 320, height: creating ? 56 : 24)
        alert.accessoryView = stack
        alert.addButton(withTitle: "Continue"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue
        defer { field.stringValue = ""; confirmation.stringValue = "" }
        guard !creating || value == confirmation.stringValue else { message = "Passwords don’t match."; return nil }
        do { try EncryptedConfiguration.validatePassword(value); return value }
        catch { message = error.localizedDescription; return nil }
    }
    private func exportFile(link: Bool) {
        guard let password = password(creating: true) else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "vvhisper-config.json"; panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        working = true
        Task {
            defer { working = false }
            do {
                let document = try sync.document(includeKeys: link || includeKeys)
                try await Task.detached {
                    let data = try EncryptedConfiguration.seal(document, password: password)
                    try ConfigurationFile.write(data, to: url, expected: nil)
                }.value
                if link { try await sync.connect(url, password: password) }
                message = link ? "Encrypted sync file created and linked." : "Encrypted configuration exported."
            } catch { message = safeError(error) }
        }
    }
    private func openFile(link: Bool) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let password = password(creating: false) else { return }
        working = true
        Task {
            defer { working = false }
            do {
                if link {
                    try await sync.connect(url, password: password)
                    message = "File linked. Check the sync status for conflicts."
                } else {
                    let document = try await Task.detached {
                        try EncryptedConfiguration.open(ConfigurationFile.read(url), password: password)
                    }.value
                    let alert = NSAlert(); alert.messageText = "Import configuration?"
                    alert.informativeText = "Replace only settings and keys included in this encrypted file? Omitted keys and device settings stay unchanged."
                    alert.addButton(withTitle: "Import"); alert.addButton(withTitle: "Cancel")
                    guard alert.runModal() == .alertFirstButtonReturn else { return }
                    try sync.apply(document); sync.refresh(); message = "Configuration imported."
                }
            } catch { message = safeError(error) }
        }
    }
    private func safeError(_ error: Error) -> String {
        (error as? ConfigurationError)?.localizedDescription ?? "Couldn’t access the configuration file. Local keys are unchanged."
    }
}
