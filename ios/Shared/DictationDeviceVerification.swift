#if DEBUG
import Foundation

/// Explicit local QA through the real keyboard proxy. Only synthetic fixture
/// comparisons and marked-state booleans are persisted, never editor text.
enum DictationDeviceVerification {
    struct Request: Codable {
        var id = UUID()
        var createdAt = Date()
        var emptyStart = false
        var chinese = false
        var isFresh: Bool { (0..<12).contains(Date().timeIntervalSince(createdAt)) }
        var prefix: String { emptyStart ? "" : "vvhisper verification: " }
        var draft: String { chinese ? "我知道了" : "rough speech" }
        var continuation: String { chinese ? "谢谢" : " grows" }
        var polished: String { chinese ? "我知道了。" : "Polished speech." }
        var final: String { prefix + polished }
    }
    struct Result: Codable {
        let id: UUID
        let completed: Bool
        let elapsed: TimeInterval
        let state: [String: Int]
    }
    struct Report: Codable {
        let completed: Bool
        let markedWhilePending: Bool
        let markedAfterCompletion: Bool
        let finalTextMatches: Bool
        let elapsed: TimeInterval
        let state: [String: Int]
        var passed: Bool { completed && markedWhilePending && !markedAfterCompletion && finalTextMatches }
    }
}
#endif
