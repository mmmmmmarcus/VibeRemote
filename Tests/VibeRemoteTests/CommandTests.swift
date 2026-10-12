import XCTest
@testable import VibeRemote

final class CommandTests: XCTestCase {
    func testAutomaticForegroundStillHonorsCancellationAndOwnerDeath() throws {
        for (cancelled, alive, expected) in [(false, true, true), (true, true, false), (false, false, false)] {
            var delivered = false
            _ = try CommandMCPGate.process(call("bring_to_front", ["pid": 42, "window_id": 7]), approve: { _ in
                CommandMCPProxy.foregroundAllowed(cancelled: cancelled, ownerAlive: alive)
            }, forward: { _ in delivered = true; return ["id": 1, "result": [:]] })
            XCTAssertEqual(delivered, expected)
        }
    }

    func testPreviewUsesWindowRelativeCursorAndRejectsUnverifiedFrame() {
        var state: [String: Any] = ["screenshot_frame_valid": true, "app_name": "Test",
            "window_bounds": ["x": -200, "y": 100, "width": 400, "height": 200]]
        func reply() -> [String: Any] { ["result": ["structuredContent": state,
            "content": [["type": "image", "data": Data([1, 2]).base64EncodedString()]]]] }
        let frame = CommandPreviewFrame.make(response: reply(), cursor: ["position": ["x": 0, "y": 150]])
        XCTAssertEqual(frame?.cursorX, 0.5)
        XCTAssertEqual(frame?.cursorY, 0.25)
        XCTAssertNil(CommandPreviewFrame.make(response: reply(), cursor: ["position": ["x": 999, "y": 0]])?.cursorX)
        state["screenshot_frame_valid"] = false
        XCTAssertNil(CommandPreviewFrame.make(response: reply(), cursor: nil))
    }

    func testCursorPresentationOnlyBindsSupportedSessionAndPreservesInputPolicy() {
        var cursor = CommandCursorPresentation()
        cursor.observeTools(["result": ["tools": [
            ["name": "click", "inputSchema": ["properties": ["session": [:]]]],
            ["name": "list_windows", "inputSchema": ["properties": [:]]]]]])
        cursor.started = true
        let request = call("click", ["pid": 42, "window_id": 7, "delivery_mode": "background", "element_token": "fresh", "session": "other"])
        let bound = cursor.bind(request)
        let args = (bound["params"] as! [String: Any])["arguments"] as! [String: Any]
        XCTAssertEqual(args["session"] as? String, cursor.session)
        XCTAssertEqual(args["delivery_mode"] as? String, "background")
        XCTAssertEqual(args["element_token"] as? String, "fresh")
        let untouched = cursor.bind(call("list_windows", ["pid": 42]))
        XCTAssertNil(((untouched["params"] as? [String: Any])?["arguments"] as? [String: Any])?["session"])
        XCTAssertEqual(cursor.setup.map(\.0), ["start_session", "set_agent_cursor_enabled", "set_agent_cursor_motion"])
        XCTAssertFalse(cursor.setup.contains { RemoteCommandConfiguration.tools.contains($0.0) })
        XCTAssertNotEqual(cursor.session, CommandCursorPresentation().session)
    }

    func testBatchExcludesHiddenMenuDuplicatesButKeepsVisibleMenuItems() {
        let visible: [String: Any] = ["frame": ["w": 48, "h": 48], "role": "AXButton", "label": "1", "element_index": 1, "element_token": "button"]
        let hidden: [String: Any] = ["role": "AXMenuItem", "label": "1", "element_index": 2, "element_token": "hidden-menu"]
        var menu = hidden; menu["frame"] = ["w": 120, "h": 24]
        var zero = visible; zero["frame"] = ["w": 0, "h": 48]
        var off = visible; off["visible"] = false
        XCTAssertEqual(Set(CommandJevBatch.candidates([visible, hidden], allowed: ["1"]).keys), ["click_1"])
        XCTAssertEqual(Set(CommandJevBatch.candidates([visible, menu], allowed: ["1"]).keys), ["click_1", "click_2"])
        XCTAssertTrue(CommandJevBatch.candidates([zero, off], allowed: ["1"]).isEmpty)
    }

    func testOrderedBatchExecutesEveryStepThenMakesOneDecision() throws {
        let plan = try CommandJevBatch.Plan(["pid": 42, "window_id": 7, "goal": "Reset then press 1 twice", "completion": "11", "allowed_labels": ["Clear", "1"], "max_steps": 3, "ordered_labels": ["Clear", "1", "1"]])
        var clicks: [String] = [], reads = 0, decisions = 0
        let output = CommandJevBatch.execute(plan, choose: { state, _, _ in
            decisions += 1
            XCTAssertEqual(clicks.count, 3) // A matching initial result must not skip setup.
            XCTAssertEqual(state["observed_ui"] as? String, "final 4")
            return "done"
        }, call: { name, args in
            if name == "get_window_state" {
                reads += 1
                return ["tree_markdown": "final \(reads)", "elements": [
                    ["frame": ["w": 48, "h": 48], "role": "AXButton", "label": "Clear", "element_index": 1, "element_token": "clear-\(reads)"],
                    ["frame": ["w": 48, "h": 48], "role": "AXButton", "label": "1", "element_index": 2, "element_token": "one-\(reads)"]]]
            }
            XCTAssertEqual(args["delivery_mode"] as? String, "background")
            clicks.append(args["element_token"] as! String)
            return ["effect": "confirmed"]
        })
        XCTAssertEqual(clicks, ["clear-1", "one-2", "one-3"])
        XCTAssertEqual(decisions, 1)
        XCTAssertEqual(reads, 4)
        XCTAssertEqual(output["next_step"] as? Int, 3)
        XCTAssertEqual(output["remaining_labels"] as? [String], [])
        XCTAssertEqual(output["observed_tree"] as? String, "final 4")
        XCTAssertNotNil(output["observed_at_unix"])
    }

    func testOrderedBatchPreservesUncertainAttemptWithoutReplaying() throws {
        let plan = try CommandJevBatch.Plan(["pid": 42, "window_id": 7, "goal": "Two clicks", "completion": "Next", "allowed_labels": ["Next"], "max_steps": 2, "ordered_labels": ["Next", "Next"]])
        var clicks = 0
        let output = CommandJevBatch.execute(plan, choose: { _, _, _ in XCTFail(); return "stop" }, call: { name, _ in
            if name == "get_window_state" { return ["tree_markdown": "Before", "elements": [["frame": ["w": 48, "h": 48], "role": "AXButton", "label": "Next", "element_index": 1, "element_token": "fresh"]]] }
            clicks += 1
            throw CommandJevWorker.Failure("Transport interrupted after dispatch")
        })
        XCTAssertEqual(clicks, 1)
        XCTAssertEqual(output["clicked_labels"] as? [String], ["Next"])
        XCTAssertEqual(output["uncertain_label"] as? String, "Next")
        XCTAssertEqual(output["next_step"] as? Int, 0)
        XCTAssertEqual(output["observed_tree"] as? String, "")
        XCTAssertNil(output["observed_at_unix"])
    }

    func testOrderedPlanRejectsUnapprovedOrOverBudgetSteps() {
        var args: [String: Any] = ["pid": 42, "window_id": 7, "goal": "Next", "completion": "Next", "allowed_labels": ["Next"], "max_steps": 2, "ordered_labels": ["Send"]]
        XCTAssertThrowsError(try CommandJevBatch.Plan(args))
        args["ordered_labels"] = ["Next", "Next", "Next"]
        XCTAssertThrowsError(try CommandJevBatch.Plan(args))
        args["ordered_labels"] = [] as [String]
        XCTAssertThrowsError(try CommandJevBatch.Plan(args))
    }

    func testHybridSelectionAndToolIsolation() {
        XCTAssertEqual(CommandBackend.available, [.codex, .claude, .hybrid])
        let normal = RemoteCommandConfiguration.arguments(driver: URL(fileURLWithPath: "/driver"), directory: URL(fileURLWithPath: "/task"), target: "Calculator", proxy: URL(fileURLWithPath: "/app"))
        let hybrid = RemoteCommandConfiguration.arguments(driver: URL(fileURLWithPath: "/driver"), directory: URL(fileURLWithPath: "/task"), target: "Calculator", proxy: URL(fileURLWithPath: "/app"), hybrid: true)
        XCTAssertFalse(normal.contains { $0.contains(CommandJevBatch.toolName) })
        XCTAssertTrue(hybrid.contains { $0.contains(CommandJevBatch.toolName) })
        XCTAssertFalse(RemoteCommandConfiguration.tools.contains(CommandJevBatch.toolName))
    }

    func testJevGateRejectsDisabledAndHostTargets() throws {
        let args: [String: Any] = ["pid": 42, "window_id": 7]
        for enabled in [false, true] {
            let response = try CommandMCPGate.process(call(CommandJevBatch.toolName, args), protectedPIDs: enabled ? [42] : [], approve: { _ in XCTFail(); return false }, jev: enabled ? { _ in XCTFail(); return [:] } : nil, forward: { _ in XCTFail(); return nil })
            XCTAssertEqual((response?["result"] as? [String: Any])?["isError"] as? Bool, true)
        }
    }

    func testJevBatchUsesFreshTokensAndAlwaysHandsBackForVerification() throws {
        let plan = try CommandJevBatch.Plan(["pid": 42, "window_id": 7, "goal": "Click twice", "completion": "Two clicks", "allowed_labels": ["Next"], "max_steps": 3])
        var snapshots = 0, decisions = 0
        var tokens: [String] = []
        let result = CommandJevBatch.execute(plan, choose: { _, choices, _ in
            XCTAssertNil(choices["click_9"])
            decisions += 1
            return decisions <= 2 ? "click_1" : "done"
        }, call: { name, args in
            XCTAssertEqual(args["pid"] as? Int, 42)
            XCTAssertEqual(args["window_id"] as? Int, 7)
            if name == "get_window_state" {
                snapshots += 1
                return ["tree_markdown": "State \(snapshots)", "elements": [
                    ["frame": ["w": 48, "h": 48], "role": "AXButton", "label": "Next", "element_index": 1, "element_token": "token-\(snapshots)"],
                    ["frame": ["w": 48, "h": 48], "role": "AXButton", "label": "Send", "element_index": 9, "element_token": "not-allowed"]]]
            }
            XCTAssertEqual(name, "click")
            XCTAssertEqual(args["delivery_mode"] as? String, "background")
            tokens.append(args["element_token"] as! String)
            return ["effect": "confirmed"]
        })
        XCTAssertEqual(tokens, ["token-1", "token-2"])
        XCTAssertEqual(result["status"] as? String, "handoff")
        XCTAssertEqual(result["observed_tree"] as? String, "State 3")
        XCTAssertEqual(result["requires_independent_verification"] as? Bool, true)
    }

    func testJevReceivesControlValuesAndCannotToggleTwice() throws {
        let plan = try CommandJevBatch.Plan(["pid": 42, "window_id": 7, "goal": "Enable bold", "completion": "bold is 1", "allowed_labels": ["bold"], "max_steps": 3])
        var clicks = 0
        let result = CommandJevBatch.execute(plan, choose: { state, _, _ in
            let controls = state["observed_controls"] as! [String: [String: Any]]
            XCTAssertEqual(controls["click_1"]?["value"] as? String, clicks == 0 ? "0" : "1")
            return "click_1" // Deliberately wrong on the second decision.
        }, call: { name, _ in
            if name == "get_window_state" { return ["tree_markdown": "bold", "elements": [["frame": ["w": 48, "h": 48], "role": "AXCheckBox", "label": "bold", "value": clicks == 0 ? "0" : "1", "element_index": 1, "element_token": "fresh"]]] }
            clicks += 1; return ["effect": "confirmed"]
        })
        XCTAssertEqual(clicks, 1)
        XCTAssertEqual(result["status"] as? String, "handoff")
        XCTAssertTrue((result["reason"] as? String ?? "").contains("Repeated toggle prevented"))
    }

    func testJevBatchStopsAfterUncertainDeliveryAndRejectsUnboundedPlans() throws {
        var args: [String: Any] = ["pid": 42, "window_id": 7, "goal": "Next", "completion": "Next page", "allowed_labels": ["Next"], "max_steps": 1]
        let plan = try CommandJevBatch.Plan(args)
        var clicks = 0
        let result = CommandJevBatch.execute(plan, choose: { _, _, _ in "click_1" }, call: { name, _ in
            if name == "get_window_state" { return ["tree_markdown": "Before", "elements": [["frame": ["w": 48, "h": 48], "role": "AXButton", "label": "Next", "element_index": 1, "element_token": "fresh"]]] }
            clicks += 1; return ["effect": "suspected_noop"]
        })
        XCTAssertEqual(clicks, 1)
        XCTAssertEqual(result["observed_tree"] as? String, "")
        XCTAssertEqual(result["clicked_labels"] as? [String], ["Next"])
        args["max_steps"] = 25
        XCTAssertThrowsError(try CommandJevBatch.Plan(args))
        args["max_steps"] = 1; args["delivery_mode"] = "foreground"
        XCTAssertThrowsError(try CommandJevBatch.Plan(args))
    }

    func testJevOnlyExposesObservedEnabledCalculatorKeypadButtons() {
        let candidates = CommandJevWorker.candidates([
            ["role": "AXButton", "label": "1", "element_index": 2, "element_token": "s00000001:2"],
            ["role": "AXButton", "label": "All Clear", "element_index": 3, "element_token": "s00000001:3"],
            ["role": "AXButton", "label": "Delete", "enabled": false, "element_index": 4, "element_token": "s00000001:4"],
            ["role": "AXButton", "label": "Continue", "element_index": 5, "element_token": "s00000001:5"],
            ["role": "AXButton", "label": "2", "element_index": 6],
            ["role": "AXTextField", "label": "3", "element_index": 7, "element_token": "s00000001:7"]
        ])
        XCTAssertEqual(Set(candidates.keys), ["button_2", "button_3"])
        XCTAssertEqual(CommandJevWorker.displayValue("- AXStaticText = \"128 + 7\" (Last Expression)\n- AXStaticText = \"135\" (Edit field)"), "135")
        XCTAssertNil(CommandJevWorker.displayValue("- AXStaticText = \"135\" (Last Expression)"))
    }

    func testClaudeUsesIsolatedMCPWithoutPermissionBypass() {
        let args = RemoteCommandConfiguration.claudeArguments(driver: URL(fileURLWithPath: "/driver"), directory: URL(fileURLWithPath: "/task"), target: "Calculator", proxy: URL(fileURLWithPath: "/app"))
        XCTAssertTrue(args.contains("--restricted"))
        XCTAssertTrue(args.contains("--strict-mcp-config"))
        XCTAssertTrue(args.contains("--no-session-persistence"))
        XCTAssertTrue(args.contains("--permission-prompts"))
        XCTAssertTrue(args.contains("auto"))
        XCTAssertFalse(args.contains("bypassPermissions"))
        XCTAssertFalse(args.contains("--allowedTools"))
        let index = args.firstIndex(of: "--mcp-config")!
        let config = try! JSONSerialization.jsonObject(with: Data(args[index + 1].utf8)) as! [String: Any]
        let servers = config["mcpServers"] as! [String: [String: Any]]
        XCTAssertEqual(Set(servers.keys), ["cua"])
        XCTAssertEqual(servers["cua"]?["command"] as? String, "/app")
    }

    func testClaudePermissionDenialCannotLookLikeSuccess() {
        var events = RemoteCommandEvents(backend: .claude)
        _ = events.receive(Data("{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"Done\",\"permission_denials\":[{}]}\n".utf8))
        XCTAssertFalse(events.completed)
        XCTAssertNotNil(events.failure)
        var successful = RemoteCommandEvents(backend: .claude)
        _ = successful.receive(Data("{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"42\",\"permission_denials\":[]}\n".utf8))
        XCTAssertTrue(successful.completed)
        XCTAssertEqual(successful.finalMessage, "42")
    }

    func testTimingSeparatesStartupFromFirstToolWithoutStoringContent() {
        var timing = CommandEventTiming(startedAt: 100)
        timing.observe(["type": "thread.started"], now: 100.4)
        timing.observe(["type": "item.started", "item": ["type": "mcp_tool_call", "arguments": "private prompt"]], now: 112)
        timing.observe(["type": "item.completed", "item": ["type": "mcp_tool_call"]], now: 112.3)
        XCTAssertEqual(timing.firstEventSeconds!, 0.4, accuracy: 0.0001)
        XCTAssertEqual(timing.firstToolSeconds, 12)
        XCTAssertEqual(timing.toolCalls, 1)
        XCTAssertFalse(timing.summary(now: 115).contains("private prompt"))
    }

    func testDriverTimingKeepsHumanWaitSeparateAndRoundTrips() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let timing = CommandMCPMeasurements(connectionSeconds: 0.05, toolSeconds: 0.3, consentSeconds: 30, toolCalls: 2)
        timing.save(to: directory)
        let loaded = try XCTUnwrap(CommandMCPMeasurements.read(from: directory))
        XCTAssertEqual(loaded.toolSeconds, 0.3)
        XCTAssertEqual(loaded.consentSeconds, 30)
        XCTAssertEqual(loaded.toolCalls, 2)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(loaded)) as? [String: Any])
        XCTAssertEqual(Set(encoded.keys), ["connectionSeconds", "toolSeconds", "consentSeconds", "toolCalls", "jevDecisionSeconds", "jevDecisions", "jevBatches", "jevActions"])
    }

    func testCommandsStayOutOfArgumentsAndOnlyCuaIsExposed() {
        let args = RemoteCommandConfiguration.arguments(driver: URL(fileURLWithPath: "/Applications/My Driver/cua-driver"), directory: URL(fileURLWithPath: "/tmp/work"), target: "TextEdit", proxy: URL(fileURLWithPath: "/Applications/VibeRemote.app/Contents/MacOS/VibeRemote"))
        XCTAssertEqual(args.last, "-")
        XCTAssertTrue(args.contains("mcp_servers.cua.command=\"/Applications/VibeRemote.app/Contents/MacOS/VibeRemote\""))
        XCTAssertTrue(args.contains { $0.contains("--command-mcp-proxy") && $0.contains("/Applications/My Driver/cua-driver") })
        XCTAssertTrue(args.contains("--ignore-user-config"))
        XCTAssertTrue(args.contains("--ephemeral"))
        XCTAssertTrue(args.contains("read-only"))
        XCTAssertTrue(args.contains("approvals_reviewer=\"auto_review\""))
        XCTAssertTrue(args.contains("shell_tool"))
        XCTAssertFalse(args.contains("--dangerously-bypass-approvals-and-sandbox"))
        XCTAssertFalse(RemoteCommandConfiguration.tools.contains("clipboard_read"))
        XCTAssertFalse(RemoteCommandConfiguration.tools.contains("set_config"))
        XCTAssertEqual(RemoteCommandConfiguration.tomlString("a\"b\\c\n"), "\"a\\\"b\\\\c\\n\"")
    }

    func testBackgroundGatePinsDefaultAndDoesNotRequestConsent() throws {
        var forwarded = false
        _ = try CommandMCPGate.process(call("click", ["pid": 42, "window_id": 7, "element_token": "observed"]), approve: { _ in
            XCTFail("Background action requested foreground"); return false
        }, forward: { message in
            forwarded = true
            let args = (message["params"] as? [String: Any])?["arguments"] as? [String: Any]
            XCTAssertEqual(args?["delivery_mode"] as? String, "background")
            return ["id": 1, "result": [:]]
        })
        XCTAssertTrue(forwarded)
    }

    func testCodexCanLaunchWithoutBypassingForegroundConsent() throws {
        var deliveries = 0, approvals = 0
        _ = try CommandMCPGate.process(call("launch_app", ["bundle_id": "com.openai.codex"]), protectedPIDs: [99], approve: { _ in
            XCTFail("Background launch should not ask for foreground"); return false
        }, forward: { _ in deliveries += 1; return ["id": 1, "result": [:]] })
        _ = try CommandMCPGate.process(call("bring_to_front", ["pid": 42, "window_id": 7]), protectedPIDs: [99], approve: { _ in
            approvals += 1; return false
        }, forward: { _ in deliveries += 1; return ["id": 1, "result": [:]] })
        XCTAssertEqual(deliveries, 1)
        XCTAssertEqual(approvals, 1)
    }

    func testForegroundCannotForwardBeforeOneUseConsent() throws {
        var order: [String] = [], ids: [UUID] = []
        for _ in 0..<2 {
            _ = try CommandMCPGate.process(call("hotkey", ["pid": 42, "window_id": 7, "keys": ["cmd", "z"], "delivery_mode": "foreground"]), approve: { request in
                order.append("consent"); ids.append(request.id)
                XCTAssertEqual(request.pid, 42); XCTAssertEqual(request.windowID, 7)
                return true
            }, forward: { _ in order.append("forward"); return ["id": 1, "result": [:]] })
        }
        XCTAssertEqual(order, ["consent", "forward", "consent", "forward"])
        XCTAssertNotEqual(ids[0], ids[1])
    }

    func testCancelledForegroundNeverReachesDriver() throws {
        let response = try CommandMCPGate.process(call("bring_to_front", ["pid": 42, "window_id": 7]), approve: { _ in false }, forward: { _ in
            XCTFail("Cancelled action forwarded"); return nil
        })
        XCTAssertEqual((response?["result"] as? [String: Any])?["isError"] as? Bool, true)
    }

    func testDesktopAndUntargetedAndUnknownRoutesFailClosed() throws {
        let blocked: [(String, [String: Any])] = [
            ("click", ["scope": "desktop", "x": 1, "y": 2]),
            ("hotkey", ["target": ["kind": "desktop", "display_id": "primary"], "keys": ["cmd", "tab"]]),
            ("type_text", ["text": "test"]),
            ("bring_to_front", ["pid": 42]),
            ("click", ["pid": 42, "delivery_mode": "auto"]),
            ("click", ["pid": 42, "action": "raise"]),
            ("set_config", [:]),
            ("launch_app", ["name": "Test", "additional_arguments": ["--foreground"]]),
            ("browser_click", ["delivery_mode": "foreground"])
        ]
        for (tool, args) in blocked {
            _ = try CommandMCPGate.process(call(tool, args), approve: { _ in XCTFail("Invalid request prompted"); return true }, forward: { _ in
                XCTFail("Blocked route forwarded: \(tool)"); return nil
            })
        }
    }

    func testProxyDoesNotExposeUnrestrictedToolsOrOtherMCPMethods() throws {
        let response = try CommandMCPGate.process(["id": 1, "method": "tools/list"], approve: { _ in false }, forward: { _ in
            ["id": 1, "result": ["tools": [["name": "click"], ["name": "set_config"], ["name": "page"]]]]
        })
        let tools = (response?["result"] as? [String: Any])?["tools"] as? [[String: Any]]
        XCTAssertEqual(tools?.count, 1)
        XCTAssertEqual(tools?.first?["name"] as? String, "click")
        _ = try CommandMCPGate.process(["id": 2, "method": "resources/read"], approve: { _ in false }, forward: { _ in
            XCTFail("Unexpected method forwarded"); return nil
        })
    }

    func testModelCannotClickItsOwnContinueButton() throws {
        for arguments: [String: Any] in [
            ["pid": 42, "window_id": 7, "element_token": "continue-button"],
            ["target": ["kind": "window", "pid": 42, "window_id": 7], "x": 1, "y": 2]
        ] {
            _ = try CommandMCPGate.process(call("click", arguments), protectedPIDs: [42], approve: { _ in
                XCTFail("Self approval requested"); return true
            }, forward: { _ in XCTFail("Self approval forwarded"); return nil })
        }
    }

    func testMailboxRejectsStaleDuplicateAndPostCancellationConsent() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let mailbox = CommandApprovalMailbox(directory: dir)
        let first = CommandForegroundRequest(id: UUID(), tool: "click", pid: 42, windowID: 7)
        let second = CommandForegroundRequest(id: UUID(), tool: "click", pid: 42, windowID: 7)
        try mailbox.publish(first); try mailbox.approve(first.id)
        XCTAssertTrue(mailbox.consumeApproval(for: first.id))
        XCTAssertFalse(mailbox.consumeApproval(for: first.id))
        try mailbox.publish(second); try mailbox.approve(first.id)
        XCTAssertFalse(mailbox.consumeApproval(for: second.id))
        try mailbox.approve(second.id); mailbox.cancel()
        XCTAssertFalse(mailbox.consumeApproval(for: second.id))
        mailbox.clearRequest(); XCTAssertNil(mailbox.request)
    }

    func testWaitingDoesNotSpendExecutionBudget() {
        var budget = CommandExecutionBudget(now: 0)
        XCTAssertFalse(budget.tick(waiting: false, now: 30))
        XCTAssertFalse(budget.tick(waiting: true, now: 900))
        XCTAssertEqual(budget.remaining, 270)
        XCTAssertTrue(budget.tick(waiting: false, now: 1170))
    }

    private func call(_ tool: String, _ args: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": tool, "arguments": args]]
    }
    func testEventsPreserveSplitUTF8AndDoNotDisplayToolPayloads() {
        let source = """
        {"type":"item.started","item":{"type":"mcp_tool_call","tool":"click"}}
        {"type":"item.completed","item":{"type":"mcp_tool_call","result":{"secret":"private screen"}}}
        {"type":"item.completed","item":{"type":"agent_message","text":"已完成计算"}}
        {"type":"turn.completed"}

        """
        var decoder = RemoteCommandEvents()
        var updates: [String] = []
        for byte in source.utf8 { updates += decoder.receive(Data([byte])) }
        XCTAssertEqual(updates, ["正在操作界面…", "已完成计算"])
        XCTAssertTrue(decoder.completed)
        XCTAssertEqual(decoder.finalMessage, "已完成计算")
        XCTAssertNil(decoder.failure)
    }
    func testFailureCannotBeMistakenForSuccessfulFinalMessage() {
        var decoder = RemoteCommandEvents()
        _ = decoder.receive(Data("{\"type\":\"turn.failed\",\"error\":{\"message\":\"Authentication failed\"}}\n".utf8))
        XCTAssertEqual(decoder.failure, "Authentication failed")
        XCTAssertFalse(decoder.completed)
    }
    @MainActor func testSiriTapAndDelayedHoldKeepBothEdgesOwned() {
        let gate = SiriCommandGate()
        var commands = 0, menu: [Bool] = []
        gate.openCommand = { commands += 1 }
        gate.holdEdge = { pressed, _, _ in menu.append(pressed) }
        XCTAssertTrue(gate.handle(button: "siri", pressed: true, device: "one", generation: .glassTouchSurface, now: 1))
        XCTAssertTrue(gate.handle(button: "siri", pressed: true, device: "one", generation: .glassTouchSurface, now: 1.01))
        XCTAssertTrue(gate.handle(button: "siri", pressed: false, device: "one", generation: .glassTouchSurface, now: 1.1))
        XCTAssertEqual(commands, 1); XCTAssertTrue(menu.isEmpty)
        _ = gate.handle(button: "siri", pressed: true, device: "one", generation: .glassTouchSurface, now: 2)
        _ = gate.handle(button: "siri", pressed: false, device: "one", generation: .glassTouchSurface, now: 3)
        XCTAssertEqual(commands, 1); XCTAssertEqual(menu, [true, false])
        XCTAssertFalse(gate.handle(button: "playPause", pressed: true, device: "one", generation: .glassTouchSurface, now: 4))
        XCTAssertTrue(gate.handle(button: "siri", pressed: true, device: "one", generation: .aluminumClickpad, now: 4))
        XCTAssertTrue(gate.handle(button: "siri", pressed: false, device: "one", generation: .aluminumClickpad, now: 4.1))
        XCTAssertEqual(commands, 2)
    }
    @MainActor func testDisconnectCancelsPendingTapAndOtherDevicesStayIndependent() {
        let gate = SiriCommandGate()
        var commands = 0
        gate.openCommand = { commands += 1 }
        _ = gate.handle(button: "siri", pressed: true, device: "one", generation: .glassTouchSurface, now: 1)
        XCTAssertFalse(gate.handle(button: "siri", pressed: false, device: "two", generation: .glassTouchSurface, now: 1.1))
        gate.reset()
        XCTAssertFalse(gate.handle(button: "siri", pressed: false, device: "one", generation: .glassTouchSurface, now: 1.2))
        XCTAssertEqual(commands, 0)
    }
}
