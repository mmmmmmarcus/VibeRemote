import Foundation
import Combine

@MainActor
final class ConfigurationSync: ObservableObject {
    enum Role: String, CaseIterable { case seedASR, polishing, polishDictation, sentencePunctuation
        var isKey: Bool { self == .seedASR || self == .polishing }
    }
    private static let bookmarkKey = "configuration.file.bookmark.v1"
    private static let passwordKey = "configuration.file.passwordID.v1"
    private static let baselineKey = "configuration.file.baseline.v1"
    @Published private(set) var enabled: Bool
    @Published private(set) var status = "No sync file linked. Existing keys stay on this device."
    @Published private(set) var hasConflict = false
    @Published private(set) var busy = false
    private let defaults: UserDefaults
    private let readLocal: (Role) throws -> String?
    private let writeLocal: (Role, String?) throws -> Void
    private var timer: Timer?
    private var applying = false
    private var generation = UUID()
    var didApply: (() -> Void)?

    init(defaults: UserDefaults, read: @escaping (Role) throws -> String?,
         write: @escaping (Role, String?) throws -> Void) {
        self.defaults = defaults; readLocal = read; writeLocal = write
        enabled = defaults.data(forKey: Self.bookmarkKey) != nil
    }
    func start() {
        guard timer == nil else { return }
        // Host apps only; the iOS keyboard consumes the existing local key store.
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }
    func disconnect() {
        generation = UUID()
        if let account = defaults.string(forKey: Self.passwordKey) { ConfigurationFilePassword.remove(account) }
        defaults.removeObject(forKey: Self.passwordKey)
        defaults.removeObject(forKey: Self.bookmarkKey)
        defaults.removeObject(forKey: Self.baselineKey)
        enabled = false; hasConflict = false
        status = "File disconnected. Local keys and the encrypted file are unchanged."
    }
    func connect(_ url: URL, password: String) async throws {
        guard !busy else { throw ConfigurationError.fileAccess }
        busy = true; defer { busy = false }
        let current = generation
        let bookmark = try await Task.detached {
            _ = try EncryptedConfiguration.open(ConfigurationFile.read(url), password: password)
            return try ConfigurationFile.bookmark(url)
        }.value
        guard current == generation else { throw ConfigurationError.fileAccess }
        let account = UUID().uuidString
        try ConfigurationFilePassword.save(password, account: account)
        if let old = defaults.string(forKey: Self.passwordKey) { ConfigurationFilePassword.remove(old) }
        defaults.set(account, forKey: Self.passwordKey)
        defaults.set(bookmark, forKey: Self.bookmarkKey)
        defaults.removeObject(forKey: Self.baselineKey)
        enabled = true; hasConflict = false
        status = "File linked. Checking for changes…"
        // Refresh after busy is cleared; no local credential is changed by linking itself.
        Task { @MainActor [weak self] in self?.refresh() }
    }
    func refresh(resolution: ConfigurationMerge.Resolution = .automatic) {
        guard enabled, !busy, !applying, let bookmark = defaults.data(forKey: Self.bookmarkKey) else { return }
        busy = true
        let current = generation
        Task {
            defer { busy = false }
            do {
                guard let account = defaults.string(forKey: Self.passwordKey) else { throw ConfigurationError.fileAccess }
                let password = try ConfigurationFilePassword.read(account)
                let local = try document(includeKeys: true)
                let snapshot = try await Task.detached {
                    let resolved = try ConfigurationFile.resolve(bookmark)
                    let data = try ConfigurationFile.read(resolved.url)
                    return (resolved.url, data, try EncryptedConfiguration.open(data, password: password), resolved.bookmark)
                }.value
                guard generation == current, enabled else { return }
                // Edits made while downloading/decrypting always win over a stale task.
                guard try document(includeKeys: true) == local else {
                    status = "Local settings changed. Will sync on the next check."; return
                }
                let baseline = defaults.dictionary(forKey: Self.baselineKey) as? [String: String] ?? [:]
                let merged = try ConfigurationMerge.merge(local: local, file: snapshot.2, baseline: baseline, resolution: resolution)
                if merged != snapshot.2 {
                    // Encrypt off main, then recheck local edits before coordinating the write.
                    let encrypted = try await Task.detached { try EncryptedConfiguration.seal(merged, password: password) }.value
                    guard generation == current, enabled, try document(includeKeys: true) == local else { return }
                    try await Task.detached { try ConfigurationFile.write(encrypted, to: snapshot.0, expected: snapshot.1) }.value
                }
                guard generation == current, enabled else { return }
                guard try document(includeKeys: true) == local else {
                    status = "Local settings changed. Will sync on the next check."; return
                }
                if merged != local { try apply(merged) }
                defaults.set(snapshot.3, forKey: Self.bookmarkKey)
                defaults.set(ConfigurationMerge.hashes(merged), forKey: Self.baselineKey)
                hasConflict = false
                status = "File checked. Cloud delivery may take time; local keys remain available offline."
            } catch {
                guard generation == current else { return }
                hasConflict = (error as? ConfigurationError) == .conflict
                status = hasConflict ? "Different settings or file versions were found. Choose a copy to keep, or resolve cloud versions in Files/Finder."
                    : (error as? ConfigurationError)?.localizedDescription ?? ConfigurationError.fileAccess.localizedDescription
            }
        }
    }
    func document(includeKeys: Bool) throws -> PortableConfiguration {
        try PortableConfiguration(settings: .init(polishDictation: readLocal(.polishDictation) == "true",
                                              sentencePunctuation: readLocal(.sentencePunctuation) == "true"),
                              credentials: includeKeys ? .init(seedASR: readLocal(.seedASR), polishing: readLocal(.polishing)) : nil)
    }
    func apply(_ document: PortableConfiguration) throws {
        _ = try PortableConfiguration.decode(document.encoded())
        var values: [(Role, String?)] = []
        if let v = document.credentials?.seedASR { values.append((.seedASR, v)) }
        if let v = document.credentials?.polishing { values.append((.polishing, v)) }
        if let v = document.settings.polishDictation { values.append((.polishDictation, String(v))) }
        if let v = document.settings.sentencePunctuation { values.append((.sentencePunctuation, String(v))) }
        let originals = try values.map { ($0.0, try readLocal($0.0)) }
        applying = true
        do {
            for (role, value) in values { try writeLocal(role, value) }
        } catch {
            var rollbackFailed = false
            for (role, value) in originals { do { try writeLocal(role, value) } catch { rollbackFailed = true } }
            applying = false
            throw rollbackFailed ? ConfigurationError.rollback : ConfigurationError.storage
        }
        applying = false; didApply?()
    }
}
