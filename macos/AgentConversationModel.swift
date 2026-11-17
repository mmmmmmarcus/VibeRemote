import Foundation

/// Pure rules for identifying conversation navigation. A control's title is data,
/// never evidence that an arbitrary control is safe to press.
enum AgentConversationSelection {
    static func exact(_ title: String, candidates: [AgentDecisionCandidate]) -> String? {
        let matches = candidates.filter { normalize($0.label) == normalize(title) }
        return matches.count == 1 ? matches[0].id : nil
    }

    static func normalize(_ value: String) -> String {
        // Accessibility labels can use nonbreaking/thin spaces or repeated layout
        // whitespace. Preserve word boundaries and punctuation while comparing them.
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    static func isNavigation(role: String, label: String, subrole: String = "",
                             identifier: String = "", roleDescription: String = "") -> Bool {
        guard !isContent(role: role, subrole: subrole, roleDescription: roleDescription) else { return false }
        // A heading or button named "Chats" must not establish navigation ownership.
        let containers: Set<String> = ["AXOutline", "AXList", "AXGroup", "AXScrollArea", "AXSplitGroup", "AXWebArea"]
        guard containers.contains(role) else { return false }
        if role == "AXOutline" { return true }
        if ["AXLandmarkNavigation", "AXLandmarkComplementary"].contains(subrole) { return true }
        if ["navigation", "navigation landmark", "sidebar", "complementary", "complementary landmark",
            "导航", "侧边栏"].contains(normalize(roleDescription)) { return true }
        if ["sidebar", "chats", "conversations", "recent chats", "recents", "history", "threads",
            "侧边栏", "聊天", "会话", "历史记录", "最近"].contains(normalize(label)) { return true }

        // Match structural identifier tokens, not a loose "chat"/"side" substring.
        let tokens = normalize(identifier).components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        if tokens.contains("sidebar") { return true }
        let listNames: Set<String> = ["chat", "chats", "conversation", "conversations", "thread", "threads"]
        return zip(tokens, tokens.dropFirst()).contains { listNames.contains($0.0) && $0.1 == "list" }
    }

    static func isContent(role: String, subrole: String = "", roleDescription: String = "") -> Bool {
        if ["AXTextArea", "AXTextField", "AXComboBox", "AXSearchField"].contains(role) { return true }
        if ["AXLandmarkMain", "AXSearchField", "AXSecureTextField"].contains(subrole) { return true }
        return ["main", "main content", "text entry area", "text area", "search text field", "主内容"]
            .contains(normalize(roleDescription))
    }

    /// Focus alone is not selection. Chromium can expose an active navigation entry
    /// through AXARIACurrent instead of the native AXSelected attribute.
    static func isCurrent(selected: Bool?, ariaCurrent: String?) -> Bool {
        if selected == true { return true }
        guard let ariaCurrent else { return false }
        return ["true", "page"].contains(normalize(ariaCurrent))
    }

    /// The caller supplies only static-text descendants of the prospective row, never
    /// nested action labels. Multiple distinct texts are ambiguous rather than joined.
    static func candidateLabel(title: String, description: String, childTexts: [String] = []) -> String? {
        func clean(_ value: String) -> String? {
            let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !result.isEmpty, result.count <= 200, !result.contains(where: { $0.isNewline }) else { return nil }
            return result
        }
        if let title = clean(title) { return title }
        if let description = clean(description) { return description }
        let children = childTexts.compactMap(clean)
        let unique = Set(children.map(normalize))
        return unique.count == 1 ? children.first : nil
    }

    static func isCandidate(role: String, label: String, navigation: Bool, pressable: Bool,
                            requestedTitle: String? = nil) -> Bool {
        guard navigation, pressable, !label.isEmpty, label.count <= 200,
              !label.contains(where: { $0.isNewline }), !isActionLabel(label) else { return false }
        if ["AXRow", "AXLink"].contains(role) { return true }
        // Electron-style button/group rows require an exact user-supplied title. They
        // must not enter Jev's fuzzy candidate set, even inside a navigation landmark.
        guard ["AXButton", "AXGroup"].contains(role), let requestedTitle else { return false }
        return !normalize(requestedTitle).isEmpty && normalize(label) == normalize(requestedTitle)
    }

    private static func isActionLabel(_ label: String) -> Bool {
        let label = normalize(label)
        let fixed: Set<String> = ["new", "new chat", "new conversation", "new thread", "new task", "search",
            "search chats", "search conversations", "search threads", "settings", "preferences", "more",
            "more options", "new project", "更多", "新聊天", "新对话", "新会话", "新任务", "设置", "搜索", "新建项目"]
        if fixed.contains(label) { return true }
        let english = ["delete", "remove", "archive", "share", "rename", "move", "pin", "unpin", "close",
                       "clear", "export", "download", "copy link"]
        for action in english where label.hasPrefix(action) {
            if label.count == action.count { return true }
            let next = label[label.index(label.startIndex, offsetBy: action.count)]
            if next.isWhitespace || next.isPunctuation { return true }
        }
        return ["删除", "移除", "归档", "分享", "共享", "重命名", "移动", "置顶", "取消置顶", "关闭", "清空", "导出", "下载", "复制链接"]
            .contains(where: label.hasPrefix)
    }
}
