import Foundation

enum DictationShortText {
    static let maximumUnits = 6.0
    static func units(_ text: String) -> Double {
        var han = 0, words = 0, inWord = false
        for scalar in text.unicodeScalars {
            if isHan(scalar) { han += 1; inWord = false }
            else if scalar.properties.isAlphabetic || scalar.properties.numericType != nil {
                if !inWord { words += 1; inWord = true }
            } else if inWord, scalar == "'" || scalar == "\u{2019}" || scalar == "-" {
                continue // Contractions and hyphenated words stay one word.
            } else { inWord = false }
        }
        return Double(han) + Double(words) * 1.5
    }
    static func skipsPolishing(_ text: String) -> Bool { units(text) <= maximumUnits }
    private static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F: true
        default: false
        }
    }
}


/// A hard wall-clock budget that does not wait for a transport ignoring cancellation.
/// Resolution and cancellation are serialized on main; late values are discarded.
@MainActor final class DictationBudgetTask<Value: Sendable> {
    private var worker: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var result: Value?
    private var waiters: [CheckedContinuation<Value, Never>] = []
    private let fallback: Value
    private(set) var timedOut = false
    init(seconds: TimeInterval, fallback: Value, operation: @escaping @MainActor () async -> Value) {
        self.fallback = fallback
        worker = Task { [weak self] in
            let value = await operation()
            guard !Task.isCancelled else { return }
            self?.resolve(value)
        }
        timer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            self?.timedOut = true
            self?.resolve(fallback)
        }
    }
    private func resolve(_ value: Value) {
        guard result == nil else { return }
        result = value; worker?.cancel(); timer?.cancel(); worker = nil; timer = nil
        let pending = waiters; waiters = []; pending.forEach { $0.resume(returning: value) }
    }
    func cancel() { resolve(fallback) }
    func value() async -> Value {
        await withTaskCancellationHandler {
            if Task.isCancelled { cancel() }
            if let result { return result }
            return await withCheckedContinuation { waiters.append($0) }
        } onCancel: { Task { @MainActor in self.cancel() } }
    }
    deinit { worker?.cancel(); timer?.cancel() }
}

/// Only durations and fixed labels. Never captures transcript, audio, keys or editor data.
@MainActor final class DictationLatency {
    let started = ProcessInfo.processInfo.systemUptime
    var released: TimeInterval?
    var values: [String: Double] = [:]
    var labels: [String: String] = [:]
    private var saved = false
    func firstAudio(_ at: TimeInterval) { if values["micLive"] == nil { values["micLive"] = max(0, at - started) } }
    func markRelease() { released = ProcessInfo.processInfo.systemUptime; values["hold"] = released! - started }
    func mark(_ stage: String) { if let released { values[stage] = max(0, ProcessInfo.processInfo.systemUptime - released) } }
    func save() {
        guard !saved else { return }; saved = true
        var record: [String: Any] = values
        labels.forEach { record[$0] = $1 }; record["date"] = ISO8601DateFormatter().string(from: Date())
        guard let data = try? JSONSerialization.data(withJSONObject: record) else { return }
        Self.queue.async {
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("VibeRemote")
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let url = root.appendingPathComponent("DictationTiming.json")
            let old = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
            guard let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let output = try? JSONSerialization.data(withJSONObject: Array((old + [record]).suffix(200)), options: [.sortedKeys]) else { return }
            try? output.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
    private static let queue = DispatchQueue(label: "vvhisper.dictation.timing")
}
