import Foundation
import XCTest
@testable import VibeRemote

final class AgentLocalActionsTests: XCTestCase {
    func testExactApplicationCommandsInEnglishAndChinese() {
        for text in ["Open ChatGPT", "activate ChatGPT", "switch to ChatGPT", "please open ChatGPT."] {
            XCTAssertEqual(AgentLocalParser.parse(text), .activate(app: "ChatGPT"), text)
        }
        XCTAssertEqual(AgentLocalParser.parse("请帮我打开备忘录"), .activate(app: "备忘录"))
        XCTAssertEqual(AgentLocalParser.parse("启动 1Password"), .activate(app: "1Password"))
        XCTAssertEqual(AgentLocalParser.parse("open com.apple.Notes"), .activate(app: "com.apple.Notes"))
        XCTAssertEqual(AgentLocalParser.parse("open com.openai.chat"), .activate(app: "com.openai.chat"))
    }

    func testExplicitWebURLsAndNamedBrowsers() {
        let url = URL(string: "https://example.com/path?q=one&lang=en")!
        XCTAssertEqual(AgentLocalParser.parse("open \(url.absoluteString) in Chrome"), .openURL(url, app: "Chrome"))
        XCTAssertEqual(AgentLocalParser.parse("用 Safari 打开 \(url.absoluteString)"), .openURL(url, app: "Safari"))
        XCTAssertEqual(AgentLocalParser.parse("访问\(url.absoluteString)"), .openURL(url, app: nil))
        XCTAssertEqual(AgentLocalParser.parse("visit \(url.absoluteString)"), .openURL(url, app: nil))
        for text in ["open file:///tmp/test", "open javascript:alert(1)", "open https://name:secret@example.com", "open https://", "open https://example.com and send a message"] {
            XCTAssertNil(AgentLocalParser.parse(text), text)
        }
    }

    func testQuotedConversationTargetIsPreservedForAdapter() {
        XCTAssertEqual(AgentLocalParser.parse("open conversation \"vvhisper planning\" in ChatGPT"),
                       .conversation(app: "ChatGPT", title: "vvhisper planning"))
        XCTAssertEqual(AgentLocalParser.parse("打开 ChatGPT 中的“产品规划”会话"),
                       .conversation(app: "ChatGPT", title: "产品规划"))
        XCTAssertEqual(AgentLocalParser.parse("Open ChatGPT and focus on the vvhisper session"),
                       .conversation(app: "ChatGPT", title: "vvhisper"))
        XCTAssertEqual(AgentLocalParser.parse("open the Product planning conversation in ChatGPT"),
                       .conversation(app: "ChatGPT", title: "Product planning"))
        XCTAssertNil(AgentLocalParser.parse("Open ChatGPT and focus on work and delete another session"))
        XCTAssertNil(AgentLocalParser.parse("open conversation \"work\" in ChatGPT and delete it"))
    }

    func testCompoundNegatedSensitiveAndPromptPhrasesNeverPartiallyExecute() {
        for text in [
            "Don't open Notes", "open Notes and send this", "open Notes then delete everything",
            "open Notes without saving", "open ChatGPT and focus my project", "open Notes; open Mail",
            "open Notes\nthen send mail", "open Notes, please", "Tell me how to open Notes",
            "Can you explain open Notes", "find a password in 1Password", "open 1Password and copy my password",
            "不要打开备忘录", "打开备忘录然后发送消息", "打开ChatGPT并且删除会话", "打开密码",
            "open Notes | cat", "open $(whoami)", "open `Notes`", "open Notes instead of Mail"
        ] { XCTAssertNil(AgentLocalParser.parse(text), text) }
    }

    func testResolverRequiresExactNameOrExplicitAlias() {
        let chrome = app("com.google.Chrome", "Google Chrome")
        let notes = app("com.apple.Notes", "Notes")
        XCTAssertEqual(AgentLocalApplicationResolver.resolve("Chrome", applications: [chrome, notes]), .match(chrome))
        XCTAssertEqual(AgentLocalApplicationResolver.resolve(" NOTES.app ", applications: [notes]), .match(notes))
        XCTAssertEqual(AgentLocalApplicationResolver.resolve("com.apple.Notes", applications: [notes]), .match(notes))
        XCTAssertEqual(AgentLocalApplicationResolver.resolve("Note", applications: [notes]), .missing)
    }

    func testChatGPTDoesNotSilentlyChooseBetweenNativeAppAndLocallyRenamedCodex() {
        let native = app("com.openai.chat", "ChatGPT")
        let codex = app("com.openai.codex", "ChatGPT")
        XCTAssertEqual(AgentLocalApplicationResolver.resolve("ChatGPT", applications: [codex]), .match(codex))
        XCTAssertEqual(AgentLocalApplicationResolver.resolve("ChatGPT", applications: [native, codex]), .ambiguous([native, codex]))
        XCTAssertEqual(AgentLocalApplicationResolver.resolve("Codex", applications: [native, codex]), .match(codex))
        XCTAssertEqual(AgentLocalApplicationResolver.resolve("ChatGPT", applications: [app("com.openai.codex", "Codex")]), .missing)
    }

    func testRunningAndInstalledEntriesDeduplicateOnlyAfterNameMatching() {
        let running = app("com.openai.codex", "Codex")
        let installed = app("com.openai.codex", "ChatGPT")
        XCTAssertEqual(AgentLocalApplicationResolver.resolve("ChatGPT", applications: [running, installed]), .match(installed))
        XCTAssertEqual(AgentLocalApplicationResolver.resolve("Codex", applications: [running, installed]), .match(running))
    }

    func testUserAppAliasPinsIdentityAcrossDisplayNameChanges() {
        let aliases = ["  Studio   Pad.app  ": "org.example.studio"]
        let renamed = app("org.example.studio", "New Studio")
        let unrelated = app("org.example.other", "Studio Pad")
        XCTAssertEqual(AgentLocalApplicationResolver.resolve("studio\tpad", applications: [unrelated, renamed], userAliases: aliases),
                       .match(renamed))
        XCTAssertEqual(AgentLocalApplicationResolver.resolve("Studio Pad", applications: [unrelated, renamed]), .match(unrelated))
        XCTAssertEqual(AgentLocalApplicationResolver.resolve("Studio", applications: [renamed], userAliases: aliases), .missing)
    }

    func testExplicitUserChoiceDisambiguatesNativeAndRenamedChatGPT() {
        let native = app("com.openai.chat", "ChatGPT")
        let renamed = app("com.openai.codex", "ChatGPT")
        let aliases = ["ChatGPT": "com.openai.codex"]
        XCTAssertEqual(AgentLocalApplicationResolver.resolve("ChatGPT", applications: [native, renamed], userAliases: aliases),
                       .match(renamed))
        let running = app("com.openai.codex", "Codex")
        XCTAssertEqual(AgentLocalApplicationResolver.resolve("ChatGPT", applications: [native, running, renamed], userAliases: aliases),
                       .match(running))
    }

    func testMissingUserAliasTargetNeverFallsBackToMatchingNameOrBuiltInAlias() {
        let native = app("com.openai.chat", "ChatGPT")
        XCTAssertEqual(AgentLocalApplicationResolver.resolve("ChatGPT", applications: [native],
                                                            userAliases: ["ChatGPT": "org.example.missing"]), .missing)
        XCTAssertEqual(AgentLocalApplicationResolver.resolve("ChatGPT", applications: [native],
                                                            userAliases: ["ChatGPT": ""]), .missing)
    }

    func testRawBundleIdentifiersBypassUserAliasesAndDisplayNames() {
        let target = app("org.example.app", "Studio")
        let other = app("org.example.other", "org.example.app")
        let aliases = ["org.example.app": "org.example.other", "org.example.missing": "org.example.other"]
        XCTAssertEqual(AgentLocalApplicationResolver.resolve("ORG.EXAMPLE.APP", applications: [other, target], userAliases: aliases),
                       .match(target))
        XCTAssertEqual(AgentLocalApplicationResolver.resolve("org.example.app", applications: [other], userAliases: aliases), .missing)
        XCTAssertEqual(AgentLocalApplicationResolver.resolve("org.example.missing", applications: [other], userAliases: aliases), .missing)
    }

    func testNormalizedUserAliasCollisionsNeverChooseAValue() {
        let first = app("org.example.first", "Studio")
        let second = app("org.example.second", "Other")
        let conflicting = ["Studio": first.bundleID, " STUDIO.app ": second.bundleID]
        XCTAssertEqual(AgentLocalApplicationResolver.resolve("studio", applications: [first, second], userAliases: conflicting),
                       .ambiguous([]))
        let duplicate = ["Studio": first.bundleID, " STUDIO.app ": first.bundleID]
        XCTAssertEqual(AgentLocalApplicationResolver.resolve("studio", applications: [first], userAliases: duplicate), .ambiguous([]))
        XCTAssertEqual(AgentLocalApplicationResolver.resolve("Other", applications: [second], userAliases: conflicting), .match(second))
        XCTAssertEqual(AgentLocalApplicationResolver.resolve(first.bundleID, applications: [first], userAliases: conflicting), .match(first))
    }

    private func app(_ id: String, _ name: String) -> AgentLocalApplication {
        AgentLocalApplication(bundleID: id, name: name, url: URL(fileURLWithPath: "/Applications/\(name).app"))
    }
}
