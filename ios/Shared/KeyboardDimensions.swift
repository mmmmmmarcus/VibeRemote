import Foundation
import Darwin

/// Strict numeric allowlist. Rectangles are [x, y, width, height], insets are
/// [top, left, bottom, right], all in points. No timestamps or input metadata.
struct KeyboardDimensionSample: Codable, Equatable, Sendable {
    var rootBounds: [Double]
    var windowBounds: [Double]
    var rootSafeArea: [Double]
    var windowSafeArea: [Double]
    var requestedHeight: Double
    var headerFrame: [Double]
    var keysFrame: [Double]
    var rowHeights: [Double]
    var rowGaps: [Double]
    var keyGap: Double
    var orientation: Int // UIInterfaceOrientation: 0 unknown, 1–4 known.
    var mini: Int // 0 full, 1 mini.
    var appVersion: [Int]
    var buildVersion: [Int]

    var isValid: Bool {
        func numbers(_ values: [Double], _ count: Int? = nil, signed: Bool = false) -> Bool {
            (count == nil || values.count == count) && values.allSatisfy {
                $0.isFinite && (signed ? -16_384...16_384 : 0...16_384).contains($0)
            }
        }
        func rectangle(_ values: [Double]) -> Bool {
            numbers(values, 4, signed: true) && values[2] >= 0 && values[3] >= 0
        }
        func version(_ values: [Int]) -> Bool {
            (1...4).contains(values.count) && values.allSatisfy { (0...999_999).contains($0) }
        }
        return rectangle(rootBounds) && rectangle(windowBounds)
            && numbers(rootSafeArea, 4) && numbers(windowSafeArea, 4)
            && numbers([requestedHeight, keyGap]) && rectangle(headerFrame) && rectangle(keysFrame)
            && (1...5).contains(rowHeights.count) && numbers(rowHeights)
            && numbers(rowGaps, rowHeights.count - 1, signed: true)
            && (0...4).contains(orientation) && (0...1).contains(mini)
            && version(appVersion) && version(buildVersion)
    }
    static func numericVersion(_ value: String?) -> [Int] {
        guard let value, value.count <= 27 else { return [0] }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return [0] }
        let result = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }),
                  let number = Int(part), (0...999_999).contains(number) else { return nil }
            return number
        }
        return result.count == parts.count ? result : [0]
    }
}

enum KeyboardDimensionError: Error { case unavailable, corrupt, invalidSample, exportInProgress }

/// Independent from preferences transfer, snippets and dictation. Uses the same
/// protected atomic-replace/flock pattern as SnippetStore. Call off the UI actor.
struct KeyboardDimensionStore: Sendable {
    static let limit = 8
    static let byteLimit = 32_768
    static var shared: Self { Self(directory: VoiceIPC.root?.appendingPathComponent("KeyboardDimensions", isDirectory: true)) }
    let directory: URL?
    var exportDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("KeyboardDimensionsExport", isDirectory: true)
    struct State: Codable, Sendable {
        var schema = 1
        var enabled = false
        var generation = UUID() // Internal consent token, NEVER exported.
        var samples: [KeyboardDimensionSample] = []
    }
    private struct Export: Encodable { let schema = 1; let samples: [KeyboardDimensionSample] }

    // Atomic replacement makes reads complete snapshots. In particular, the
    // default-off layout probe never creates files/directories or takes a lock.
    func load() throws -> State { try read() }
    func setEnabled(_ enabled: Bool) throws {
        try locked {
            var state = try read()
            state.enabled = enabled; state.generation = UUID()
            try write(state)
        }
    }
    /// Clearing also stops collection, so queued layouts cannot refill the list.
    func clear() throws {
        try locked {
            // Never remove a file while a Files picker in another scene uses it.
            let export = try acquireExport()
            defer { export.release() }
            try write(State())
            try export.removeFiles()
        }
    }
    /// Host launch/foreground recovery. Do not create storage on a fresh install.
    /// A live export is not an orphan; flock is released automatically on process death.
    func recover() throws {
        guard let directory else { throw KeyboardDimensionError.unavailable }
        guard FileManager.default.fileExists(atPath: directory.path)
            || FileManager.default.fileExists(atPath: exportDirectory.path) else { return }
        try locked {
            do {
                let export = try acquireExport()
                defer { export.release() }
                try export.removeFiles()
            } catch KeyboardDimensionError.exportInProgress { /* Live picker owns its staging file. */ }
        }
    }
    /// Hold this lease through picker completion/cancellation, not merely file creation.
    func beginExport() throws -> ExportSession {
        try locked {
            let export = try acquireExport()
            do {
                try export.removeFiles()
                let data = try exportJSON()
                try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true,
                    attributes: Self.protectionAttributes(directory: true))
                try protect(exportDirectory)
                try data.write(to: export.file, options: [.withoutOverwriting, .completeFileProtection])
                try protect(export.file)
                return export
            } catch {
                try? export.finish()
                throw error
            }
        }
    }
    // The separate lease never waits while holding store.lock, avoiding lock-order deadlocks.
    private func acquireExport() throws -> ExportSession {
        guard let directory else { throw KeyboardDimensionError.unavailable }
        let lock = directory.appendingPathComponent("export.lock")
        let fd = open(lock.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw KeyboardDimensionError.unavailable }
        do { try protect(lock) } catch { close(fd); throw error }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let active = errno == EWOULDBLOCK
            close(fd)
            throw active ? KeyboardDimensionError.exportInProgress : KeyboardDimensionError.unavailable
        }
        return ExportSession(directory: exportDirectory, descriptor: fd)
    }
    /// File lifecycle is serialized even if a controller is released during a detached cleanup.
    final class ExportSession: @unchecked Sendable {
        let file: URL
        private let directory: URL
        private let mutex = NSLock()
        private var descriptor: Int32
        fileprivate init(directory: URL, descriptor: Int32) {
            self.directory = directory; self.descriptor = descriptor
            file = directory.appendingPathComponent("KeyboardDimensions.json")
        }
        fileprivate func removeFiles() throws {
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
        }
        fileprivate func release() {
            mutex.lock(); defer { mutex.unlock() }
            if descriptor >= 0 { flock(descriptor, LOCK_UN); close(descriptor); descriptor = -1 }
        }
        func finish() throws {
            mutex.lock(); defer { mutex.unlock() }
            guard descriptor >= 0 else { return }
            defer { flock(descriptor, LOCK_UN); close(descriptor); descriptor = -1 }
            try removeFiles()
        }
        deinit { try? finish() }
    }
    func append(_ sample: KeyboardDimensionSample, generation: UUID, fullAccess: Bool) throws {
        guard fullAccess else { throw KeyboardDimensionError.unavailable }
        guard sample.isValid else { throw KeyboardDimensionError.invalidSample }
        try locked {
            var state = try read()
            guard state.enabled, state.generation == generation else { return }
            guard !state.samples.contains(sample) else { return }
            state.samples = Array((state.samples + [sample]).suffix(Self.limit))
            try write(state)
        }
    }
    func exportJSON() throws -> Data {
        let state = try load()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Re-encode the allowlist, never export raw disk bytes or consent tokens.
        return try encoder.encode(Export(samples: state.samples))
    }
    static func protectionAttributes(directory: Bool) -> [FileAttributeKey: Any] {
        [.protectionKey: FileProtectionType.complete, .posixPermissions: directory ? 0o700 : 0o600]
    }
    private func protect(_ url: URL) throws {
        try FileManager.default.setAttributes(Self.protectionAttributes(directory: url.hasDirectoryPath), ofItemAtPath: url.path)
        var url = url
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
    private func locked<T>(_ operation: () throws -> T) throws -> T {
        guard let directory else { throw KeyboardDimensionError.unavailable }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: Self.protectionAttributes(directory: true))
        try protect(directory)
        let lock = directory.appendingPathComponent("store.lock")
        let fd = open(lock.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw KeyboardDimensionError.unavailable }
        defer { close(fd) }
        try protect(lock)
        guard flock(fd, LOCK_EX) == 0 else { throw KeyboardDimensionError.unavailable }
        defer { flock(fd, LOCK_UN) }
        // Only our UUID-named write staging files, never unrelated App Group data.
        // All writers hold this same lock until rename, so these are necessarily orphans.
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            if url.pathExtension == "tmp", UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil {
                try FileManager.default.removeItem(at: url)
            }
        }
        return try operation()
    }
    private func read() throws -> State {
        guard let url = directory?.appendingPathComponent("samples.json") else { throw KeyboardDimensionError.unavailable }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else {
            if errno == ENOENT { return State() }
            throw KeyboardDimensionError.unavailable
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.byteLimit + 1) ?? Data()
        guard data.count <= Self.byteLimit,
              let state = try? JSONDecoder().decode(State.self, from: data), state.schema == 1,
              state.samples.count <= Self.limit, state.samples.allSatisfy(\.isValid) else { throw KeyboardDimensionError.corrupt }
        return state
    }
    private func write(_ state: State) throws {
        guard let directory else { throw KeyboardDimensionError.unavailable }
        let data = try JSONEncoder().encode(state)
        guard data.count <= Self.byteLimit else { throw KeyboardDimensionError.corrupt }
        let temporary = directory.appendingPathComponent(UUID().uuidString + ".tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: [.withoutOverwriting, .completeFileProtection])
        try protect(temporary)
        let fd = open(temporary.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw KeyboardDimensionError.unavailable }
        let synced = fsync(fd); close(fd)
        guard synced == 0, rename(temporary.path, directory.appendingPathComponent("samples.json").path) == 0 else {
            throw KeyboardDimensionError.unavailable
        }
    }
}

enum KeyboardDimensionCopy {
    static let title = "键盘尺寸诊断"
    static let privacy = "默认关闭。仅保留最近 8 组不重复的键盘尺寸、间距、安全区域、方向、完整／迷你模式及版本数字，仅存本机，不备份、不联网。不读取或记录输入内容、剪贴板、Snippet、所在 App、截图或凭据。"
    static let permission = "键盘未开启「允许完全访问」时，尺寸诊断不可用。请在系统设置 → 通用 → 键盘 → vvhisper 中开启后，重新打开键盘。主 App 无法直接确认这项权限。"
    static let unavailable = "尺寸诊断暂不可用，未能读取或保存本机数据。请解锁设备后重试。"
}
