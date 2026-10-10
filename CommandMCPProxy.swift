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
                    throw CommandBackgroundPolicy.Failure("VibeRemote's own UI cannot be inspected or operated by this agent. Only a human can approve foreground actions.")
                }
                if tool == "launch_app" {
                    let name = (arguments["name"] as? String ?? "").lowercased()
                    let bundle = (arguments["bundle_id"] as? String ?? "").lowercased()
                    guard !name.contains("viberemote"), bundle != "com.viberemote.app" else {
                        throw CommandBackgroundPolicy.Failure("The agent cannot launch or activate its own host.")
                    }
                }
                let prepared = try CommandBackgroundPolicy.prepare(tool: tool, arguments: arguments)
                if prepared.foreground {
                    let args = prepared.arguments
                    let target = args["target"] as? [String: Any]
                    let pid = ((args["pid"] as? Int) ?? (target?["pid"] as? Int)).flatMap(Int32.init(exactly:))
                    let window = (args["window_id"] as? Int) ?? (target?["window_id"] as? Int)
                    guard approve(CommandForegroundRequest(id: UUID(), tool: tool, pid: pid, windowID: window)) else {
                        throw CommandBackgroundPolicy.Failure("Foreground action was cancelled or expired. It was NOT executed. Do not retry or use another route.")
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
                tool["description"] = (tool["description"] as? String ?? "") + "\nVibeRemote: background by default. Foreground calls pause until the human clicks 继续执行; each call needs separate consent. Try a background alternative first."
                return tool
            }
            result.removeValue(forKey: "nextCursor")
            response["result"] = result
        }
        return response
    }
}

/// Internal app executable mode. Runs before AppKit initialization; never creates a
/// second menu-bar app or touches the remote/audio pipeline.
enum CommandMCPProxy {
    static func run(driver: URL, directory: URL, ownerPID: Int32) -> Int32 {
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
        do {
            while let line = try source.next(),
                  let request = try JSONSerialization.jsonObject(with: line) as? [String: Any] {
                let response = try CommandMCPGate.process(request, protectedPIDs: [Int(ownerPID), Int(getpid())], approve: { request in
                    do { try mailbox.publish(request) } catch { return false }
                    defer { mailbox.clearRequest() }
                    let deadline = ProcessInfo.processInfo.systemUptime + 900
                    while ProcessInfo.processInfo.systemUptime < deadline {
                        if mailbox.isCancelled { return false }
                        if mailbox.consumeApproval(for: request.id) { return !mailbox.isCancelled }
                        Thread.sleep(forTimeInterval: 0.1)
                    }
                    return false
                }, forward: { outgoing in
                    try write(outgoing, to: input.fileHandleForWriting)
                    guard let expectedID = outgoing["id"] else { return nil }
                    while let data = try replies.next() {
                        guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        if let id = response["id"], String(describing: id) == String(describing: expectedID) { return response }
                        // Forward upstream notifications, never an unsolicited server request.
                        if response["id"] == nil { try write(response, to: .standardOutput) }
                    }
                    throw CommandBackgroundPolicy.Failure("Cua Driver disconnected.")
                })
                if let response { try write(response, to: .standardOutput) }
            }
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
