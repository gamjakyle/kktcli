import Foundation

/// How the MCP tool `kktcli_read` turns its arguments into a `kktcli read` invocation.
public struct MCPReadRequest: Equatable, Sendable {
    /// Seconds before the MCP server stops waiting for `kktcli read` (deep recovery: 15).
    public static let defaultTimeout: Double = 8
    public static let deepRecoveryTimeout: Double = 15
    /// Default `--scrollback-timeout` of `kktcli read`.
    public static let defaultScrollbackSeconds: Double = 4
    public static let maximumLimit = 500
    public static let maximumScrollbackSeconds: Double = 60

    public var chat: String?
    public var chatID: String?
    public var limit: Int
    public var layout: String
    public var deepRecovery: Bool
    public var backgroundSafe: Bool
    public var keepWindow: Bool
    public var traceAX: Bool
    /// `--skip-unread`: leave a room unopened when its chat-list row shows unread messages.
    /// (The tool's old `allow_unread` argument is accepted and ignored by the server.)
    public var skipUnread: Bool
    public var includeSystem: Bool
    /// nil = automatic (only when fewer than `limit` messages are loaded; the CLI keeps it
    /// inside the default timeout), true = `--scrollback`, false = `--no-scrollback`.
    public var scrollback: Bool?
    public var scrollbackSeconds: Double?

    public init(
        chat: String? = nil,
        chatID: String? = nil,
        limit: Int = 20,
        layout: String = "preserve",
        deepRecovery: Bool = false,
        backgroundSafe: Bool = false,
        keepWindow: Bool = false,
        traceAX: Bool = false,
        skipUnread: Bool = false,
        includeSystem: Bool = false,
        scrollback: Bool? = nil,
        scrollbackSeconds: Double? = nil
    ) {
        self.chat = chat
        self.chatID = chatID
        self.limit = limit
        self.layout = layout
        self.deepRecovery = deepRecovery
        self.backgroundSafe = backgroundSafe
        self.keepWindow = keepWindow
        self.traceAX = traceAX
        self.skipUnread = skipUnread
        self.includeSystem = includeSystem
        self.scrollback = scrollback
        self.scrollbackSeconds = scrollbackSeconds
    }

    public var boundedLimit: Int {
        max(1, min(limit, Self.maximumLimit))
    }

    public var arguments: [String] {
        var arguments = ["read"]
        if let chatID, !chatID.isEmpty {
            arguments += ["--chat-id", chatID]
        } else {
            arguments.append(chat ?? "")
        }
        arguments += ["--json", "--limit", String(boundedLimit), "--layout", layout]
        if deepRecovery { arguments.append("--deep-recovery") }
        if backgroundSafe { arguments.append("--background-safe") }
        if keepWindow { arguments.append("--keep-window") }
        if traceAX { arguments.append("--trace-ax") }
        if skipUnread { arguments.append("--skip-unread") }
        if includeSystem { arguments.append("--include-system") }
        switch scrollback {
        case .some(true):
            arguments.append("--scrollback")
        case .some(false):
            arguments.append("--no-scrollback")
        case .none:
            break
        }
        if let scrollbackSeconds {
            arguments += ["--scrollback-timeout", Self.format(min(max(0, scrollbackSeconds), Self.maximumScrollbackSeconds))]
        }
        return arguments
    }

    /// 8 s (15 s with deep recovery), extended by the scrollback budget only when scrollback
    /// was requested explicitly.
    public var timeout: Double {
        var timeout = deepRecovery ? Self.deepRecoveryTimeout : Self.defaultTimeout
        if scrollback == true {
            let seconds = min(max(0, scrollbackSeconds ?? Self.defaultScrollbackSeconds), Self.maximumScrollbackSeconds)
            timeout += seconds + 2
        }
        return timeout
    }

    private static func format(_ seconds: Double) -> String {
        seconds == seconds.rounded() ? String(Int(seconds)) : String(seconds)
    }
}

/// Error codes the MCP server reports for a failed kktcli subprocess.
public enum MCPErrorMapping {
    /// The runner reports a process that could not be launched with this status.
    public static let launchFailureStatus: Int32 = 127

    public struct ReadError: Equatable, Sendable {
        public var code: String
        public var message: String
        public var hint: String?
        public var details: [String: String]
    }

    /// `kktcli read --json` prints {"ok": false, "error": {"code", "message", "hint"}, ...}.
    public static func readError(fromStdout stdout: String) -> ReadError? {
        guard
            let data = stdout.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            object["ok"] as? Bool == false,
            let error = object["error"] as? [String: Any],
            let code = error["code"] as? String,
            !code.isEmpty
        else {
            return nil
        }
        return ReadError(
            code: code,
            message: error["message"] as? String ?? "",
            hint: error["hint"] as? String,
            details: object["details"] as? [String: String] ?? [:]
        )
    }

    public static func code(returnCode: Int32, stdout: String, stderr: String) -> String {
        if returnCode == launchFailureStatus {
            return "KKTCLI_BIN_NOT_FOUND"
        }
        if let readError = readError(fromStdout: stdout) {
            return readError.code
        }
        let combinedText = "\(stdout)\n\(stderr)"
        if combinedText.contains("NOT_FRONTMOST") {
            return "NOT_FRONTMOST"
        }
        if combinedText.contains("WINDOW_NOT_READY") {
            return "KAKAO_WINDOW_UNAVAILABLE"
        }
        if combinedText.contains("SEARCH_MISS") {
            return "CHAT_NOT_FOUND"
        }
        if combinedText.contains("FOCUS_FAIL") {
            return "KAKAO_SEARCH_FOCUS_FAILED"
        }
        if combinedText.contains("Accessibility") || combinedText.contains("손쉬운 사용") {
            return "ACCESSIBILITY_PERMISSION_DENIED"
        }
        return "UNKNOWN_EXEC_FAILURE"
    }

    public static func hint(for code: String) -> String {
        switch code {
        case "KKTCLI_BIN_NOT_FOUND":
            return "The kktcli binary could not be launched; check that it exists and is executable."
        case "UNREAD_REFUSED":
            return "skip_unread=true left the room unopened because it shows unread messages. Reading it with skip_unread=false (the default) opens it, which sends read receipts like opening it by hand."
        case "UNREAD_UNVERIFIED":
            return "skip_unread=true left the room unopened because its chat-list row could not be read completely. Retry, or read it with skip_unread=false (the default), which sends read receipts if there are unread messages."
        case "CHAT_NOT_IN_LIST":
            return "No chat-list row matched. Check the exact name or chat_id with `kktcli chats`."
        case "AMBIGUOUS_CHAT":
            return "Several chats match equally well; use the exact name or a chat_id."
        case "UNKNOWN_CHAT_ID":
            return "The chat_id is not in the local registry; run `kktcli chats` to refresh it."
        case "CHAT_WINDOW_NOT_OPENED":
            return "The chat window did not appear after 채팅방 열기; retry, and check KakaoTalk for a dialog."
        case "MENU_UNAVAILABLE", "MENU_ITEM_MISSING", "MENU_ITEM_BLOCKED":
            return "The chat-list context menu could not be used. Retry, or open the chat yourself and read it with background_safe=true."
        case "ROW_CHANGED":
            return "The chat list reordered while the room was being opened (new messages move rooms up); retry."
        case "ROW_NOT_VISIBLE":
            return "The row could not be scrolled into view; make KakaoTalk's main window larger and retry."
        case "CHAT_LIST_UNAVAILABLE", "WINDOW_NOT_READY", "KAKAO_WINDOW_UNAVAILABLE":
            return "KakaoTalk's main window or chat list is not available. Open KakaoTalk on the 채팅 tab and retry (deep_recovery=true may reopen it, which activates KakaoTalk)."
        case "MAIN_WINDOW_MINIMIZED", "KAKAO_HIDDEN":
            return "KakaoTalk's main window is minimized or hidden; restore it (it may stay in the background) and retry."
        case "BACKGROUND_SAFE_BLOCKED":
            return "background_safe=true only reads chat windows that are already open."
        case "TRANSCRIPT_UNAVAILABLE":
            return "The chat window has no readable transcript."
        case "NOT_FRONTMOST":
            return "KakaoTalk was not the frontmost app, so no keystrokes were posted. Bring KakaoTalk to the front and retry."
        case "CHAT_NOT_FOUND":
            return "Chat was not found in search results. Verify chat name spacing and visibility."
        case "KAKAO_SEARCH_FOCUS_FAILED":
            return "KakaoTalk search input could not be focused. Open KakaoTalk, ensure the chat list is visible, then retry with deep_recovery=true."
        case "ACCESSIBILITY_PERMISSION_DENIED":
            return "Grant Accessibility permission in System Settings > Privacy & Security > Accessibility."
        case "KAKAO_NOT_RUNNING", "KAKAO_LAUNCH_FAILED", "KAKAO_UNAVAILABLE", "KAKAO_AUTH_FAILED":
            return "KakaoTalk is not running or not logged in; start it and log in, then retry."
        case "INTERRUPTED":
            return "The read was interrupted; retry."
        default:
            return "Check raw_stdout/raw_stderr and rerun with trace_ax=true for details."
        }
    }
}
