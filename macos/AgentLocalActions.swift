import AppKit
import Foundation

/// Exact local commands skip planner startup. This is deliberately a small grammar, not a
/// best-effort interpretation: an unmatched request remains entirely owned by the agent.
enum AgentLocalPlan: Equatable, Sendable {
    case activate(app: String)
    case openURL(URL, app: String?)
    case conversation(app: String, title: String)
}

enum AgentLocalParser {
    static func parse(_ command: String) -> AgentLocalPlan? {
        var text = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 500, !text.contains(where: { $0.isNewline }),
              !text.contains(";"), !text.contains("；"), !text.contains("|"),
              !text.contains("`"), !text.contains("$") else { return nil }
        // Optional politeness is allowed only at the beginning; never search inside a prompt.
        text = text.replacingOccurrences(of: #"^(?:please\s+|请(?:帮我)?\s*)"#, with: "", options: [.regularExpression, .caseInsensitive])
        if let parts = captures(#"^(?:open|focus|switch to)\s+(?:the\s+)?(?:conversation|chat|session)\s+[\"“]([^\"”]+)[\"”]\s+in\s+(.+?)[.!]?$"#, text) {
            guard validApp(parts[1]), validTitle(parts[0]) else { return nil }
            return .conversation(app: parts[1], title: parts[0])
        }
        if let parts = captures(#"^(?:open|activate|switch to)\s+(.+?)\s+and\s+(?:focus on|open|switch to)\s+(?:the\s+)?(.+?)\s+(?:session|conversation|chat)[.!]?$"#, text) {
            let title = unquote(parts[1])
            guard validApp(parts[0]), validCommandTitle(title) else { return nil }
            return .conversation(app: parts[0], title: title)
        }
        if let parts = captures(#"^(?:open|focus on|switch to)\s+(?:the\s+)?(.+?)\s+(?:conversation|session|chat)\s+in\s+(.+?)[.!]?$"#, text) {
            let title = unquote(parts[0])
            guard validApp(parts[1]), validCommandTitle(title) else { return nil }
            return .conversation(app: parts[1], title: title)
        }
        if let parts = captures(#"^(?:打开|切换到|聚焦)\s*(.+?)\s*(?:中的|里的)[“\"]([^”\"]+)[”\"](?:会话|聊天)?[。！]?$"#, text) {
            guard validApp(parts[0]), validTitle(parts[1]) else { return nil }
            return .conversation(app: parts[0], title: parts[1])
        }
        if let parts = captures(#"^(?:open|go to|visit)\s+(https?://\S+?)(?:\s+in\s+(.+?))?$"#, text) {
            guard let url = webURL(parts[0]), parts[1].isEmpty || validApp(parts[1]) else { return nil }
            return .openURL(url, app: parts[1].isEmpty ? nil : parts[1])
        }
        if let parts = captures(#"^(?:用|使用)\s*(.+?)\s*打开\s*(https?://\S+)$"#, text) {
            guard validApp(parts[0]), let url = webURL(parts[1]) else { return nil }
            return .openURL(url, app: parts[0])
        }
        if let parts = captures(#"^(?:打开|访问)\s*(https?://\S+)$"#, text), let url = webURL(parts[0]) {
            return .openURL(url, app: nil)
        }
        if let parts = captures(#"^(?:open|activate|launch|switch to|bring up)\s+(.+?)[.!]?$"#, text), validApp(parts[0]) {
            return .activate(app: parts[0])
        }
        if let parts = captures(#"^(?:打开|启动|切换到)\s*(.+?)[。！]?$"#, text), validApp(parts[0]) {
            return .activate(app: parts[0])
        }
        return nil
    }

    private static func captures(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]).trimmingCharacters(in: .whitespaces) } ?? ""
        }
    }

    private static func validApp(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 80,
              name.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\\"“”':?<>@(){}[]")) == nil,
              !name.contains("，"), !name.contains(","), !name.contains("。") else { return false }
        if name.range(of: #"^[A-Za-z][A-Za-z0-9-]*(?:\.[A-Za-z0-9-]+){2,}$"#, options: .regularExpression) != nil {
            return true
        }
        // App names resolve by exact installed identity too. This guard prevents a compound,
        // negated or sensitive request from becoming a partial launch before agent handoff.
        let blocked = #"(?i)\b(and|then|but|without|don't|do not|not|except|instead|password|passwords|delete|remove|send|buy|purchase|please|find|focus|session|chat|conversation)\b|然后|并且|再|不要|别|除了|密码|删除|发送|购买|查找|会话|聊天"#
        return name.range(of: blocked, options: .regularExpression) == nil
    }

    private static func validTitle(_ title: String) -> Bool {
        !title.isEmpty && title.count <= 200 && !title.contains(where: { $0.isNewline })
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        if (value.first == "\"" && value.last == "\"") || (value.first == "“" && value.last == "”") {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    private static func validCommandTitle(_ title: String) -> Bool {
        guard validTitle(title), title.rangeOfCharacter(from: CharacterSet(charactersIn: "\"“”,，")) == nil else { return false }
        return title.range(of: #"(?i)\b(and|then|but|without|not|delete|remove|send|buy|password)\b|然后|并且|不要|删除|发送|购买|密码"#, options: .regularExpression) == nil
    }

    private static func webURL(_ raw: String) -> URL? {
        guard let components = URLComponents(string: raw),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              let url = components.url else { return nil }
        return url
    }
}

struct AgentLocalApplication: Equatable, Sendable {
    let bundleID: String
    let name: String
    let url: URL
}

enum AgentLocalApplicationResolver {
    static let userAliasesKey = "agentApplicationAliases"

    enum Resolution: Equatable, Sendable {
        case match(AgentLocalApplication)
        case ambiguous([AgentLocalApplication])
        case missing
    }

    static func resolve(_ query: String, applications: [AgentLocalApplication],
                        userAliases: [String: String] = [:]) -> Resolution {
        let rawQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // An explicit bundle identifier is already an identity, not an app-name alias.
        // Check before stripping .app, which can also be the last identifier component.
        if rawQuery.range(of: #"^[A-Za-z][A-Za-z0-9-]*(?:\.[A-Za-z0-9-]+){2,}$"#,
                          options: .regularExpression) != nil
            || applications.contains(where: { $0.bundleID.lowercased() == rawQuery }) {
            return result(applications.filter { $0.bundleID.lowercased() == rawQuery })
        }
        let query = normalized(query)
        let configured = userAliases.filter { normalized($0.key) == query }
        // Configuration collisions remain ambiguous even when both values agree.
        guard configured.count <= 1 else { return .ambiguous([]) }
        if let target = configured.first?.value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            // A saved preference pins one identity. Never substitute another matching name.
            return result(applications.filter { $0.bundleID.lowercased() == target })
        }
        let aliases: [String: Set<String>] = [
            "chrome": ["com.google.chrome"], "google chrome": ["com.google.chrome"],
            "谷歌浏览器": ["com.google.chrome"], "safari": ["com.apple.safari"],
            "edge": ["com.microsoft.edgemac"], "firefox": ["org.mozilla.firefox"],
            "codex": ["com.openai.codex"], "chatgpt": ["com.openai.chat"],
            "claude": ["com.anthropic.claudefordesktop"],
            "1password": ["com.1password.1password", "com.agilebits.onepassword7"],
            "notes": ["com.apple.notes"], "备忘录": ["com.apple.notes"],
            "finder": ["com.apple.finder"], "访达": ["com.apple.finder"]
        ]
        return result(applications.filter { app in
            let id = app.bundleID.lowercased()
            return normalized(app.name) == query || id == query || aliases[query]?.contains(id) == true
        })
    }

    private static func result(_ applications: [AgentLocalApplication]) -> Resolution {
        var seen: Set<String> = []
        let matches = applications.filter { seen.insert($0.bundleID.lowercased()).inserted }
            .sorted { $0.bundleID < $1.bundleID }
        if matches.count == 1 { return .match(matches[0]) }
        return matches.isEmpty ? .missing : .ambiguous(matches)
    }

    private static func normalized(_ name: String) -> String {
        var value = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasSuffix(".app") { value.removeLast(4) }
        return value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

@MainActor
final class AgentLocalActions {
    enum Outcome: Equatable, Sendable {
        case completed(String)
        /// Nothing was dispatched. It is safe to give the entire command to another executor.
        case unhandled(String?)
        /// Includes uncertain outcomes after dispatch. Never automatically repeat via fallback.
        case failed(String)
    }

    private var cached: [AgentLocalApplication] = []
    private var cacheTime: Date = .distantPast
    private let workspace: NSWorkspace

    init(workspace: NSWorkspace = .shared) { self.workspace = workspace }

    func applications() async -> [AgentLocalApplication] {
        if Date().timeIntervalSince(cacheTime) > 60 {
            let installed = await Task.detached(priority: .userInitiated) { InstalledApp.scan() }.value
            cached = installed.map { AgentLocalApplication(bundleID: $0.bundleID, name: $0.name, url: $0.url) }
            cacheTime = Date()
        }
        let running = workspace.runningApplications.compactMap { app -> AgentLocalApplication? in
            guard let id = app.bundleIdentifier, let url = app.bundleURL else { return nil }
            return AgentLocalApplication(bundleID: id, name: app.localizedName ?? url.deletingPathExtension().lastPathComponent, url: url)
        }
        // Keep both names for matching; resolver deduplicates identities after matching.
        return running + cached
    }

    func resolveApplication(_ name: String) async -> AgentLocalApplicationResolver.Resolution {
        let aliases = UserDefaults.standard.dictionary(forKey: AgentLocalApplicationResolver.userAliasesKey) as? [String: String] ?? [:]
        let result = AgentLocalApplicationResolver.resolve(name, applications: await applications(), userAliases: aliases)
        switch result {
        case .match:
            rmDebug("🤖 Local app resolution: result=matched count=1")
        case .missing:
            rmDebug("🤖 Local app resolution: result=missing count=0")
        case .ambiguous(let matches):
            rmDebug("🤖 Local app resolution: result=ambiguous count=\(matches.count)")
        }
        return result
    }

    func execute(_ plan: AgentLocalPlan) async -> Outcome {
        guard !Task.isCancelled else { return .failed("Cancelled before opening anything.") }
        if case .conversation = plan { return .unhandled("Conversation navigation requires an app adapter.") }
        let requested: String?
        let url: URL?
        switch plan {
        case .activate(let app): requested = app; url = nil
        case .openURL(let value, let app): requested = app; url = value
        case .conversation: return .unhandled(nil)
        }
        let application: AgentLocalApplication
        if let requested {
            switch await resolveApplication(requested) {
            case .match(let found): application = found
            case .ambiguous: return .unhandled("The requested app is ambiguous; no app was opened.")
            case .missing: return .unhandled("No exact installed app matches ‘\(requested)’; no app was opened.")
            }
        } else if let url, let appURL = workspace.urlForApplication(toOpen: url),
                  let bundle = Bundle(url: appURL), let id = bundle.bundleIdentifier {
            application = AgentLocalApplication(bundleID: id, name: appURL.deletingPathExtension().lastPathComponent, url: appURL)
        } else { return .unhandled("No default browser is available; no URL was opened.") }
        guard !Task.isCancelled else { return .failed("Cancelled before opening anything.") }
        if url != nil, requested != nil {
            let browsers: Set<String> = ["com.apple.Safari", "com.google.Chrome", "com.microsoft.edgemac", "org.mozilla.firefox", "com.brave.Browser", "company.thebrowser.Browser", "com.operasoftware.Opera", "com.vivaldi.Vivaldi"]
            guard browsers.contains(application.bundleID) else {
                return .unhandled("The requested app is not a supported browser; no URL was opened.")
            }
        }
        // Once dispatched, cancellation/timeout is a failure rather than an invitation to
        // retry the same action in the general agent. NSWorkspace cannot undo a launch.
        let state = OpenState()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let completion: @Sendable (NSRunningApplication?, Error?) -> Void = { app, error in
            let bundleID = app?.bundleIdentifier
            let failure = error?.localizedDescription
            Task { @MainActor in
                state.bundleID = bundleID
                state.error = failure
                state.finished = true
            }
        }
        if let url {
            workspace.open([url], withApplicationAt: application.url, configuration: configuration, completionHandler: completion)
        } else {
            workspace.openApplication(at: application.url, configuration: configuration, completionHandler: completion)
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while ProcessInfo.processInfo.systemUptime < deadline {
            if Task.isCancelled { return .failed("Cancelled after opening was requested; the app may already be open.") }
            if let error = state.error { return .failed("Could not open \(application.name): \(error)") }
            if state.finished, workspace.frontmostApplication?.bundleIdentifier == application.bundleID {
                if url != nil { return .completed("Sent the URL to \(application.name).") }
                return .completed("Opened \(application.name).")
            }
            do { try await Task.sleep(nanoseconds: 40_000_000) }
            catch { return .failed("Cancelled after opening was requested; the app may already be open.") }
        }
        return .failed("Opening \(application.name) was requested, but focus could not be confirmed. It was not retried.")
    }

    @MainActor
    private final class OpenState {
        var finished = false
        var bundleID: String?
        var error: String?
    }
}
