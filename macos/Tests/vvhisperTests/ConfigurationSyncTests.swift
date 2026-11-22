import XCTest
@testable import vvhisper

final class ConfigurationSyncTests: XCTestCase {
    private let password = "vvhisper-test-密码🔐"
    private var document: PortableConfiguration {
        .init(settings: .init(polishDictation: false, sentencePunctuation: true),
              credentials: .init(seedASR: "test-asr", polishing: "test-ark"))
    }
    // Independent Node.js PBKDF2/AES-GCM vector, identical to the Android test resource.
    private let fixture = #"{"format":"vvhisper.encrypted","version":1,"kdf":"pbkdf2-sha256","iterations":600000,"cipher":"aes-256-gcm","salt":"ABEiM0RVZneImaq7zN3u/w==","nonce":"ABEiM0RVZneImaq7","ciphertext":"xawp9SjY1iw92ChK0rE3GasGC4RRZImLc8pZ6nk7mgvQwPaJB+0MEQv0hb+Q0L4KbeNDJpgtN8d8x0O+lqmBkbvOb90lxBsKuwQjtMnOR5SbKxQuCYTkJXzrk+d4dgU7NN9ko7db4e9li5nSiYw5dZL6+9rrv5Nob6DvmmjZFCUvyA7lB0jE9ZRK5MTV5wTLbgsdTuFgHfqNdPSlenbXgIlkuSNyObevRcYUe2c="}"#

    func testIndependentUTF8VectorAndRandomizedEncryptedRoundTrip() throws {
        XCTAssertEqual(try EncryptedConfiguration.open(Data(fixture.utf8), password: password), document)
        if let source = ProcessInfo.processInfo.environment["VVHISPER_CRYPTO_JAVA_FIXTURE"] {
            XCTAssertEqual(try EncryptedConfiguration.open(Data(contentsOf: URL(fileURLWithPath: source)), password: password), document)
        }
        let first = try EncryptedConfiguration.seal(document, password: password)
        let second = try EncryptedConfiguration.seal(document, password: password)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try EncryptedConfiguration.open(first, password: password), document)
        XCTAssertFalse(String(decoding: first, as: UTF8.self).contains("test-asr"))
        XCTAssertThrowsError(try EncryptedConfiguration.open(first, password: "wrong-password"))
        // Optional executable interoperability check; no real credentials enter this file.
        if let destination = ProcessInfo.processInfo.environment["VVHISPER_CRYPTO_TEST_OUTPUT"] {
            try first.write(to: URL(fileURLWithPath: destination))
        }
    }
    func testTamperingAndUnsupportedFilesFailBeforeImport() throws {
        let data = Data(fixture.utf8)
        var envelope = try JSONDecoder().decode(EncryptedConfiguration.Envelope.self, from: data)
        envelope.ciphertext[0] ^= 1
        XCTAssertThrowsError(try EncryptedConfiguration.open(JSONEncoder().encode(envelope), password: password))
        envelope = try JSONDecoder().decode(EncryptedConfiguration.Envelope.self, from: data)
        envelope.iterations = Int.max
        XCTAssertThrowsError(try EncryptedConfiguration.open(JSONEncoder().encode(envelope), password: password))
        XCTAssertThrowsError(try EncryptedConfiguration.open(document.encoded(), password: password))
        XCTAssertThrowsError(try EncryptedConfiguration.open(Data(repeating: 0, count: 131073), password: password))
        XCTAssertThrowsError(try EncryptedConfiguration.seal(document, password: "short"))
    }
    func testThreeWayMergePreservesKeysAndDetectsConflicts() throws {
        let original = document, baseline = ConfigurationMerge.hashes(document)
        var here = original, there = original
        here.settings.polishDictation = true
        there.settings.sentencePunctuation = false
        let merged = try ConfigurationMerge.merge(local: here, file: there, baseline: baseline, resolution: .automatic)
        XCTAssertEqual(merged.settings.polishDictation, true)
        XCTAssertEqual(merged.settings.sentencePunctuation, false)
        here.credentials?.seedASR = "local-key"; there.credentials?.seedASR = "remote-key"
        XCTAssertThrowsError(try ConfigurationMerge.merge(local: here, file: there, baseline: baseline, resolution: .automatic))
        XCTAssertThrowsError(try ConfigurationMerge.merge(local: here, file: there, baseline: [:], resolution: .automatic))
        XCTAssertEqual(try ConfigurationMerge.merge(local: here, file: there, baseline: baseline, resolution: .local).credentials?.seedASR, "local-key")
        XCTAssertEqual(try ConfigurationMerge.merge(local: here, file: there, baseline: baseline, resolution: .file).credentials?.seedASR, "remote-key")
        there.credentials = nil
        XCTAssertEqual(try ConfigurationMerge.merge(local: original, file: there, baseline: baseline, resolution: .automatic).credentials, original.credentials)
        here.credentials = nil
        XCTAssertEqual(try ConfigurationMerge.merge(local: here, file: original, baseline: [:], resolution: .automatic).credentials, original.credentials)
    }
    func testCoordinatedWriteRejectsStaleFileAndBoundedRead() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("config.json")
        let original = Data(fixture.utf8), newer = Data("newer".utf8)
        try ConfigurationFile.write(original, to: url, expected: nil)
        XCTAssertEqual(try ConfigurationFile.read(url), original)
        try ConfigurationFile.write(newer, to: url, expected: original)
        XCTAssertThrowsError(try ConfigurationFile.write(original, to: url, expected: original))
        XCTAssertEqual(try Data(contentsOf: url), newer)
        try Data(repeating: 0, count: 131073).write(to: url)
        XCTAssertThrowsError(try ConfigurationFile.read(url))
    }
    @MainActor
    func testImportRollbackMissingKeysAndLockedReads() throws {
        let f = Fixture(); f.local = [.seedASR: "old", .polishing: "old-ark", .polishDictation: "true"]
        try f.sync.apply(.init(settings: .init(polishDictation: false)))
        XCTAssertEqual(f.local[.seedASR], "old")
        f.failNextPolishing = true
        XCTAssertThrowsError(try f.sync.apply(document))
        XCTAssertEqual(f.local[.seedASR], "old"); XCTAssertEqual(f.local[.polishing], "old-ark")
        XCTAssertEqual(f.local[.polishDictation], "false")
        f.failRead = true
        XCTAssertThrowsError(try f.sync.apply(document))
        XCTAssertThrowsError(try f.sync.document(includeKeys: true))
        XCTAssertEqual(f.local[.seedASR], "old")
        XCTAssertNil(try f.sync.document(includeKeys: false).credentials)
    }
    #if os(macOS)
    @MainActor
    func testCredentialSideEffectsOnlyFollowCommittedKeyReplacements() throws {
        let f = Fixture()
        f.local = [.seedASR: "legacy-token", .polishing: "old-ark"]
        var replaced: [Set<ConfigurationSync.Role>] = []
        f.sync.didReplaceKeys = { replaced.append($0) }
        try f.sync.apply(.init(settings: .init(polishDictation: false)))
        XCTAssertTrue(replaced.isEmpty)
        f.failNextPolishing = true
        XCTAssertThrowsError(try f.sync.apply(document))
        XCTAssertTrue(replaced.isEmpty, "rollback must preserve the legacy App ID with its token")
        XCTAssertEqual(f.local[.seedASR], "legacy-token")
        try f.sync.apply(document)
        XCTAssertEqual(replaced, [Set([.seedASR, .polishing])])
        try f.sync.apply(document)
        XCTAssertEqual(replaced.count, 1, "unchanged credentials must not reset local authentication")
    }

    @MainActor
    func testLinkedFileLifecycleKeepsExistingKeysAndDisconnectPreservesFile() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("config.json")
        try EncryptedConfiguration.seal(document, password: password).write(to: url)
        let f = Fixture()
        f.local = [.seedASR: "existing-key", .polishing: "test-ark", .polishDictation: "false", .sentencePunctuation: "true"]
        defer { f.sync.disconnect() }
        try await f.sync.connect(url, password: password)
        await Task.yield()
        try await waitForSync(f.sync)
        XCTAssertTrue(f.sync.hasConflict)
        XCTAssertEqual(f.local[.seedASR], "existing-key")
        f.sync.refresh(resolution: .file)
        try await waitForSync(f.sync)
        XCTAssertFalse(f.sync.hasConflict)
        XCTAssertEqual(f.local[.seedASR], "test-asr")
        f.local[.polishDictation] = "true"
        f.sync.refresh()
        try await waitForSync(f.sync)
        XCTAssertEqual(try EncryptedConfiguration.open(ConfigurationFile.read(url), password: password).settings.polishDictation, true)
        let before = try Data(contentsOf: url)
        f.sync.disconnect()
        XCTAssertEqual(f.local[.seedASR], "test-asr")
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertFalse(f.sync.enabled)
    }
    @MainActor
    private func waitForSync(_ sync: ConfigurationSync) async throws {
        for _ in 0..<1000 {
            if !sync.busy { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Sync did not finish within ten seconds")
    }
    #endif
    @MainActor private final class Fixture {
        var local: [ConfigurationSync.Role: String] = [:]
        var failNextPolishing = false, failRead = false
        let defaults = UserDefaults(suiteName: "vvhisper.config.tests." + UUID().uuidString)!
        lazy var sync = ConfigurationSync(defaults: defaults, read: {
            if self.failRead && $0.isKey { throw ConfigurationError.storage }; return self.local[$0]
        }, write: {
            if $0 == .polishing && self.failNextPolishing { self.failNextPolishing = false; throw ConfigurationError.storage }
            self.local[$0] = $1
        })
    }
}
