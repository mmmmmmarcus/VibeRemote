import Foundation
import Security
import SwiftUI

enum CommandBackend: String, CaseIterable, Identifiable {
    case codex, claude, hybrid, jev
    var id: String { rawValue }
    // Standalone Jev remains private; it is a decision model, not a general planner.
    static let available: [Self] = [.codex, .claude, .hybrid]
    static let preferenceKey = "commandBackend"
    static var selected: Self { Self(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "") ?? .codex }
    var title: String {
        switch self {
        case .codex: return "Codex · Local CLI"
        case .claude: return "Claude · Local CLI"
        case .hybrid: return "Codex + Jev · OpenRouter"
        case .jev: return "Jev · Unavailable"
        }
    }
}

enum CommandKeychain {
    static var existingTestKeyURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/viberemote/openrouter-key")
    }
    private static var query: [String: Any] { [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.viberemote.openrouter",
        kSecAttrAccount as String: "api-key"
    ] }
    static func read() throws -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data,
              let key = String(data: data, encoding: .utf8) else { throw failure(status) }
        return key
    }
    static func contains() -> Bool {
        var q = query
        q[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }
    static func save(_ input: String) throws {
        let key = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.utf8.count <= 4096, !key.contains(where: \.isWhitespace) else {
            throw NSError(domain: "VibeRemote.Keychain", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Enter a valid API key without spaces."])
        }
        let attributes: [String: Any] = [kSecValueData as String: Data(key.utf8)]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query.merging(attributes) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw failure(status) }
    }
    static func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
    }
    private static func failure(_ status: OSStatus) -> NSError {
        NSError(domain: "VibeRemote.Keychain", code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Unable to access the macOS Keychain. Please unlock it and try again."])
    }
}

@MainActor
private final class CommandBackendForm: ObservableObject {
    @Published var draftKey = ""
    @Published var hasKey = false
    @Published var message = ""
}

@MainActor
struct CommandBackendSettings: View {
    @AppStorage(CommandBackend.preferenceKey) private var selected = CommandBackend.codex.rawValue
    @StateObject private var form = CommandBackendForm()
    private var backend: CommandBackend { CommandBackend(rawValue: selected) ?? .codex }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Command assistant").font(.system(size: 13, weight: .semibold))
            Picker("Backend", selection: $selected) {
                ForEach(CommandBackend.available) { Text($0.title).tag($0.rawValue) }
            }.pickerStyle(.menu).accessibilityIdentifier("settings.command.backend")
            if backend == .hybrid || backend == .jev {
                Text("Experimental cooperation: Codex plans and verifies; Known actions run as one sequence; Jev resolves ambiguities and checks the result. Uses your Codex CLI login. Delegated window content is sent to OpenRouter.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                SecureField(form.hasKey ? "Replace OpenRouter API key" : "OpenRouter API key", text: $form.draftKey)
                    .textFieldStyle(.roundedBorder).accessibilityIdentifier("settings.command.apiKey")
                HStack {
                    Button("Save key") {
                        do { try CommandKeychain.save(form.draftKey); form.draftKey = ""; form.hasKey = true; form.message = "Key saved." }
                        catch { form.message = error.localizedDescription }
                    }.disabled(form.draftKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Remove key") {
                        do { try CommandKeychain.remove(); form.draftKey = ""; form.hasKey = false; form.message = "Key removed." }
                        catch { form.message = error.localizedDescription }
                    }.disabled(!form.hasKey)
                }
                if !form.hasKey && FileManager.default.fileExists(atPath: CommandKeychain.existingTestKeyURL.path) {
                    Button("Import saved test key") {
                        do {
                            let key = try String(contentsOf: CommandKeychain.existingTestKeyURL, encoding: .utf8)
                            try CommandKeychain.save(key)
                            form.hasKey = true; form.draftKey = ""; form.message = "Key imported into macOS Keychain."
                        } catch { form.message = "Unable to import the saved key. Enter it above instead." }
                    }
                    .accessibilityIdentifier("settings.command.importKey")
                }
                Text(form.message.isEmpty ? (form.hasKey ? "Key configured · Stored in macOS Keychain" : "No key configured · Stored in macOS Keychain after saving") : form.message)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                let name = backend == .codex ? "codex" : "claude"
                Text("Uses your existing \(backend == .codex ? "Codex" : "Claude") CLI login. No API key needed here.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Text(RemoteCommandConfiguration.executable(name) == nil
                     ? "CLI not found. Install it and sign in first."
                     : "CLI found · Sign in using \(name == "codex" ? "codex login" : "claude auth login") if needed.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .onAppear { form.hasKey = CommandKeychain.contains() }
        .onChange(of: selected) { _, _ in form.draftKey = ""; form.message = "" }
        .onDisappear { form.draftKey = "" }
    }
}
