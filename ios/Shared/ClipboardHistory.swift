import Foundation

/// Five copied text items, local to the keyboard. Never sent to ASR or polishing.
@MainActor final class ClipboardHistory {
    private(set) var items: [String] = []
    private let fileURL: URL?
    static var defaultURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ClipboardHistory/recent.json")
    }
    convenience init() { self.init(fileURL: Self.defaultURL) }
    init(fileURL: URL?) {
        self.fileURL = fileURL
        guard let fileURL, let data = try? Data(contentsOf: fileURL), data.count <= 1_000_000,
              let saved = try? JSONDecoder().decode([String].self, from: data) else { return }
        var seen = Set<String>()
        items = Array(saved.filter { Self.accepts($0) && seen.insert($0).inserted }.prefix(5))
    }
    static func accepts(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf16.count <= 20_000
    }
    func record(_ text: String) {
        guard Self.accepts(text), items.first != text else { return }
        items.removeAll { $0 == text }; items.insert(text, at: 0)
        items = Array(items.prefix(5)); save()
    }
    func clear() {
        items.removeAll()
        // Persist an empty list atomically; do not alter the system clipboard.
        save()
    }
    static func preview(_ text: String) -> String {
        let title = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return String(title.prefix(70)) + (title.count > 70 ? "…" : "")
    }
    private func save() {
        guard let fileURL, let data = try? JSONEncoder().encode(items) else { return }
        do {
            let folder = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var excluded = folder
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try excluded.setResourceValues(values)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        } catch { /* Keep a bounded in-memory list; never log clipboard content. */ }
    }
}
