import ArgumentParser
import Darwin
import Foundation
import KktcliCore

private typealias JSONDict = [String: Any]

private struct MCPCommandResult {
    let returncode: Int32
    let stdout: String
    let stderr: String
    let latencyMs: Int
    let timedOut: Bool
}

private struct MCPToolError: Error, @unchecked Sendable {
    let code: Int
    let message: String
    let data: JSONDict

    init(code: Int, message: String, data: JSONDict = [:]) {
        self.code = code
        self.message = message
        self.data = data
    }
}

private enum MCPStdioTransport {
    case contentLength
    case newlineDelimitedJSON
}

private final class MCPDataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func store(_ newData: Data) {
        lock.lock()
        data = newData
        lock.unlock()
    }

    func load() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

private final class SubprocessRunner {
    let executablePath: String

    init() {
        if let bundlePath = Bundle.main.executablePath, !bundlePath.isEmpty {
            executablePath = bundlePath
        } else {
            executablePath = CommandLine.arguments[0]
        }
    }

    func run(_ arguments: [String], timeoutSec: TimeInterval) -> MCPCommandResult {
        let start = Date()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return MCPCommandResult(
                returncode: 127,
                stdout: "",
                stderr: String(describing: error),
                latencyMs: Int(Date().timeIntervalSince(start) * 1000),
                timedOut: false
            )
        }

        let stdoutData = MCPDataBuffer()
        let stderrData = MCPDataBuffer()
        let stdoutSemaphore = DispatchSemaphore(value: 0)
        let stderrSemaphore = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            stdoutData.store(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            stdoutSemaphore.signal()
        }
        DispatchQueue.global().async {
            stderrData.store(stderrPipe.fileHandleForReading.readDataToEndOfFile())
            stderrSemaphore.signal()
        }

        let waitSemaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            process.waitUntilExit()
            waitSemaphore.signal()
        }

        let timedOut = waitSemaphore.wait(timeout: .now() + timeoutSec) == .timedOut
        if timedOut {
            process.terminate()

            let terminateSemaphore = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                process.waitUntilExit()
                terminateSemaphore.signal()
            }

            if terminateSemaphore.wait(timeout: .now() + 0.5) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }

        _ = stdoutSemaphore.wait(timeout: .now() + 1.0)
        _ = stderrSemaphore.wait(timeout: .now() + 1.0)

        let stdout = String(decoding: stdoutData.load(), as: UTF8.self)
        let stderr = String(decoding: stderrData.load(), as: UTF8.self)

        return MCPCommandResult(
            returncode: process.terminationStatus,
            stdout: stdout,
            stderr: stderr,
            latencyMs: Int(Date().timeIntervalSince(start) * 1000),
            timedOut: timedOut
        )
    }

    func checkReady() -> (Bool, JSONDict) {
        let version = run(["--version"], timeoutSec: 2.0)
        if version.returncode != 0 {
            return (
                false,
                [
                    "stage": "version",
                    "message": "kktcli binary not executable",
                    "stdout": version.stdout,
                    "stderr": version.stderr,
                    "kktcli_bin": executablePath,
                ]
            )
        }

        let env = ProcessInfo.processInfo.environment
        let shouldRunStatusCheck = (env["KKTCLI_MCP_STARTUP_STATUS_CHECK"] ?? "false").lowercased() == "true"
        if !shouldRunStatusCheck {
            return (
                true,
                [
                    "kktcli_bin": executablePath,
                    "version": version.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                    "status_check": "skipped",
                ]
            )
        }

        let status = run(["status"], timeoutSec: 15.0)
        if status.returncode != 0 {
            return (
                false,
                [
                    "stage": "status",
                    "message": "kktcli status check failed",
                    "stdout": status.stdout,
                    "stderr": status.stderr,
                    "kktcli_bin": executablePath,
                ]
            )
        }

        return (
            true,
            [
                "kktcli_bin": executablePath,
                "version": version.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            ]
        )
    }
}

private final class KktcliMCPServer {
    private let protocolVersion = "2024-11-05"
    private let runner = SubprocessRunner()
    private let deepRecoveryDefault: Bool
    private let backgroundSafeDefault: Bool
    private let traceDefault: Bool
    private let readLayoutDefault: String
    private let serverVersion: String
    private var initialized = false
    private var shutdown = false
    private var responseTransport: MCPStdioTransport = .contentLength

    init() {
        let env = ProcessInfo.processInfo.environment
        deepRecoveryDefault = (env["KKTCLI_DEFAULT_DEEP_RECOVERY"] ?? "false").lowercased() == "true"
        backgroundSafeDefault = (env["KKTCLI_DEFAULT_BACKGROUND_SAFE"] ?? "false").lowercased() == "true"
        traceDefault = (env["KKTCLI_TRACE_DEFAULT"] ?? "false").lowercased() == "true"
        readLayoutDefault = Self.validReadLayout(env["KKTCLI_DEFAULT_READ_LAYOUT"]) ?? "preserve"
        serverVersion = env["KKTCLI_MCP_VERSION"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? env["KKTCLI_MCP_VERSION"]!.trimmingCharacters(in: .whitespacesAndNewlines)
            : BuildVersion.current
    }

    func serveForever() throws {
        while !shutdown {
            guard let request = readMessage() else { break }
            guard request["method"] != nil else { continue }

            let requestID = request["id"]
            do {
                if let response = try handleRequest(request) {
                    try writeMessage(response)
                }
            } catch let error as MCPToolError {
                guard let requestID else { continue }
                try writeMessage(jsonRPCError(id: requestID, code: error.code, message: error.message, data: error.data))
            } catch {
                guard let requestID else { continue }
                try writeMessage(
                    jsonRPCError(
                        id: requestID,
                        code: -32000,
                        message: "Internal server error",
                        data: ["detail": String(describing: error)]
                    )
                )
            }
        }
    }

    private func handleRequest(_ request: JSONDict) throws -> JSONDict? {
        let method = request["method"] as? String
        let requestID = request["id"] ?? NSNull()

        switch method {
        case "initialize":
            initialized = true
            let (ready, detail) = runner.checkReady()
            var startupCheck = detail
            if !ready {
                startupCheck["note"] = "MCP server started, but kktcli readiness check failed"
            }
            return jsonRPCResult(
                id: requestID,
                result: [
                    "protocolVersion": protocolVersion,
                    "capabilities": [
                        "tools": JSONDict(),
                    ],
                    "serverInfo": [
                        "name": "kktcli",
                        "version": serverVersion,
                    ],
                    "instructions": "Use kktcli_read for read-only operations. It opens rooms with unread messages like any other, which sends read receipts exactly as opening them by hand; pass skip_unread=true to leave such rooms unopened (UNREAD_REFUSED). While the user is busy in KakaoTalk it waits (KAKAOTALK_IN_USE after wait_for_idle); it never brings KakaoTalk to the front unless allow_activate=true (MAIN_WINDOW_NOT_VISIBLE otherwise). Sending is off unless the user turned it on with kktcli config set send on; never enable it on your own, and the send tools are listed only while it is on. When sending: draft concisely, keep dates, times, places, amounts, links and asks verbatim, drop greetings, background and repetition and tell the user what you dropped, never add facts, at most 3 lines unless the user asked for more. Always call kktcli_send (or kktcli_send_image) with mode=preview first, show the user the preview (recipient, last messages, exact text) and wait for their explicit 보내 before calling it again with mode=send. One message per call; never send in bulk; never retry a send whose result is uncertain without reading the room first.",
                    "meta": [
                        "startup_check": startupCheck,
                    ],
                ]
            )

        case "notifications/initialized":
            return nil

        case "ping":
            return jsonRPCResult(id: requestID, result: JSONDict())

        case "tools/list":
            try ensureInitialized()
            return jsonRPCResult(id: requestID, result: ["tools": toolDefinitions()])

        case "tools/call":
            try ensureInitialized()
            let params = request["params"] as? JSONDict ?? [:]
            let result = try handleToolsCall(params)
            return jsonRPCResult(id: requestID, result: result)

        case "shutdown":
            try ensureInitialized()
            shutdown = true
            return jsonRPCResult(id: requestID, result: JSONDict())

        case "exit":
            shutdown = true
            return nil

        default:
            throw MCPToolError(code: -32601, message: "Method not found: \(method ?? "")")
        }
    }

    private func ensureInitialized() throws {
        if !initialized {
            throw MCPToolError(code: -32002, message: "Server not initialized")
        }
    }

    private func toolDefinitions() -> [[String: Any]] {
        [
            [
                "name": "kktcli_read",
                "description": "Read recent KakaoTalk messages from a chat via kktcli. Opens a closed room through the chat list's context menu without keystrokes. A room with unread messages is opened too, which sends read receipts like opening it by hand; skip_unread=true leaves such rooms unopened.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "chat": ["type": "string", "description": "Chat room or user name"],
                        "chat_id": ["type": "string", "description": "Synthetic chat_id from kktcli chats"],
                        "limit": ["type": "integer", "minimum": 1, "maximum": MCPReadRequest.maximumLimit, "default": 20],
                        "skip_unread": [
                            "type": "boolean",
                            "default": false,
                            "description": "Do not open the room if its chat-list row shows unread messages (fails with UNREAD_REFUSED instead), so no read receipts are sent.",
                        ],
                        "allow_unread": [
                            "type": "boolean",
                            "description": "Deprecated and ignored: rooms with unread messages are opened by default; see skip_unread.",
                        ],
                        "scrollback": [
                            "type": "boolean",
                            "description": "true: load older messages until limit is reached (within scrollback_timeout; the call timeout is extended accordingly). false: never scroll. Omit for automatic scrollback, which stays within the default timeout.",
                        ],
                        "scrollback_timeout": [
                            "type": "number",
                            "minimum": 0,
                            "maximum": MCPReadRequest.maximumScrollbackSeconds,
                            "description": "Seconds for loading older messages (kktcli default 4).",
                        ],
                        "idle_seconds": [
                            "type": "number",
                            "minimum": 0,
                            "maximum": UserActivityPolicy.maximumSeconds,
                            "description": "While KakaoTalk is in front, press nothing until the keyboard and mouse were idle this many seconds (default 10).",
                        ],
                        "wait_for_idle": [
                            "type": "number",
                            "minimum": 0,
                            "maximum": UserActivityPolicy.maximumSeconds,
                            "description": "Seconds to wait for that before failing with KAKAOTALK_IN_USE (default 30; 0 fails at once). The call timeout is extended by it.",
                        ],
                        "allow_activate": [
                            "type": "boolean",
                            "default": false,
                            "description": "Allow bringing KakaoTalk to the front when its main window is not visible (closed, minimised, or on another desktop or full-screen Space); may switch the user's desktop. Without it such reads fail with MAIN_WINDOW_NOT_VISIBLE.",
                        ],
                        "include_system": [
                            "type": "boolean",
                            "default": false,
                            "description": "Include system messages such as joins and notices",
                        ],
                        "deep_recovery": [
                            "type": "boolean",
                            "default": deepRecoveryDefault,
                            "description": "Enable deep recovery mode for window resolution",
                        ],
                        "background_safe": [
                            "type": "boolean",
                            "default": backgroundSafeDefault,
                            "description": "Only read already exposed matching chat windows; do not launch, activate, search, resize, or close KakaoTalk windows",
                        ],
                        "keep_window": [
                            "type": "boolean",
                            "default": false,
                            "description": "Keep auto-opened KakaoTalk window",
                        ],
                        "trace_ax": [
                            "type": "boolean",
                            "default": traceDefault,
                            "description": "Include AX tracing logs",
                        ],
                        "layout": [
                            "type": "string",
                            "enum": ["preserve", "left", "right", "split-left", "split-right"],
                            "default": readLayoutDefault,
                            "description": "Window layout before reading",
                        ],
                    ],
                    "additionalProperties": false,
                ],
            ],
        ] + (ConfigStore.load().send ? sendToolDefinitions() : [])
    }

    /// Offered only while sending is on (`kktcli config set send on`).
    private func sendToolDefinitions() -> [[String: Any]] {
        [
            sendToolDefinition(
                name: "kktcli_send",
                description: "Send one KakaoTalk text message, only ever after the user saw it. mode=preview (the default) sends nothing: it opens the room like kktcli_read and returns who it goes to (title, kind, members, chat_id), the last 3 messages, a same-name warning and the exact text with line and character counts. mode=send sends it: the room is checked again right before its own 전송 button is pressed once, and the new bubble is verified; the result reports sent and bubble_verified. Call mode=send only after the user saw the preview and explicitly said 보내.",
                payloadKey: "message",
                payloadDescription: "The exact message text (at most 3 lines unless the user asked for more)"
            ),
            sendToolDefinition(
                name: "kktcli_send_image",
                description: "Send one image to a KakaoTalk chat, only ever after the user saw it. mode=preview (the default) sends nothing; mode=send pastes it (KakaoTalk comes to the front for the paste) and verifies the bubble. The clipboard and the previous front app are restored afterwards.",
                payloadKey: "image_path",
                payloadDescription: "Absolute path to a local image file"
            ),
        ]
    }

    private func handleToolsCall(_ params: JSONDict) throws -> JSONDict {
        let name = params["name"] as? String ?? ""
        let arguments = params["arguments"] as? JSONDict ?? [:]

        let resultObject: JSONDict
        switch name {
        case "kktcli_read":
            resultObject = callRead(arguments)
        case "kktcli_send":
            resultObject = callSend(arguments)
        case "kktcli_send_image":
            resultObject = callSendImage(arguments)
        default:
            throw MCPToolError(code: -32601, message: "Unknown tool: \(name)")
        }

        return [
            "content": [["type": "text", "text": prettyJSONString(resultObject)]],
            "isError": !(resultObject["ok"] as? Bool ?? false),
            "structuredContent": resultObject,
        ]
    }

    private func callRead(_ arguments: JSONDict) -> JSONDict {
        let chat = String(describing: arguments["chat"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let chatID = String(describing: arguments["chat_id"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if chat.isEmpty && chatID.isEmpty {
            return errorPayload(
                code: "INVALID_ARGUMENT",
                message: "chat or chat_id is required",
                hint: "Provide either a non-empty chat name or a chat_id from kktcli chats.",
                rawStdout: "",
                rawStderr: "",
                latencyMs: 0
            )
        }
        if !chat.isEmpty && !chatID.isEmpty {
            return errorPayload(
                code: "INVALID_ARGUMENT",
                message: "chat and chat_id cannot be used together",
                hint: "Use chat_id for stable identity, or chat for name-based lookup.",
                rawStdout: "",
                rawStderr: "",
                latencyMs: 0
            )
        }

        let rawLimit = arguments["limit"]
        let limit: Int
        if rawLimit == nil {
            limit = 20
        } else if let intValue = rawLimit as? Int {
            limit = intValue
        } else if let doubleValue = rawLimit as? Double {
            limit = Int(doubleValue)
        } else {
            return errorPayload(
                code: "INVALID_ARGUMENT",
                message: "limit must be an integer",
                hint: "Use integer range 1..\(MCPReadRequest.maximumLimit) for limit.",
                rawStdout: "",
                rawStderr: "",
                latencyMs: 0
            )
        }

        guard let layout = Self.validReadLayout(arguments["layout"] as? String ?? readLayoutDefault) else {
            return errorPayload(
                code: "INVALID_ARGUMENT",
                message: "layout must be preserve, left, right, split-left, or split-right",
                hint: "Use layout=preserve, layout=left, layout=right, layout=split-left, or layout=split-right.",
                rawStdout: "",
                rawStderr: "",
                latencyMs: 0
            )
        }

        var scrollbackSeconds: Double?
        if let raw = arguments["scrollback_timeout"], !(raw is NSNull) {
            // JSON booleans are NSNumbers too; only accept real numbers.
            guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
                return errorPayload(
                    code: "INVALID_ARGUMENT",
                    message: "scrollback_timeout must be a number of seconds",
                    hint: "Use a number between 0 and \(Int(MCPReadRequest.maximumScrollbackSeconds)).",
                    rawStdout: "",
                    rawStderr: "",
                    latencyMs: 0
                )
            }
            scrollbackSeconds = number.doubleValue
        }

        var waitSeconds: [String: Double] = [:]
        for key in ["idle_seconds", "wait_for_idle"] {
            guard let raw = arguments[key], !(raw is NSNull) else { continue }
            guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
                return errorPayload(
                    code: "INVALID_ARGUMENT",
                    message: "\(key) must be a number of seconds",
                    hint: "Use a number between 0 and \(Int(UserActivityPolicy.maximumSeconds)).",
                    rawStdout: "",
                    rawStderr: "",
                    latencyMs: 0
                )
            }
            waitSeconds[key] = number.doubleValue
        }

        let request = MCPReadRequest(
            chat: chat,
            chatID: chatID,
            limit: limit,
            layout: layout,
            deepRecovery: boolValue(arguments["deep_recovery"], defaultValue: deepRecoveryDefault),
            backgroundSafe: boolValue(arguments["background_safe"], defaultValue: backgroundSafeDefault),
            keepWindow: boolValue(arguments["keep_window"], defaultValue: false),
            traceAX: boolValue(arguments["trace_ax"], defaultValue: traceDefault),
            // allow_unread is deprecated and ignored: unread rooms are opened by default.
            skipUnread: boolValue(arguments["skip_unread"], defaultValue: false),
            includeSystem: boolValue(arguments["include_system"], defaultValue: false),
            scrollback: optionalBoolValue(arguments["scrollback"]),
            scrollbackSeconds: scrollbackSeconds,
            idleSeconds: waitSeconds["idle_seconds"],
            waitForIdleSeconds: waitSeconds["wait_for_idle"],
            allowActivate: boolValue(arguments["allow_activate"], defaultValue: false)
        )
        let backgroundSafe = request.backgroundSafe
        let traceAX = request.traceAX

        // `kktcli read` itself keeps automatic work inside the default timeout and closes the
        // window it opened when it is stopped, so there is no retry here.
        let first = runner.run(request.arguments, timeoutSec: request.timeout)

        if first.timedOut {
            return errorPayload(
                code: "PROCESS_TIMEOUT",
                message: "kktcli read timed out after \(Int(request.timeout)) s",
                hint: "Retry; KakaoTalk may be busy.",
                rawStdout: first.stdout,
                rawStderr: first.stderr,
                latencyMs: first.latencyMs
            )
        }

        if first.returncode != 0 {
            let code = MCPErrorMapping.code(returnCode: first.returncode, stdout: first.stdout, stderr: first.stderr)
            let readError = MCPErrorMapping.readError(fromStdout: first.stdout)
            return errorPayload(
                code: code,
                message: readError.map { "kktcli read failed: \($0.message)" } ?? "kktcli read failed",
                hint: readError?.hint ?? MCPErrorMapping.hint(for: code),
                rawStdout: first.stdout,
                rawStderr: first.stderr,
                latencyMs: first.latencyMs,
                details: readError?.details ?? [:]
            )
        }

        guard let payload = jsonObject(from: first.stdout) else {
            return errorPayload(
                code: "INVALID_JSON_OUTPUT",
                message: "kktcli returned non-JSON output for read --json",
                hint: "Run kktcli read manually and confirm JSON-only stdout.",
                rawStdout: first.stdout,
                rawStderr: first.stderr,
                latencyMs: first.latencyMs
            )
        }

        var response: JSONDict = [
            "ok": true,
            "chat": payload["chat"] ?? (chat.isEmpty ? chatID : chat),
            "fetched_at": payload["fetched_at"] as Any,
            "count": payload["count"] ?? 0,
            "messages": payload["messages"] ?? [],
            "meta": [
                "latency_ms": first.latencyMs,
                "layout": layout,
                "background_safe": backgroundSafe,
                // opened_via, window, list_recovery, main_window, scrollback, ... from kktcli
                "read": payload["meta"] ?? NSNull(),
            ],
        ]
        if traceAX, !first.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var meta = response["meta"] as? JSONDict ?? [:]
            meta["stderr_trace"] = first.stderr
            response["meta"] = meta
        }
        return response
    }

    private func sendToolDefinition(name: String, description: String, payloadKey: String, payloadDescription: String) -> [String: Any] {
        [
            "name": name,
            "description": description,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "chat": ["type": "string", "description": "Exact chat name (must be unique; prefer chat_id)"],
                    "chat_id": ["type": "string", "description": "chat_id from kktcli chats"],
                    payloadKey: ["type": "string", "description": payloadDescription],
                    "mode": [
                        "type": "string",
                        "enum": ["preview", "send"],
                        "default": "preview",
                        "description": "preview (default) sends nothing; send sends right away (no dialog), only after the user saw the preview and said 보내",
                    ],
                    "keep_window": ["type": "boolean", "default": false, "description": "Keep the chat window kktcli opened"],
                    "idle_seconds": ["type": "number", "minimum": 0, "maximum": UserActivityPolicy.maximumSeconds, "description": "While KakaoTalk is in front, press nothing until input was idle this long (default 10)"],
                    "wait_for_idle": ["type": "number", "minimum": 0, "maximum": UserActivityPolicy.maximumSeconds, "description": "Seconds to wait for that before KAKAOTALK_IN_USE (default 30)"],
                    "allow_activate": ["type": "boolean", "default": false, "description": "Allow bringing KakaoTalk to the front (hidden main window; Enter fallback). Only with the user's consent."],
                    "trace_ax": ["type": "boolean", "default": traceDefault, "description": "Include AX tracing logs"],
                ],
                "required": [payloadKey],
                "additionalProperties": false,
            ],
        ]
    }

    private func callSend(_ arguments: JSONDict) -> JSONDict {
        callSendTool(arguments, kind: .text, payloadKey: "message")
    }

    private func callSendImage(_ arguments: JSONDict) -> JSONDict {
        callSendTool(arguments, kind: .image, payloadKey: "image_path")
    }

    private func callSendTool(_ arguments: JSONDict, kind: MCPSendRequest.Kind, payloadKey: String) -> JSONDict {
        guard ConfigStore.load().send else {
            return errorPayload(
                code: "SEND_DISABLED",
                message: "Sending is off in kktcli; nothing was sent.",
                hint: "Never enable it on your own. Only if the user asks: kktcli config set send on",
                rawStdout: "",
                rawStderr: "",
                latencyMs: 0
            )
        }
        let chat = (arguments["chat"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let chatID = (arguments["chat_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = (arguments[payloadKey] as? String) ?? ""
        let invalid = { (message: String, hint: String) in
            self.errorPayload(code: "INVALID_ARGUMENT", message: message, hint: hint, rawStdout: "", rawStderr: "", latencyMs: 0)
        }
        guard (chat?.isEmpty == false) != (chatID?.isEmpty == false) else {
            return invalid("Give exactly one of chat and chat_id", "Prefer chat_id from kktcli chats.")
        }
        guard !payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return invalid("\(payloadKey) is required", "Provide \(payloadKey).")
        }
        guard let mode = MCPSendRequest.mode(from: arguments["mode"] as? String) else {
            return invalid("mode must be preview or send", "Use mode=preview first; mode=send only after the user said 보내.")
        }
        var waits: [String: Double] = [:]
        for key in ["idle_seconds", "wait_for_idle"] {
            guard let raw = arguments[key], !(raw is NSNull) else { continue }
            guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
                return invalid("\(key) must be a number of seconds", "Use a number between 0 and \(Int(UserActivityPolicy.maximumSeconds)).")
            }
            waits[key] = number.doubleValue
        }
        let request = MCPSendRequest(
            kind: kind,
            chat: chat,
            chatID: chatID,
            payload: payload,
            mode: mode,
            keepWindow: boolValue(arguments["keep_window"], defaultValue: false),
            traceAX: boolValue(arguments["trace_ax"], defaultValue: traceDefault),
            idleSeconds: waits["idle_seconds"],
            waitForIdleSeconds: waits["wait_for_idle"],
            allowActivate: boolValue(arguments["allow_activate"], defaultValue: false)
        )
        let run = runner.run(request.arguments, timeoutSec: request.timeout)
        if run.timedOut {
            return errorPayload(
                code: "PROCESS_TIMEOUT",
                message: "kktcli \(request.arguments[0]) timed out after \(Int(request.timeout)) s; the dialog may still have been open. Check the room before doing anything else.",
                hint: "Do not send again before checking the room with kktcli_read.",
                rawStdout: run.stdout,
                rawStderr: run.stderr,
                latencyMs: run.latencyMs
            )
        }
        guard let data = run.stdout.data(using: .utf8),
              let report = try? JSONDecoder().decode(SendReport.self, from: data)
        else {
            let code = MCPErrorMapping.code(returnCode: run.returncode, stdout: run.stdout, stderr: run.stderr)
            return errorPayload(code: code, message: "kktcli \(request.arguments[0]) returned no report", hint: MCPErrorMapping.hint(for: code), rawStdout: run.stdout, rawStderr: run.stderr, latencyMs: run.latencyMs)
        }
        var response: JSONDict = [
            "ok": report.ok,
            "mode": report.mode,
            "sent": report.sent,
            "cancelled": report.cancelled,
            "bubble_verified": report.bubbleVerified,
            "meta": ["latency_ms": run.latencyMs, "window": (report.window as Any?) ?? NSNull(), "method": (report.method as Any?) ?? NSNull()] as JSONDict,
        ]
        if let preview = report.preview, let encoded = try? JSONEncoder().encode(preview),
           let object = try? JSONSerialization.jsonObject(with: encoded)
        {
            response["preview"] = object
            response["preview_text"] = preview.humanText
        }
        if let file = report.file { response["file"] = file }
        if let error = report.error {
            response["error"] = ["code": error.code, "message": error.message, "hint": error.hint ?? MCPErrorMapping.hint(for: error.code)]
            response["details"] = report.details
        }
        if request.traceAX, !run.stderr.isEmpty {
            var meta = response["meta"] as? JSONDict ?? [:]
            meta["stderr_trace"] = run.stderr
            response["meta"] = meta
        }
        return response
    }

    private func errorPayload(
        code: String,
        message: String,
        hint: String,
        rawStdout: String,
        rawStderr: String,
        latencyMs: Int,
        details: [String: String] = [:]
    ) -> JSONDict {
        var error: JSONDict = [
            "code": code,
            "message": message,
            "hint": hint,
            "raw_stdout": rawStdout,
            "raw_stderr": rawStderr,
        ]
        if !details.isEmpty {
            error["details"] = details
        }
        return [
            "ok": false,
            "error": error,
            "meta": [
                "latency_ms": latencyMs,
            ],
        ]
    }

    /// nil when the argument is missing, null, or not a recognisable boolean ("automatic").
    private func optionalBoolValue(_ raw: Any?) -> Bool? {
        guard let raw, !(raw is NSNull) else { return nil }
        if let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue
        }
        if let string = raw as? String {
            switch string.lowercased() {
            case "true", "1", "yes":
                return true
            case "false", "0", "no":
                return false
            default:
                return nil
            }
        }
        return nil
    }

    private func boolValue(_ raw: Any?, defaultValue: Bool) -> Bool {
        guard let raw else { return defaultValue }
        if let bool = raw as? Bool { return bool }
        if let number = raw as? NSNumber { return number.boolValue }
        if let string = raw as? String {
            switch string.lowercased() {
            case "true", "1", "yes":
                return true
            case "false", "0", "no":
                return false
            default:
                return defaultValue
            }
        }
        return defaultValue
    }

    private static func validReadLayout(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "preserve", "left", "right", "split-left", "split-right":
            return normalized
        default:
            return nil
        }
    }

    private func jsonObject(from string: String) -> JSONDict? {
        guard let data = string.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? JSONDict
        else {
            return nil
        }
        return dict
    }

    private func prettyJSONString(_ object: JSONDict) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return string
    }

    private func jsonRPCResult(id: Any, result: JSONDict) -> JSONDict {
        [
            "jsonrpc": "2.0",
            "id": id,
            "result": result,
        ]
    }

    private func jsonRPCError(id: Any, code: Int, message: String, data: JSONDict = [:]) -> JSONDict {
        var payload: JSONDict = [
            "jsonrpc": "2.0",
            "id": id,
            "error": [
                "code": code,
                "message": message,
            ],
        ]
        if !data.isEmpty {
            payload["error"] = [
                "code": code,
                "message": message,
                "data": data,
            ]
        }
        return payload
    }

    private func readMessage() -> JSONDict? {
        var headers: [String: String] = [:]

        while true {
            guard let line = readHeaderLine() else { return nil }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if headers.isEmpty, trimmed.hasPrefix("{") {
                responseTransport = .newlineDelimitedJSON
                return jsonObject(from: Data(line.utf8))
            }

            if line == "\r\n" || line == "\n" {
                break
            }

            if trimmed.isEmpty {
                continue
            }

            let parts = trimmed.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            headers[parts[0].trimmingCharacters(in: .whitespaces).lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
        }

        guard let lengthString = headers["content-length"],
              let contentLength = Int(lengthString),
              contentLength > 0,
              let body = readExact(contentLength)
        else {
            return nil
        }
        responseTransport = .contentLength

        return jsonObject(from: body)
    }

    private func jsonObject(from data: Data) -> JSONDict? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? JSONDict
        else {
            return nil
        }
        return dict
    }

    private func readHeaderLine() -> String? {
        var bytes: [UInt8] = []
        while true {
            let char = getchar()
            if char == EOF {
                return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
            }
            bytes.append(UInt8(char))
            if char == 10 {
                return String(decoding: bytes, as: UTF8.self)
            }
        }
    }

    private func readExact(_ count: Int) -> Data? {
        var buffer = [UInt8](repeating: 0, count: count)
        let readCount = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
            guard let baseAddress = rawBuffer.baseAddress else { return 0 }
            return fread(baseAddress, 1, count, stdin)
        }
        guard readCount == count else { return nil }
        return Data(buffer)
    }

    private func writeMessage(_ payload: JSONDict) throws {
        let encoded = try JSONSerialization.data(withJSONObject: payload, options: [])
        switch responseTransport {
        case .contentLength:
            try writeContentLengthMessage(encoded)
        case .newlineDelimitedJSON:
            writeNewlineDelimitedJSONMessage(encoded)
        }
    }

    private func writeContentLengthMessage(_ encoded: Data) throws {
        let header = "Content-Length: \(encoded.count)\r\n\r\n"
        header.utf8CString.withUnsafeBufferPointer { buffer in
            _ = fwrite(buffer.baseAddress, 1, buffer.count - 1, stdout)
        }
        encoded.withUnsafeBytes { rawBuffer in
            if let baseAddress = rawBuffer.baseAddress {
                _ = fwrite(baseAddress, 1, encoded.count, stdout)
            }
        }
        fflush(stdout)
    }

    private func writeNewlineDelimitedJSONMessage(_ encoded: Data) {
        encoded.withUnsafeBytes { rawBuffer in
            if let baseAddress = rawBuffer.baseAddress {
                _ = fwrite(baseAddress, 1, encoded.count, stdout)
            }
        }
        var newline = UInt8(ascii: "\n")
        _ = fwrite(&newline, 1, 1, stdout)
        fflush(stdout)
    }
}

struct MCPServerCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp-server",
        abstract: "Run the stdio MCP server for kktcli integrations",
        discussion: """
            Starts the local stdio MCP server for OpenClaw and similar clients.

            Examples:
              kktcli mcp-server
              KKTCLI_TRACE_DEFAULT=true kktcli mcp-server
            """
    )

    func run() throws {
        let server = KktcliMCPServer()
        try server.serveForever()
    }
}
