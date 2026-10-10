import XCTest
@testable import VibeRemote

final class CommandTests: XCTestCase {
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
        XCTAssertEqual(updates, ["正在操作：click", "已完成计算"])
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
