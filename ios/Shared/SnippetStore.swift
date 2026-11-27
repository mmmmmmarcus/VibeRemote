import Foundation
import Darwin

struct Snippet: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let revision: UUID
    let abbreviation: String
    let content: String
    var key: String { abbreviation.lowercased() } // Validated ASCII only.
    var preview: String {
        let preview = content.prefix(21)
        return preview.prefix(20).map { $0.isNewline ? " " : String($0) }.joined() + (preview.count > 20 ? "…" : "")
    }
}

enum SnippetError: Error, Equatable {
    case abbreviationRequired, callMarker, invalidAbbreviation, duplicate, contentRequired
    case unavailable, corrupt, stale
    var message: String {
        switch self {
        case .abbreviationRequired: return "请输入缩写。"
        case .callMarker: return "这里只填缩写，不加 @@。"
        case .invalidAbbreviation: return "缩写只能包含英文字母、数字和下划线。"
        case .duplicate: return "这个缩写已被使用，请换一个。"
        case .contentRequired: return "请输入要填入的内容。"
        case .stale: return "这个 Snippet 已更新，请重新选择。"
        default: return "未能保存，请重试。"
        }
    }
    var isContentError: Bool { self == .contentRequired }
}

/// Independent, device-local App Group store. No defaults, transfer, clipboard,
/// provider, history or telemetry integration. All disk work runs off the UI actor.
/// flock serializes read/validate/replace across *processes* and store instances;
/// an actor alone would not protect the host against an extension's stale write.
struct SnippetStore: Sendable {
    static let shared = SnippetStore(directory: VoiceIPC.root?.appendingPathComponent("Snippets", isDirectory: true))
    let directory: URL?
    private struct Envelope: Codable { var version = 1; var records: [Snippet] }

    static func validCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.count == 1 && character.unicodeScalars.allSatisfy {
            (65...90).contains($0.value) || (97...122).contains($0.value) || (48...57).contains($0.value) || $0.value == 95
        }
    }
    static func validateAbbreviation(_ value: String) throws {
        if value.isEmpty { throw SnippetError.abbreviationRequired }
        if value.contains("@@") { throw SnippetError.callMarker }
        if !value.allSatisfy(validCharacter) { throw SnippetError.invalidAbbreviation }
    }
    static func validateContent(_ value: String) throws {
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw SnippetError.contentRequired }
    }

    func load() throws -> [Snippet] { try locked { try read() } }

    @discardableResult
    func save(abbreviation: String, content: String, replacing original: Snippet? = nil) throws -> Snippet {
        try Self.validateAbbreviation(abbreviation)
        return try locked {
            var records = try read()
            if records.contains(where: { $0.id != original?.id && $0.key == abbreviation.lowercased() }) { throw SnippetError.duplicate }
            try Self.validateContent(content)
            let item = Snippet(id: original?.id ?? UUID(), revision: UUID(), abbreviation: abbreviation, content: content)
            if let original {
                guard let index = records.firstIndex(where: { $0.id == original.id }), records[index].revision == original.revision else { throw SnippetError.stale }
                records[index] = item
            } else { records.append(item) }
            try write(records)
            return item
        }
    }
    func delete(_ original: Snippet) throws {
        try locked {
            var records = try read()
            guard let index = records.firstIndex(where: { $0.id == original.id }), records[index].revision == original.revision else { throw SnippetError.stale }
            records.remove(at: index)
            try write(records)
        }
    }

    static func protectionAttributes(directory: Bool) -> [FileAttributeKey: Any] {
        [.protectionKey: FileProtectionType.complete, .posixPermissions: directory ? 0o700 : 0o600]
    }
    private func protect(_ url: URL) throws {
        try FileManager.default.setAttributes(Self.protectionAttributes(directory: url.hasDirectoryPath), ofItemAtPath: url.path)
        var mutable = url
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try mutable.setResourceValues(values)
    }
    private func locked<T>(_ operation: () throws -> T) throws -> T {
        guard let directory else { throw SnippetError.unavailable }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: Self.protectionAttributes(directory: true))
        try protect(directory)
        let lock = directory.appendingPathComponent("store.lock")
        let descriptor = open(lock.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw SnippetError.unavailable }
        defer { close(descriptor) }
        try protect(lock)
        guard flock(descriptor, LOCK_EX) == 0 else { throw SnippetError.unavailable }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }
    private func read() throws -> [Snippet] {
        guard let url = directory?.appendingPathComponent("records.json") else { throw SnippetError.unavailable }
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
        catch { throw SnippetError.unavailable }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data), envelope.version == 1 else { throw SnippetError.corrupt }
        var ids = Set<UUID>(), keys = Set<String>()
        for record in envelope.records {
            guard (try? Self.validateAbbreviation(record.abbreviation)) != nil,
                  (try? Self.validateContent(record.content)) != nil,
                  ids.insert(record.id).inserted, keys.insert(record.key).inserted else { throw SnippetError.corrupt }
        }
        return envelope.records
    }
    private func write(_ records: [Snippet]) throws {
        guard let directory else { throw SnippetError.unavailable }
        let temporary = directory.appendingPathComponent(UUID().uuidString + ".tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let data = try JSONEncoder().encode(Envelope(records: records))
        try data.write(to: temporary, options: [.withoutOverwriting, .completeFileProtection])
        try protect(temporary) // Set backup exclusion BEFORE the atomic rename.
        let fd = open(temporary.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw SnippetError.unavailable }
        let synced = fsync(fd); close(fd)
        guard synced == 0 else { throw SnippetError.unavailable }
        guard rename(temporary.path, directory.appendingPathComponent("records.json").path) == 0 else { throw SnippetError.unavailable }
        // Atomic rename is the commit point; never report a failed save after it.
    }
}

enum SnippetCopy {
    static let introduction = "保存常用内容，用缩写调用，或在键盘里点选填入。"
    static let privacy = "这些 Snippet 保存在本机，不加入应用内同步、导出、剪贴板历史或 AI 请求。你选择填入后，内容会交给当前 App，由该 App 处理。你可以随时在这里修改或删除。"
    static let permission = "键盘需要「允许完全访问」，才能读取这里保存的 Snippet。这项权限也允许键盘联网，但本功能不会把保存的 Snippet 发送给 AI。"
    static let permissionDetail = "请在系统设置的键盘选项中，为 vvhisper 开启「允许完全访问」。" + permission
    static let unsafe = "无法确认缩写位置，请重新输入后选择。"
    static let insertionFailure = "未能填入，请点选输入框后重试。"
}
