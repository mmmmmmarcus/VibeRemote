import Foundation
import CRime

/// Offline Rime owner. All C API access, using build-time compiled dictionaries,
/// is serialized off the UI thread. No keystrokes or candidate text are logged/synced.
final class PinyinEngine: @unchecked Sendable {
    static let shared = PinyinEngine()
    enum Action: Sendable {
        case prepare, key(Int32), choose(Int), chooseAbsolute(Int), literal, english(String), clear, nextPage, previousPage
        case correction(text: String, input: String, revision: Int)
    }
    struct Snapshot: Sendable {
        var input = ""
        var preedit = ""
        var commitPreview = ""
        var candidates: [String] = []
        var corrections: [String] = []
        var suggestions: [String] = []
        var committed = ""
        var page = 0
        var isLastPage = true
        var error: String?
        var revision = 0
        var candidateOffset = 0
    }
    struct CandidateBatch: Sendable {
        let offset: Int
        let texts: [String]
        let hasMore: Bool
    }
    private let queue = DispatchQueue(label: "com.vvhisper.ios.pinyin", qos: .userInitiated)
    private var session: RimeSessionId = 0
    private var correctionSession: RimeSessionId = 0
    private var correctedInput = ""
    private var correctionCache: [String] = []
    private var suggestionCache: [String] = []
    private var typoIndex: PinyinTypoIndex?
    // Only this cancellation counter crosses queues; Rime and caches stay serial.
    private let requestLock = NSLock()
    private var requestGeneration: UInt64 = 0
    private var initialized = false
    private var strings: [UnsafeMutablePointer<CChar>] = []
    private var startupError: String?
    private var revision = 0

    @discardableResult
    func cancelCorrectionSearch() -> UInt64 {
        requestLock.lock(); defer { requestLock.unlock() }
        requestGeneration &+= 1
        return requestGeneration
    }

    private func isCurrent(_ request: UInt64) -> Bool {
        requestLock.lock(); defer { requestLock.unlock() }
        return requestGeneration == request
    }

    func perform(_ action: Action, completion: @escaping @MainActor @Sendable (Snapshot) -> Void) {
        let request = cancelCorrectionSearch()
        queue.async { [self] in
            let result = process(action, request: request)
            Task { @MainActor in
                // Preserve every ordered keystroke/commit callback, but never let
                // a cancelled search publish suggestions after a newer request.
                var delivered = result
                if !self.isCurrent(request) { delivered.suggestions = [] }
                completion(delivered)
            }
        }
    }

    /// Read more choices without turning Rime's page or changing the Space choice.
    /// Reject a response for an earlier composition, even if its spelling matches.
    func candidates(after offset: Int, revision expected: Int,
                    completion: @escaping @MainActor @Sendable (CandidateBatch?) -> Void) {
        queue.async { [self] in
            guard session != 0, expected == revision, offset >= 0, offset < Int(Int32.max) else {
                Task { @MainActor in completion(nil) }; return
            }
            let api = rime_get_api()!.pointee
            var iterator = RimeCandidateListIterator()
            var texts: [String] = []
            var hasMore = false
            if api.candidate_list_from_index!(session, &iterator, Int32(offset)) != 0 {
                defer { api.candidate_list_end!(&iterator) }
                while texts.count < 32, api.candidate_list_next!(&iterator) != 0 {
                    guard let text = iterator.candidate.text else { break }
                    texts.append(String(cString: text))
                }
                hasMore = api.candidate_list_next!(&iterator) != 0
            }
            let batch = CandidateBatch(offset: offset, texts: texts, hasMore: hasMore)
            Task { @MainActor in completion(batch) }
        }
    }

    private func initialize() {
        guard !initialized else { return }
        initialized = true
        guard let resources = Bundle.main.url(forResource: "Rime", withExtension: nil) else {
            startupError = "Pinyin dictionary is missing."; return
        }
        do {
            let cache = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("vvhisper-pinyin-v3", isDirectory: true)
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            func cString(_ value: String) -> UnsafePointer<CChar> {
                let pointer = strdup(value)!
                strings.append(pointer)
                return UnsafePointer(pointer)
            }
            var traits = RimeTraits()
            traits.data_size = Int32(MemoryLayout<RimeTraits>.size - MemoryLayout<Int32>.size)
            traits.shared_data_dir = cString(resources.path)
            traits.user_data_dir = cString(cache.path)
            traits.app_name = cString("rime.vvhisper")
            traits.distribution_name = cString("vvhisper")
            traits.distribution_code_name = cString("vvhisper")
            traits.distribution_version = cString("1.0")
            traits.min_log_level = 3
            traits.log_dir = cString("")
            let api = rime_get_api()!.pointee
            api.setup!(&traits)
            api.initialize!(&traits)
            // Bundled build/ contains compiled dictionaries. Never compile in an extension.
            session = api.create_session!()
            guard session != 0, api.select_schema!(session, "vvhisper_pinyin") != 0 else {
                startupError = "Pinyin could not start. Use English or reopen the keyboard."; return
            }
            api.set_option!(session, "ascii_mode", 0)
            typoIndex = PinyinTypoIndex(url: resources.appendingPathComponent("PinyinTypo.bin"))
            correctionSession = api.create_session!()
            if correctionSession != 0 {
                _ = api.select_schema!(correctionSession, "vvhisper_pinyin")
                api.set_option!(correctionSession, "ascii_mode", 0)
            }
        } catch {
            startupError = "Pinyin storage is unavailable. English typing still works."
        }
    }

    private func process(_ action: Action, request: UInt64) -> Snapshot {
        initialize()
        if let startupError { return Snapshot(error: startupError) }
        let api = rime_get_api()!.pointee
        var literal = ""
        let previousRevision = revision
        if case .prepare = action {} else { revision &+= 1 }
        switch action {
        case .prepare: break
        case .clear: api.clear_composition!(session)
        case .literal:
            literal = api.get_input!(session).map { String(cString: $0) } ?? ""
            api.clear_composition!(session)
        case .english(let word):
            literal = word
            api.clear_composition!(session)
        case .correction(let text, let input, let expected):
            let current = api.get_input!(session).map { String(cString: $0) } ?? ""
            if previousRevision == expected, current == input, suggestionCache.contains(text) {
                literal = text
                api.clear_composition!(session)
            }
        case .key(let key):
            let count = api.get_input!(session).map { strlen($0) } ?? 0
            // Bound composition memory; backspace/space remain available at the cap.
            if count < 64 || key == 0xff08 || key == 0x20 { _ = api.process_key!(session, key, 0) }
        case .choose(let index): _ = api.select_candidate_on_current_page!(session, index)
        case .chooseAbsolute(let index):
            if index >= 0 { _ = api.select_candidate!(session, index) }
        case .nextPage: _ = api.change_page!(session, 0)
        case .previousPage: _ = api.change_page!(session, 1)
        }
        var snapshot = Snapshot(committed: literal, revision: revision)
        var commit = RimeCommit()
        commit.data_size = Int32(MemoryLayout<RimeCommit>.size - MemoryLayout<Int32>.size)
        if api.get_commit!(session, &commit) != 0 {
            snapshot.committed += commit.text.map { String(cString: $0) } ?? ""
            _ = api.free_commit!(&commit)
        }
        snapshot.input = api.get_input!(session).map { String(cString: $0) } ?? ""
        var context = RimeContext()
        context.data_size = Int32(MemoryLayout<RimeContext>.size - MemoryLayout<Int32>.size)
        if api.get_context!(session, &context) != 0 {
            snapshot.preedit = context.composition.preedit.map { String(cString: $0) } ?? ""
            snapshot.commitPreview = context.commit_text_preview.map { String(cString: $0) } ?? ""
            snapshot.page = Int(context.menu.page_no)
            snapshot.candidateOffset = Int(context.menu.page_no) * Int(context.menu.page_size)
            snapshot.isLastPage = context.menu.is_last_page != 0
            if let candidates = context.menu.candidates {
                for index in 0..<Int(context.menu.num_candidates) {
                    if let text = candidates[index].text { snapshot.candidates.append(String(cString: text)) }
                }
            }
            _ = api.free_context!(&context)
        }
        if snapshot.input != correctedInput {
            correctedInput = snapshot.input
            correctionCache = correctedCandidates(for: snapshot.input)
            suggestionCache = []
            if isCurrent(request), let typoIndex {
                let deadline = ProcessInfo.processInfo.systemUptime + 0.060
                let search = typoIndex.search(snapshot.input, cancelled: { !self.isCurrent(request) })
                suggestionCache = dictionaryCandidates(search.repairs, deadline: deadline, request: request)
            }
        }
        snapshot.corrections = snapshot.page == 0 ? correctionCache : []
        snapshot.suggestions = snapshot.page == 0 && isCurrent(request) ? suggestionCache : []
        return snapshot
    }

    /// At most four spellings / two Rime choices each, with a cooperative 60 ms
    /// total deadline. Rime calls themselves cannot be interrupted. Select in an
    /// isolated session and require the entire repaired spelling to commit.
    private func dictionaryCandidates(_ repairs: [PinyinTypoIndex.Repair], deadline: TimeInterval,
                                      request: UInt64) -> [String] {
        guard correctionSession != 0 else { return [] }
        let api = rime_get_api()!.pointee
        defer { api.clear_composition!(correctionSession) }
        var result: [String] = []
        for repair in repairs {
            for candidate in 0..<2 {
                guard isCurrent(request), ProcessInfo.processInfo.systemUptime < deadline else { return [] }
                api.clear_composition!(correctionSession)
                for byte in repair.spelling.utf8 { _ = api.process_key!(correctionSession, Int32(byte), 0) }
                _ = api.select_candidate!(correctionSession, candidate)
                var commit = RimeCommit()
                commit.data_size = Int32(MemoryLayout<RimeCommit>.size - MemoryLayout<Int32>.size)
                guard api.get_commit!(correctionSession, &commit) != 0 else { continue }
                let text = commit.text.map { String(cString: $0) } ?? ""
                _ = api.free_commit!(&commit)
                let remaining = api.get_input!(correctionSession).map { String(cString: $0) } ?? ""
                if remaining.isEmpty, text.count >= 2,
                   !text.unicodeScalars.contains(where: { $0.isASCII }),
                   !result.contains(text), !correctionCache.contains(text) { result.append(text) }
                if result.count == 3 { return isCurrent(request) ? result : [] }
            }
        }
        return isCurrent(request) ? result : []
    }

    /// A separate, queue-owned Rime session tests repairs without editing the
    /// real composition. Only complete Chinese commits can become suggestions.
    private func correctedCandidates(for input: String) -> [String] {
        guard correctionSession != 0 else { return [] }
        let api = rime_get_api()!.pointee
        var result: [String] = []
        for spelling in PinyinTypo.spellings(for: input) {
            api.clear_composition!(correctionSession)
            for byte in spelling.utf8 { _ = api.process_key!(correctionSession, Int32(byte), 0) }
            _ = api.select_candidate!(correctionSession, 0)
            var commit = RimeCommit()
            commit.data_size = Int32(MemoryLayout<RimeCommit>.size - MemoryLayout<Int32>.size)
            guard api.get_commit!(correctionSession, &commit) != 0 else { continue }
            let text = commit.text.map { String(cString: $0) } ?? ""
            _ = api.free_commit!(&commit)
            let remaining = api.get_input!(correctionSession).map { String(cString: $0) } ?? ""
            if remaining.isEmpty, text.count >= 2, !text.unicodeScalars.contains(where: { $0.isASCII }), !result.contains(text) { result.append(text) }
            if result.count == 3 { break }
        }
        api.clear_composition!(correctionSession)
        return result
    }
}
