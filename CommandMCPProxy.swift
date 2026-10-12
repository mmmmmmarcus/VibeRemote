import Foundation
import Darwin

/// One consent belongs to one intercepted call, never to the session or a later task.
struct CommandForegroundRequest: Codable, Equatable {
    let id: UUID
    let tool: String
    let pid: Int32?
    let windowID: Int?

    var actionName: String {
        switch tool {
        case "bring_to_front": return "显示目标窗口"
        case "drag": return "拖动"
        case "scroll", "browser_pointer": return "操作页面"
        case "type_text", "set_value", "browser_type": return "输入内容"
        case "press_key", "hotkey": return "发送按键"
        default: return "操作目标控件"
        }
    }
}

struct CommandApprovalMailbox {
    let directory: URL
    private var requestURL: URL { directory.appendingPathComponent("foreground-request.json") }
    private var approvalURL: URL { directory.appendingPathComponent("foreground-approval") }
    var isCancelled: Bool { FileManager.default.fileExists(atPath: directory.appendingPathComponent("cancelled").path) }
    var request: CommandForegroundRequest? {
        guard let data = try? Data(contentsOf: requestURL) else { return nil }
        return try? JSONDecoder().decode(CommandForegroundRequest.self, from: data)
    }
    func publish(_ request: CommandForegroundRequest) throws {
        try? FileManager.default.removeItem(at: approvalURL)
        try JSONEncoder().encode(request).write(to: requestURL, options: .atomic)
    }
    func approve(_ id: UUID) throws {
        guard !isCancelled, request?.id == id else { return }
        try Data(id.uuidString.utf8).write(to: approvalURL, options: .atomic)
    }
    func consumeApproval(for id: UUID) -> Bool {
        guard !isCancelled, request?.id == id,
              (try? String(contentsOf: approvalURL, encoding: .utf8)) == id.uuidString else { return false }
        try? FileManager.default.removeItem(at: approvalURL)
        return true
    }
    func clearRequest() {
        try? FileManager.default.removeItem(at: requestURL)
        try? FileManager.default.removeItem(at: approvalURL)
    }
    func cancel() { try? Data().write(to: directory.appendingPathComponent("cancelled"), options: .atomic) }
}

/// Enforce the boundary independently of the model's instructions. Unknown tools fail closed.
enum CommandBackgroundPolicy {
    static let deliveryTools: Set<String> = ["click", "double_click", "right_click", "drag", "scroll", "press_key", "hotkey", "type_text"]

    static func prepare(tool: String, arguments: [String: Any]) throws -> (arguments: [String: Any], foreground: Bool) {
        guard RemoteCommandConfiguration.tools.contains(tool) else { throw Failure("Tool is not available in VibeRemote.") }
        var args = arguments
        let target = args["target"] as? [String: Any]
        // Untargeted desktop input can land in whichever app the human is using. Require
        // an exact window even after consent; the model can discover it without activation.
        guard args["scope"] as? String != "desktop", target?["kind"] as? String != "desktop" else {
            throw Failure("Desktop-wide input is unavailable. Read list_windows and address an exact pid/window_id instead.")
        }
        if tool == "launch_app" {
            guard args["additional_arguments"] == nil, args["webkit_inspector_port"] == nil else {
                throw Failure("Launch arguments and inspector setup are unavailable; use a normal background launch.")
            }
        }
        if tool == "click", let action = args["action"] as? String,
           !["press", "show_menu", "pick", "confirm", "cancel", "open"].contains(action) {
            throw Failure("Unsupported AX action.")
        }
        // These browser tools have a background-only contract. Reject future/unknown
        // foreground switches instead of letting additionalProperties bypass this gate.
        if !deliveryTools.contains(tool), tool != "bring_to_front", args["delivery_mode"] != nil {
            throw Failure("This tool has no approved foreground delivery contract.")
        }
        var foreground = tool == "bring_to_front"
        if deliveryTools.contains(tool) {
            let mode = args["delivery_mode"] as? String ?? "background"
            guard ["background", "foreground"].contains(mode) else { throw Failure("Invalid delivery mode.") }
            foreground = mode == "foreground"
            args["delivery_mode"] = mode
            let pid = (args["pid"] as? Int) ?? (target?["pid"] as? Int)
            guard let pid, pid > 0 else {
                throw Failure("An exact application target is required; inspect list_windows first.")
            }
        }
        if foreground {
            let pid = (args["pid"] as? Int) ?? (target?["pid"] as? Int)
            let window = (args["window_id"] as? Int) ?? (target?["window_id"] as? Int)
            guard let pid, pid > 0, let window, window > 0 else {
                throw Failure("Foreground requests require an explicit pid and window_id from a fresh observation.")
            }
        }
        return (args, foreground)
    }

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}

/// JSON-RPC gate: hold the original call until a native button supplies one-use consent.
/// The live Codex turn and MCP connection remain intact while waiting.
enum CommandMCPGate {
    static func process(_ request: [String: Any], protectedPIDs: Set<Int> = [], approve: (CommandForegroundRequest) -> Bool,
                        jev: (([String: Any]) throws -> [String: Any])? = nil,
                        forward: ([String: Any]) throws -> [String: Any]?) throws -> [String: Any]? {
        let method = request["method"] as? String ?? ""
        if method == "tools/call" {
            let params = request["params"] as? [String: Any] ?? [:]
            let tool = params["name"] as? String ?? ""
            do {
                let arguments = params["arguments"] as? [String: Any] ?? [:]
                let target = arguments["target"] as? [String: Any]
                let addressedPIDs = [arguments["pid"] as? Int, target?["pid"] as? Int].compactMap { $0 }
                guard protectedPIDs.isDisjoint(with: addressedPIDs) else {
                    throw CommandBackgroundPolicy.Failure("VibeRemote's own UI cannot be inspected or operated by this agent. The host remains excluded from target applications.")
                }
                if tool == "launch_app" {
                    let name = (arguments["name"] as? String ?? "").lowercased()
                    let bundle = (arguments["bundle_id"] as? String ?? "").lowercased()
                    guard !name.contains("viberemote"), bundle != "com.viberemote.app" else {
                        throw CommandBackgroundPolicy.Failure("The agent cannot launch or activate its own host.")
                    }
                }
                if tool == CommandJevBatch.toolName {
                    guard let jev else { throw CommandBackgroundPolicy.Failure("Jev is not enabled for this task.") }
                    let result = try jev(arguments)
                    let data = try JSONSerialization.data(withJSONObject: result)
                    return ["jsonrpc": "2.0", "id": request["id"] ?? NSNull(), "result": [
                        "structuredContent": result,
                        "content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]]]]
                }
                let prepared = try CommandBackgroundPolicy.prepare(tool: tool, arguments: arguments)
                if prepared.foreground {
                    let args = prepared.arguments
                    let target = args["target"] as? [String: Any]
                    let pid = ((args["pid"] as? Int) ?? (target?["pid"] as? Int)).flatMap(Int32.init(exactly:))
                    let window = (args["window_id"] as? Int) ?? (target?["window_id"] as? Int)
                    guard approve(CommandForegroundRequest(id: UUID(), tool: tool, pid: pid, windowID: window)) else {
                        throw CommandBackgroundPolicy.Failure("Foreground action was cancelled. It was NOT executed. Do not retry or use another route.")
                    }
                }
                var outgoing = request, nextParams = params
                nextParams["arguments"] = prepared.arguments; outgoing["params"] = nextParams
                return try forward(outgoing)
            } catch let error as CommandBackgroundPolicy.Failure {
                return ["jsonrpc": "2.0", "id": request["id"] ?? NSNull(), "result": [
                    "isError": true, "content": [["type": "text", "text": error.message]]]]
            }
        }
        guard ["initialize", "notifications/initialized", "notifications/cancelled", "ping", "tools/list"].contains(method) else {
            guard let id = request["id"] else { return nil }
            return ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method unavailable"]]
        }
        guard var response = try forward(request) else { return nil }
        if method == "tools/list", var result = response["result"] as? [String: Any],
           let tools = result["tools"] as? [[String: Any]] {
            result["tools"] = tools.filter { RemoteCommandConfiguration.tools.contains($0["name"] as? String ?? "") }.map { tool in
                var tool = tool
                tool["description"] = (tool["description"] as? String ?? "") + "\nVibeRemote: background by default. Use foreground delivery directly when required, with an exact pid/window_id. No VibeRemote confirmation is needed. Prefer background when it works."
                return tool
            }
            if jev != nil { result["tools"] = (result["tools"] as? [[String: Any]] ?? []) + [CommandJevBatch.definition] }
            result.removeValue(forKey: "nextCursor")
            response["result"] = result
        }
        return response
    }
}

/// Internal app executable mode. Runs before AppKit initialization; never creates a
/// second menu-bar app or touches the remote/audio pipeline.
/// Host-owned presentation only: never grants foreground or sends pointer input.
struct CommandCursorPresentation {
    let session = "VibeRemote-" + UUID().uuidString
    var sessionTools = Set<String>()
    var attempted = false
    var started = false
    mutating func observeTools(_ response: [String: Any]) {
        guard let result = response["result"] as? [String: Any],
              let tools = result["tools"] as? [[String: Any]] else { return }
        sessionTools = Set(tools.compactMap { tool in
            guard let name = tool["name"] as? String,
                  let schema = tool["inputSchema"] as? [String: Any],
                  let properties = schema["properties"] as? [String: Any],
                  properties["session"] != nil else { return nil }
            return name
        })
    }
    var setup: [(String, [String: Any])] { [
        ("start_session", ["session": session]),
        ("set_agent_cursor_enabled", ["session": session, "enabled": true]),
        ("set_agent_cursor_motion", ["session": session, "glide_duration_ms": 300,
            "dwell_after_click_ms": 250, "idle_hide_ms": 8000])
    ] }
    func bind(_ request: [String: Any]) -> [String: Any] {
        guard started, request["method"] as? String == "tools/call",
              var params = request["params"] as? [String: Any],
              let name = params["name"] as? String, sessionTools.contains(name) else { return request }
        var args = params["arguments"] as? [String: Any] ?? [:]
        args["session"] = session
        params["arguments"] = args
        var bound = request; bound["params"] = params
        return bound
    }
}

enum CommandMCPProxy {
    static func foregroundAllowed(cancelled: Bool, ownerAlive: Bool) -> Bool {
        !cancelled && ownerAlive
    }

    static func run(driver: URL, directory: URL, ownerPID: Int32) -> Int32 {
        let proxyStartedAt = ProcessInfo.processInfo.systemUptime
        var measurements = CommandMCPMeasurements()
        let mailbox = CommandApprovalMailbox(directory: directory)
        let child = Process(), input = Pipe(), output = Pipe()
        child.executableURL = driver; child.arguments = ["mcp"]
        child.standardInput = input; child.standardOutput = output
        // Driver diagnostics may contain page data. Do not merge them into user-visible logs.
        child.standardError = FileHandle.nullDevice
        do { try child.run() } catch { return 1 }
        defer {
            mailbox.clearRequest()
            try? input.fileHandleForWriting.close()
            if child.isRunning { child.terminate() }
        }
        // The blocked MCP call cannot read stdin cancellation. Observe the owning app
        // and a private cancellation marker independently, including while reading a tool result.
        DispatchQueue.global().async {
            while true {
                if kill(ownerPID, 0) != 0 || mailbox.isCancelled || !FileManager.default.fileExists(atPath: directory.path) {
                    if child.isRunning { child.terminate() }
                    _exit(0)
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        let source = LineReader(FileHandle.standardInput), replies = LineReader(output.fileHandleForReading)
        var cursor = CommandCursorPresentation()
        var lastPreviewAt = 0.0
        var lastPreviewTarget = ""
        let exchange: ([String: Any]) throws -> [String: Any]? = { outgoing in
            try write(outgoing, to: input.fileHandleForWriting)
            guard let expectedID = outgoing["id"] else { return nil }
            while let data = try replies.next() {
                guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                if let id = response["id"], String(describing: id) == String(describing: expectedID) { return response }
                if response["id"] == nil { try write(response, to: .standardOutput) }
            }
            throw CommandBackgroundPolicy.Failure("Cua Driver disconnected.")
        }
        func cursorCall(_ name: String, _ args: [String: Any]) -> [String: Any] {
            ["jsonrpc": "2.0", "id": "cursor-" + UUID().uuidString, "method": "tools/call",
             "params": ["name": name, "arguments": args]]
        }
        do {
            while let line = try source.next(),
                  let request = try JSONSerialization.jsonObject(with: line) as? [String: Any] {
                // The user authorized automatic foreground delivery. Preserve task
                // cancellation/owner liveness, without publishing a consent request.
                let approve: (CommandForegroundRequest) -> Bool = { _ in
                    foregroundAllowed(cancelled: mailbox.isCancelled, ownerAlive: kill(ownerPID, 0) == 0)
                }
                let forward: ([String: Any]) throws -> [String: Any]? = { outgoing in
                    let began = ProcessInfo.processInfo.systemUptime
                    defer {
                        let now = ProcessInfo.processInfo.systemUptime
                        if outgoing["method"] as? String == "initialize" {
                            measurements.connectionSeconds = now - proxyStartedAt
                        } else if outgoing["method"] as? String == "tools/call" {
                            measurements.toolSeconds += now - began
                            measurements.toolCalls += 1
                        }
                        measurements.save(to: directory)
                    }
                    if outgoing["method"] as? String == "tools/call", !cursor.attempted {
                        cursor.attempted = true
                        // These host-only calls are never exposed as model tools. Older
                        // Drivers can keep their default overlay if setup is unavailable.
                        for (name, args) in cursor.setup {
                            guard let reply = try exchange(cursorCall(name, args)), reply["error"] == nil,
                                  let result = reply["result"] as? [String: Any], result["isError"] as? Bool != true else { break }
                            if name == "start_session" { cursor.started = true }
                        }
                    }
                    let response = try exchange(cursor.bind(outgoing))
                    if outgoing["method"] as? String == "tools/list", let response { cursor.observeTools(response) }
                    if outgoing["method"] as? String == "tools/call",
                       let params = outgoing["params"] as? [String: Any],
                       let name = params["name"] as? String,
                       let args = params["arguments"] as? [String: Any] {
                        let previewURL = directory.appendingPathComponent("preview.json")
                        if name == "end_session" { try? FileManager.default.removeItem(at: previewURL) }
                        let target = args["target"] as? [String: Any]
                        let pid = args["pid"] as? Int ?? target?["pid"] as? Int
                        let window = args["window_id"] as? Int ?? target?["window_id"] as? Int
                        let now = ProcessInfo.processInfo.systemUptime
                        if let pid, pid > 0, pid != Int(ownerPID), pid != Int(getpid()), let window, window > 0,
                           cursor.started, name != "end_session",
                           now - lastPreviewAt > 0.4 || lastPreviewTarget != "\(pid):\(window)" {
                            lastPreviewAt = now; lastPreviewTarget = "\(pid):\(window)"
                            // Capture-only never walks AX or replaces its action tokens.
                            // Keep these local frames out of model replies and timing logs.
                            let capture = try? exchange(cursorCall("get_window_state", ["pid": pid, "window_id": window,
                                "include_accessibility_tree": false, "include_screenshot": true,
                                "max_dimension": 720, "session": cursor.session]))
                            let cursorReply = try? exchange(cursorCall("get_agent_cursor_state", ["session": cursor.session]))
                            let state = (cursorReply?["result"] as? [String: Any])?["structuredContent"] as? [String: Any]
                            if let capture, let frame = CommandPreviewFrame.make(response: capture, cursor: state),
                               let encoded = try? JSONEncoder().encode(frame), !mailbox.isCancelled {
                                try? encoded.write(to: previewURL, options: .atomic)
                                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: previewURL.path)
                            } else { try? FileManager.default.removeItem(at: previewURL) }
                        }
                    }
                    return response
                }
                let protected: Set<Int> = [Int(ownerPID), Int(getpid())]
                let enabled = FileManager.default.fileExists(atPath: directory.appendingPathComponent("jev-enabled").path)
                let jev: (([String: Any]) throws -> [String: Any])? = enabled ? { args in
                    guard args["ordered_labels"] != nil else {
                        throw CommandJevWorker.Failure("Provide the complete ordered_labels plan. No action executed.")
                    }
                    let plan = try CommandJevBatch.Plan(args)
                    guard let key = try CommandKeychain.read(), !key.isEmpty else {
                        return ["status": "handoff", "reason": "OpenRouter key unavailable. Codex may continue after inspecting current state."]
                    }
                    let api = CommandJevWorker.API(key: key)
                    measurements.jevBatches += 1
                    let batch = CommandJevBatch.execute(plan, choose: { state, criteria, instructions in
                        let started = ProcessInfo.processInfo.systemUptime
                        defer {
                            measurements.jevDecisions += 1
                            measurements.jevDecisionSeconds += ProcessInfo.processInfo.systemUptime - started
                            measurements.save(to: directory)
                        }
                        return try api.choose(state: state, criteria: criteria, instructions: instructions)
                    }, call: { name, arguments in
                        let nested: [String: Any] = ["jsonrpc": "2.0", "id": "jev-\(UUID().uuidString)", "method": "tools/call",
                            "params": ["name": name, "arguments": arguments]]
                        guard let response = try CommandMCPGate.process(nested, protectedPIDs: protected,
                                approve: approve, forward: forward),
                              let result = response["result"] as? [String: Any],
                              result["isError"] as? Bool != true,
                              let structured = result["structuredContent"] as? [String: Any] else {
                            throw CommandJevWorker.Failure("Driver refused the bounded action. Inspect current state before continuing.")
                        }
                        return structured
                    })
                    measurements.jevActions += (batch["clicked_labels"] as? [String] ?? []).count
                    measurements.save(to: directory)
                    return batch
                } : nil
                let response: [String: Any]?
                do {
                    response = try CommandMCPGate.process(request, protectedPIDs: protected,
                        approve: approve, jev: jev, forward: forward)
                } catch {
                    response = ["jsonrpc": "2.0", "id": request["id"] ?? NSNull(), "result": ["isError": true,
                        "content": [["type": "text", "text": "Invalid Jev plan or unavailable configuration. No further action executed."]]]]
                }
                if let response { try write(response, to: .standardOutput) }
            }
            if cursor.started { _ = try? exchange(cursorCall("end_session", ["session": cursor.session])) }
            return 0
        } catch { return 1 }
    }

    private static func write(_ object: [String: Any], to handle: FileHandle) throws {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        data.append(10); try handle.write(contentsOf: data)
    }
    private final class LineReader {
        let handle: FileHandle
        var pending = Data()
        init(_ handle: FileHandle) { self.handle = handle }
        func next() throws -> Data? {
            while true {
                if let newline = pending.firstIndex(of: 10) {
                    let line = Data(pending[..<newline]); pending.removeSubrange(...newline); return line
                }
                let data = handle.availableData
                if data.isEmpty { return nil }
                pending.append(data)
                guard pending.count <= 32_000_000 else { throw CommandBackgroundPolicy.Failure("Oversized MCP message") }
            }
        }
    }
}

/// Task-private, fixed numeric schema. Replaced atomically and removed with the
/// task directory; foreground waiting is counted separately from driver work.
struct CommandMCPMeasurements: Codable {
    var connectionSeconds: TimeInterval?
    var toolSeconds: TimeInterval = 0
    var consentSeconds: TimeInterval = 0
    var toolCalls = 0
    var jevDecisionSeconds: TimeInterval = 0
    var jevDecisions = 0
    var jevBatches = 0
    var jevActions = 0
    func save(to directory: URL) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: directory.appendingPathComponent("timing.json"), options: .atomic)
    }
    static func read(from directory: URL) -> Self? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("timing.json")) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
    var summary: String {
        let connection = connectionSeconds.map { String(format: "%.3f", $0) } ?? "unavailable"
        return "connection_s=\(connection) driver_s=\(String(format: "%.3f", toolSeconds)) consent_wait_s=\(String(format: "%.3f", consentSeconds)) driver_calls=\(toolCalls) jev_s=\(String(format: "%.3f", jevDecisionSeconds)) jev_decisions=\(jevDecisions) jev_batches=\(jevBatches) jev_actions=\(jevActions)"
    }
}
