import XCTest
@testable import VibeRemote

final class ComputerUseAgentTests: XCTestCase {
    func testClaudeStreamReportsCommandsMessagesAndResult() {
        let tool = #"{"type":"assistant","message":{"content":[{"type":"text","text":"Opening Notes."},{"type":"tool_use","name":"Bash","input":{"command":"agent-desktop snapshot --app Notes -i --compact"}}]}}"#
        XCTAssertEqual(AgentStreamParser.claude(line: tool),
                       [.message("Opening Notes."), .action("snapshot --app Notes -i --compact")])
        XCTAssertEqual(AgentStreamParser.claude(line: #"{"type":"result","subtype":"success","is_error":false,"result":"Created the note."}"#),
                       [.finished("Created the note.")])
        XCTAssertEqual(AgentStreamParser.claude(line: #"{"type":"result","subtype":"success","is_error":true,"result":"Not logged in"}"#),
                       [.failed("Not logged in")])
        XCTAssertEqual(AgentStreamParser.claude(line: #"{"type":"result","subtype":"error_max_turns","is_error":false}"#),
                       [.failed("Claude Code stopped with an error.")])
        XCTAssertEqual(AgentStreamParser.claude(line: #"{"type":"system","subtype":"init"}"#), [])
        XCTAssertEqual(AgentStreamParser.claude(line: "not json"), [])
    }

    func testCodexStreamReportsCommandsMessagesAndCompletion() {
        XCTAssertEqual(AgentStreamParser.codex(line: #"{"type":"item.started","item":{"id":"1","type":"command_execution","command":"bash -lc 'agent-desktop click @s1:e4'","status":"in_progress"}}"#),
                       [.action("click")])
        XCTAssertEqual(AgentStreamParser.codex(line: #"{"type":"item.completed","item":{"id":"2","type":"agent_message","text":"Done."}}"#),
                       [.message("Done.")])
        // Completed commands and reasoning are not repeated as progress.
        XCTAssertEqual(AgentStreamParser.codex(line: #"{"type":"item.completed","item":{"type":"command_execution","command":"agent-desktop status"}}"#), [])
        XCTAssertEqual(AgentStreamParser.codex(line: #"{"type":"item.completed","item":{"type":"reasoning","text":"thinking"}}"#), [])
        XCTAssertEqual(AgentStreamParser.codex(line: #"{"type":"turn.completed","usage":{}}"#), [.finished(nil)])
        XCTAssertEqual(AgentStreamParser.codex(line: #"{"type":"turn.failed","error":{"message":"quota"}}"#), [.failed("quota")])
        XCTAssertEqual(AgentStreamParser.codex(line: #"{"type":"error","message":"stream closed"}"#), [.failed("stream closed")])
    }

    func testCommandSummaryKeepsTheReadablePart() {
        XCTAssertEqual(AgentCommandSummary.describe("/Applications/VibeRemote.app/Contents/Helpers/AgentDesktop/agent-desktop launch Notes"),
                       "launch Notes")
        XCTAssertEqual(AgentCommandSummary.describe("agent-desktop type @s8f3k2p9:e12 \"Buy milk\""), "type \"Buy milk\"")
        XCTAssertEqual(AgentCommandSummary.describe("/bin/zsh -lc \"agent-desktop press cmd+n\""), "press cmd+n")
        XCTAssertEqual(AgentCommandSummary.describe("ls -la"), "$ ls -la")
        let long = AgentCommandSummary.describe("agent-desktop type @s1:e1 \"" + String(repeating: "a", count: 200) + "\"")
        XCTAssertEqual(long.count, AgentCommandSummary.maxLength)
        XCTAssertTrue(long.hasSuffix("…"))
    }

    func testTVTapKeepsShiftEnterAndHoldOpensTheAgent() {
        var gate = AgentButtonGate()
        // 2nd/3rd gen: TV is a plain Shift+Enter, deferred to release.
        XCTAssertTrue(gate.press(at: 10, defersTap: true))
        XCTAssertEqual(gate.release(at: 10.2, chorded: false), .tap)
        XCTAssertTrue(gate.press(at: 20, defersTap: true))
        XCTAssertEqual(gate.release(at: 20.6, chorded: false), .openAgent(passThrough: false))
        // 1st gen: TV is also a modifier; the press passes through and a chord wins.
        XCTAssertFalse(gate.press(at: 30, defersTap: false))
        XCTAssertEqual(gate.release(at: 30.1, chorded: false), .passThrough)
        XCTAssertFalse(gate.press(at: 40, defersTap: false))
        XCTAssertEqual(gate.release(at: 41, chorded: true), .passThrough)
        XCTAssertFalse(gate.press(at: 50, defersTap: false))
        XCTAssertEqual(gate.release(at: 51, chorded: false), .openAgent(passThrough: true))
        // A release without a seen press (e.g. the press went to the Advanced Menu).
        XCTAssertEqual(gate.release(at: 60, chorded: false), .passThrough)
        XCTAssertTrue(gate.press(at: 70, defersTap: true))
        gate.reset()
        XCTAssertEqual(gate.release(at: 71, chorded: false), .passThrough)
    }

    func testSettingsRoundTripAndModelFallback() {
        let name = "VibeRemote.ComputerUseAgentTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        XCTAssertEqual(AgentSettings.load(from: defaults), AgentSettings())
        let custom = AgentSettings(backend: .openRouter, openRouterModel: "google/gemini-3.5-flash",
                                   claudeModel: "haiku", codexModel: "gpt-6-luna")
        custom.save(to: defaults)
        XCTAssertEqual(AgentSettings.load(from: defaults), custom)
        defaults.set("  ", forKey: AgentSettings.modelKey)
        XCTAssertEqual(AgentSettings.load(from: defaults).openRouterModel, AgentSettings.defaultOpenRouterModel)
    }

    func testPlannerArgumentsLimitClaudeToAgentDesktopAndRunCodexUnsandboxed() {
        let context = AgentContext(appName: "Notes", bundleID: "com.apple.Notes")
        let claude = AgentRun.claudeArguments(command: "make a note", context: context)
        XCTAssertEqual(claude[claude.firstIndex(of: "--tools")! + 1], "Bash")
        XCTAssertEqual(claude[claude.firstIndex(of: "--allowedTools")! + 1], "Bash(agent-desktop:*)")
        XCTAssertEqual(claude[claude.firstIndex(of: "--output-format")! + 1], "stream-json")
        XCTAssertEqual(claude[claude.firstIndex(of: "--effort")! + 1], "low")
        XCTAssertFalse(claude.contains("--model"))
        let haiku = AgentRun.claudeArguments(command: "make a note", context: context, model: "haiku")
        XCTAssertEqual(haiku[haiku.firstIndex(of: "--model")! + 1], "haiku")
        XCTAssertTrue(claude[1].contains("Task: make a note"))
        XCTAssertTrue(claude[1].contains("Notes (com.apple.Notes)"))

        let directory = URL(fileURLWithPath: "/tmp/agent")
        let codex = AgentRun.codexArguments(command: "make a note", context: context, directory: directory)
        XCTAssertEqual(Array(codex.prefix(2)), ["exec", "--json"])
        XCTAssertEqual(codex[codex.firstIndex(of: "-s")! + 1], "danger-full-access")
        XCTAssertEqual(codex[codex.firstIndex(of: "-C")! + 1], "/tmp/agent")
        XCTAssertTrue(codex.contains("model_reasoning_effort=\"low\""))
        XCTAssertFalse(codex.contains("-m"))
        let luna = AgentRun.codexArguments(command: "make a note", context: context, directory: directory, model: "gpt-6-luna")
        XCTAssertEqual(luna[luna.firstIndex(of: "-m")! + 1], "gpt-6-luna")
        XCTAssertTrue(luna.last!.hasSuffix("Task: make a note"))
        XCTAssertTrue(codex.last!.hasPrefix(AgentPrompt.instructions()))
        XCTAssertTrue(codex.last!.hasSuffix("Task: make a note"))
    }

    func testBriefingPutsGuidesInTheRulesAndTheSnapshotBeforeTheTask() {
        let context = AgentContext(appName: "Notes", bundleID: "com.apple.Notes")
        XCTAssertTrue(AgentPrompt.instructions().contains("skills get desktop"))
        let briefing = AgentBriefing(guides: ["GUIDE-A", "GUIDE-B"], snapshot: #"{"ok":true}"#)
        let rules = AgentPrompt.instructions(briefing)
        XCTAssertFalse(rules.contains("Before your first action run"))
        XCTAssertTrue(rules.hasSuffix("GUIDE-A\n\nGUIDE-B"))
        XCTAssertTrue(AgentPrompt.instructions(briefing, tool: true).contains("agent_desktop tool"))

        let claude = AgentRun.claudeArguments(command: "make a note", context: context, briefing: briefing)
        XCTAssertTrue(claude[1].contains("Snapshot of Notes taken just now"))
        XCTAssertTrue(claude[1].hasSuffix("Task: make a note"))
        XCTAssertEqual(claude[claude.firstIndex(of: "--append-system-prompt")! + 1], rules)
        // Without an app there is nothing to snapshot.
        XCTAssertFalse(AgentPrompt.task("x", context: AgentContext(), snapshot: "{}").contains("Snapshot"))
    }

    func testCodexModelsComeFromItsCacheInPriorityOrder() {
        let cache = Data(#"{"models":[{"slug":"b","display_name":"B","visibility":"list","priority":2},{"slug":"hidden","visibility":"hide","priority":0},{"slug":"a","display_name":"A","visibility":"list","priority":1}]}"#.utf8)
        XCTAssertEqual(AgentModelCatalog.codex(cache: cache).map(\.id), ["", "a", "b"])
        XCTAssertEqual(AgentModelCatalog.codex(cache: nil).map(\.id), [""])
        XCTAssertEqual(AgentModelCatalog.codex(cache: Data("junk".utf8)).map(\.id), [""])
        let kept = AgentModelCatalog.choices(AgentModelCatalog.claudeCode, keeping: "claude-fable-5")
        XCTAssertEqual(kept.last, AgentModelChoice(id: "claude-fable-5", title: "claude-fable-5"))
        XCTAssertEqual(AgentModelCatalog.choices(AgentModelCatalog.claudeCode, keeping: "opus"), AgentModelCatalog.claudeCode)
        XCTAssertEqual(AgentSettings(backend: .codex, codexModel: "a").model, "a")
    }

    func testOpenRouterToolTakesAnArgumentArray() throws {
        let function = try XCTUnwrap(AgentRun.toolDefinition()["function"] as? [String: Any])
        XCTAssertEqual(function["name"] as? String, "agent_desktop")
        let parameters = try XCTUnwrap(function["parameters"] as? [String: Any])
        XCTAssertEqual(parameters["required"] as? [String], ["args"])
        XCTAssertTrue(JSONSerialization.isValidJSONObject(AgentRun.toolDefinition()))
    }

    func testPathDiscoveryPrefersTheLoginShellAndSkipsBanners() {
        XCTAssertEqual(AgentToolLocator.loginPath(fromShellOutput: "Welcome!\n__VIBEREMOTE_PATH__/a:/b"), "/a:/b")
        XCTAssertNil(AgentToolLocator.loginPath(fromShellOutput: "no marker"))
        let folders = AgentToolLocator.searchPath(loginPath: "/custom/bin:/usr/local/bin", home: "/Users/test")
        XCTAssertEqual(Array(folders.prefix(3)), ["/custom/bin", "/usr/local/bin", "/Users/test/.local/bin"])
        XCTAssertEqual(folders.filter { $0 == "/usr/local/bin" }.count, 1)
    }

    func testVendoredAgentDesktopIsFound() throws {
        let directory = try XCTUnwrap(AgentToolLocator.agentDesktopDirectory(bundle: Bundle(for: Self.self)))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: directory.appendingPathComponent("agent-desktop-macos-helper").path))
    }

    @MainActor
    func testAgentPhasesFollowRunEvents() {
        let agent = ComputerUseAgent(settings: AgentSettings(), hasOpenRouterKey: false)
        agent.prepare(context: AgentContext(appName: "Notes", bundleID: "com.apple.Notes"))
        XCTAssertFalse(agent.canSubmit)
        agent.command = "  "
        XCTAssertFalse(agent.canSubmit)
        agent.command = "make a note"
        XCTAssertTrue(agent.canSubmit)

        for index in 0..<(ComputerUseAgent.stepLimit + 5) { agent.handle(.action("step \(index)")) }
        XCTAssertEqual(agent.steps.count, ComputerUseAgent.stepLimit)
        XCTAssertEqual(agent.steps.last, "step \(ComputerUseAgent.stepLimit + 4)")
        agent.handle(.message("Typing"))
        XCTAssertEqual(agent.latestMessage, "Typing")
        agent.handle(.finished(nil))
        XCTAssertEqual(agent.phase, .finished("Done."))

        // Opening the panel again starts a fresh command.
        agent.prepare(context: AgentContext(appName: "Safari", bundleID: nil))
        XCTAssertEqual(agent.phase, .composing)
        XCTAssertEqual(agent.command, "")
        XCTAssertTrue(agent.steps.isEmpty)
        XCTAssertEqual(agent.context.appName, "Safari")
    }
}
