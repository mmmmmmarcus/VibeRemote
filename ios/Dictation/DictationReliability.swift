import Foundation

/// Coarse failure classes for dictation. They never carry provider bodies,
/// identifiers, keys or transcript text, so they are safe to show and to record.
enum DictationFailureKind: String, Codable, Sendable, CaseIterable {
    case offline, auth, quota, timeout, other

    /// Shown only when a hold produced no text at all.
    var recognitionMessage: String {
        switch self {
        case .offline: "No internet connection. Dictation needs a network."
        case .auth: "Speech service key was rejected. This build needs a new key."
        case .quota: "Speech service is rate-limited or out of quota. Try again later."
        case .timeout: "Recognition timed out. Try again."
        case .other: "Recognition unavailable. Check your connection or try again later."
        }
    }
    /// A rejected key or exhausted quota will fail again; do not spend a retry on it.
    var retryable: Bool { self != .auth && self != .quota }

    static let offlineCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
        .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff, .callIsActive,
    ]
    static func classify(_ error: Error) -> Self {
        let error = error as NSError
        guard error.domain == NSURLErrorDomain else { return .other }
        let code = URLError.Code(rawValue: error.code)
        if code == .timedOut { return .timeout }
        return offlineCodes.contains(code) ? .offline : .other
    }
    static func classify(httpStatus: Int) -> Self? {
        switch httpStatus {
        case 401, 403: .auth
        case 429: .quota
        default: nil
        }
    }
    /// Seed SAUC error frames. 45000081 is the server's audio wait timeout and
    /// 55000031 its overload/concurrency refusal. Text is inspected only for
    /// classification; it is never stored or shown.
    static func classify(seedCode: UInt32, message: String) -> Self {
        if seedCode == 45_000_081 { return .timeout }
        if seedCode == 55_000_031 { return .quota }
        let text = message.lowercased()
        if ["quota", "rate limit", "ratelimit", "too many", "concurrency"].contains(where: text.contains) { return .quota }
        if ["unauthor", "authentic", "access key", "api key", "permission", "forbidden"].contains(where: text.contains) { return .auth }
        return .other
    }
}

/// Short utterances skip ordinary polishing: there is little to correct and the
/// round trip would dominate their latency. A Han character counts 1 unit and a
/// Latin/digit word 1.5 units; up to 6 units skips (6 Han characters, or 4 words).
/// Translation always goes to Ark.
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

/// The last ten final dictation results, newest first, local to this device.
/// They let the user recover text after a dismissal or a failed commit. Never
/// sent to providers, logged or included in timing metrics.
struct DictationRecent: Codable, Equatable, Sendable {
    var text: String
    var date: Date
}
struct DictationRecentStore: Sendable {
    static let limit = 10
    static let maximumLength = 20_000
    static var shared: Self { Self(fileURL: VoiceIPC.root?.appendingPathComponent("DictationRecent.json")) }
    let fileURL: URL?

    var items: [DictationRecent] {
        guard let fileURL, let data = try? Data(contentsOf: fileURL), data.count <= 2_000_000,
              let saved = try? JSONDecoder().decode([DictationRecent].self, from: data) else { return [] }
        return Array(saved.filter { Self.accepts($0.text) }.prefix(Self.limit))
    }
    static func accepts(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf16.count <= maximumLength
    }
    func record(_ text: String, at date: Date = Date()) {
        guard fileURL != nil, Self.accepts(text) else { return }
        var list = items
        list.removeAll { $0.text == text }
        list.insert(DictationRecent(text: text, date: date), at: 0)
        save(Array(list.prefix(Self.limit)))
    }
    func clear() { save([]) }
    private func save(_ list: [DictationRecent]) {
        guard var fileURL, let data = try? JSONEncoder().encode(list) else { return }
        // Unless-open protection lets a dismissal during screen lock still save.
        do {
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUnlessOpen])
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try fileURL.setResourceValues(values)
        } catch { /* Best effort; never log dictated text. */ }
    }
}

/// Per-utterance durations in seconds, local only. Contains no transcript text,
/// lengths, keys, provider bodies or document information.
struct DictationTiming: Codable, Equatable, Sendable {
    enum Path: String, Codable, Sendable { case refined, live, partial, retry, empty, failed, cancelled }
    enum Polish: String, Codable, Sendable { case polished, translated, skippedShort, disabled, timedOut, failed }
    var date: Date
    /// Hold start → first audio chunk (microphone live).
    var micLive: Double?
    /// Hold start → release.
    var hold: Double?
    /// Release → live (bigmodel_async) final.
    var liveFinal: Double?
    /// Release → refined (bigmodel_nostream) final; nil with refinedTimedOut when it was not awaited.
    var refinedFinal: Double?
    var refinedTimedOut = false
    /// Release → recognized text chosen (before polishing).
    var recognition: Double?
    var polish: Polish?
    var polishDuration: Double?
    /// Release → final text handed to the keyboard.
    var textReady: Double?
    /// Release → keyboard acknowledged committing the text.
    var committed: Double?
    var path: Path?
    var retried = false
    var error: DictationFailureKind?

    init(date: Date) { self.date = date }
    var releaseToText: Double? { committed ?? textReady }
    var delivered: Bool { [.refined, .live, .partial, .retry].contains(path) }

    enum Step: String, CaseIterable { case microphone = "Microphone start", recognition = "Recognition", polishing = "Polishing", commit = "Inserting text" }
    var slowestStep: Step? {
        let steps: [(Step, Double?)] = [(.microphone, micLive), (.recognition, recognition), (.polishing, polishDuration),
                                        (.commit, committed.flatMap { c in textReady.map { c - $0 } })]
        return steps.compactMap { step, value in value.map { (step, $0) } }.max { $0.1 < $1.1 }?.0
    }
}

struct DictationTimingStore: Sendable {
    static let limit = 200
    static var shared: Self { Self(fileURL: VoiceIPC.root?.appendingPathComponent("DictationTiming.json")) }
    let fileURL: URL?

    func load() -> [DictationTiming] {
        guard let fileURL, let data = try? Data(contentsOf: fileURL), data.count <= 1_000_000,
              let saved = try? Self.decoder.decode([DictationTiming].self, from: data) else { return [] }
        return Array(saved.suffix(Self.limit))
    }
    func append(_ record: DictationTiming) {
        guard let fileURL else { return }
        let list = Array((load() + [record]).suffix(Self.limit))
        guard let data = try? Self.encoder(pretty: false).encode(list) else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    /// The anonymised export: the same fields as stored, nothing else.
    func exportJSON() -> String {
        let data = (try? Self.encoder(pretty: true).encode(load())) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }
    private static func encoder(pretty: Bool) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return encoder
    }
    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder
    }
}

struct DictationTimingSummary: Equatable {
    var count: Int
    var median: Double?
    var p90: Double?
    var slowestStep: DictationTiming.Step?

    init(_ records: [DictationTiming]) {
        count = records.count
        let delivered = records.filter(\.delivered)
        let durations = delivered.compactMap(\.releaseToText).sorted()
        median = Self.percentile(durations, 0.5)
        p90 = Self.percentile(durations, 0.9)
        var counts: [DictationTiming.Step: Int] = [:]
        for step in delivered.compactMap(\.slowestStep) { counts[step, default: 0] += 1 }
        slowestStep = DictationTiming.Step.allCases.max { (counts[$0] ?? 0) < (counts[$1] ?? 0) }
        if counts.isEmpty { slowestStep = nil }
    }
    /// Nearest-rank percentile.
    static func percentile(_ sorted: [Double], _ p: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let rank = Int((p * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }
    var text: String {
        guard count > 0 else { return "No dictations recorded yet." }
        var lines = ["\(count) dictation\(count == 1 ? "" : "s") recorded"]
        if let median, let p90 {
            lines.append(String(format: "Release to text: median %.1f s, p90 %.1f s", median, p90))
        }
        if let slowestStep { lines.append("Most common slow step: \(slowestStep.rawValue)") }
        return lines.joined(separator: "\n")
    }
}
