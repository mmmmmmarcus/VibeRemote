import Foundation

/// User-confirmed shorthand maps to one literal title in one app. These preferences
/// contain no executable actions and never weaken sidebar or selection verification.
enum AgentConversationAliases {
    static let defaultsKey = "agentConversationAliases"

    enum Resolution: Equatable {
        case unchanged
        case title(String)
        case scopedTitle(String, section: String)
        case ambiguous
    }

    static func resolve(_ requestedTitle: String, bundleID: String,
                        defaults: UserDefaults = .standard) -> Resolution {
        guard let apps = defaults.dictionary(forKey: defaultsKey),
              let aliases = apps[bundleID] as? [String: Any],
              valid(requestedTitle) else { return .unchanged }
        let requested = AgentConversationSelection.normalize(requestedTitle)
        let matches = aliases.filter { valid($0.key) && AgentConversationSelection.normalize($0.key) == requested }
        guard !matches.isEmpty else { return .unchanged }
        // Even two equivalent keys with the same target are ambiguous configuration.
        guard matches.count == 1 else { return .ambiguous }
        if let title = matches.first?.value as? String, valid(title) {
            return .title(title.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard let target = matches.first?.value as? [String: String],
              let title = target["title"], valid(title),
              let section = target["section"], valid(section) else { return .unchanged }
        return .scopedTitle(title.trimmingCharacters(in: .whitespacesAndNewlines),
                            section: section.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func valid(_ title: String) -> Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && title.count <= 200 && !title.contains(where: { $0.isNewline })
    }
}
