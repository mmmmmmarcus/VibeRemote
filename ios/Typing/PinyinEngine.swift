import Foundation
import CRime

/// Offline Rime owner. All C API access, using build-time compiled dictionaries,
/// is serialized off the UI thread. No keystrokes or candidate text are logged/synced.
final class PinyinEngine: @unchecked Sendable {
    static let shared = PinyinEngine()
    enum Action: Sendable {
        case prepare, key(Int32), choose(Int), literal, english(String), clear, nextPage, previousPage
    }
    struct Snapshot: Sendable {
        var input = ""
        var preedit = ""
        var commitPreview = ""
        var candidates: [String] = []
        var committed = ""
        var page = 0
        var isLastPage = true
        var error: String?
    }
    private let queue = DispatchQueue(label: "com.vvhisper.ios.pinyin", qos: .userInitiated)
    private var session: RimeSessionId = 0
    private var initialized = false
    private var strings: [UnsafeMutablePointer<CChar>] = []
    private var startupError: String?

    func perform(_ action: Action, completion: @escaping @MainActor @Sendable (Snapshot) -> Void) {
        queue.async { [self] in
            let result = process(action)
            Task { @MainActor in completion(result) }
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
        } catch {
            startupError = "Pinyin storage is unavailable. English typing still works."
        }
    }

    private func process(_ action: Action) -> Snapshot {
        initialize()
        if let startupError { return Snapshot(error: startupError) }
        let api = rime_get_api()!.pointee
        var literal = ""
        switch action {
        case .prepare: break
        case .clear: api.clear_composition!(session)
        case .literal:
            literal = api.get_input!(session).map { String(cString: $0) } ?? ""
            api.clear_composition!(session)
        case .english(let word):
            literal = word
            api.clear_composition!(session)
        case .key(let key):
            let count = api.get_input!(session).map { strlen($0) } ?? 0
            // Bound composition memory; backspace/space remain available at the cap.
            if count < 64 || key == 0xff08 || key == 0x20 { _ = api.process_key!(session, key, 0) }
        case .choose(let index): _ = api.select_candidate_on_current_page!(session, index)
        case .nextPage: _ = api.change_page!(session, 0)
        case .previousPage: _ = api.change_page!(session, 1)
        }
        var snapshot = Snapshot(committed: literal)
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
            snapshot.isLastPage = context.menu.is_last_page != 0
            if let candidates = context.menu.candidates {
                for index in 0..<Int(context.menu.num_candidates) {
                    if let text = candidates[index].text { snapshot.candidates.append(String(cString: text)) }
                }
            }
            _ = api.free_context!(&context)
        }
        return snapshot
    }
}
