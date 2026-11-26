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
    /// `--idle-seconds` / `--wait-for-idle` (nil = kktcli's defaults, 10 s / 30 s).
    public var idleSeconds: Double?
    public var waitForIdleSeconds: Double?
    /// `--allow-activate`: bring KakaoTalk to the front when its main window is not visible.
    public var allowActivate: Bool
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
        scrollbackSeconds: Double? = nil,
        idleSeconds: Double? = nil,
        waitForIdleSeconds: Double? = nil,
        allowActivate: Bool = false
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
        self.idleSeconds = idleSeconds
        self.waitForIdleSeconds = waitForIdleSeconds
        self.allowActivate = allowActivate
    }

    /// Bounded like the CLI options (0–600 s).
    private static func boundedSeconds(_ seconds: Double) -> Double {
        min(max(0, seconds), UserActivityPolicy.maximumSeconds)
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
        if let idleSeconds {
            arguments += ["--idle-seconds", Self.format(Self.boundedSeconds(idleSeconds))]
        }
        if let waitForIdleSeconds {
            arguments += ["--wait-for-idle", Self.format(Self.boundedSeconds(waitForIdleSeconds))]
        }
        if allowActivate { arguments.append("--allow-activate") }
        return arguments
    }

    /// 8 s (15 s with deep recovery), extended by the scrollback budget only when scrollback
    /// was requested explicitly, and always by the wait for an idle user (`wait_for_idle`).
    public var timeout: Double {
        var timeout = deepRecovery ? Self.deepRecoveryTimeout : Self.defaultTimeout
        timeout += Self.boundedSeconds(waitForIdleSeconds ?? UserActivityPolicy.defaultWaitSeconds)
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
        case "KAKAOTALK_IN_USE":
            return "KakaoTalk was in front and in use for the whole wait, so nothing was pressed (a window opened then would take the user's typing). Retry later, or raise wait_for_idle."
        case "MAIN_WINDOW_NOT_VISIBLE":
            return "KakaoTalk's main window is closed, minimised, or on another desktop or full-screen Space, and reopening it would bring KakaoTalk to the front. Ask the user to show KakaoTalk, or retry with allow_activate=true only if they agree to KakaoTalk coming to the front."
        case "OPEN_CHAT_LIST":
            return "This open-chat row opens a list of 1:1 open-chat conversations, not a chat; reading those is not supported. The list window was closed."
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

/// How the MCP tools `kktcli_send` / `kktcli_send_image` turn their arguments into a
/// `kktcli send` / `send-image` invocation. `mode` "preview" (the default) never sends;
/// "send" opens the confirmation dialog on the user's screen and waits for it.
public struct MCPSendRequest: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case text
        case image
    }

    public enum Mode: String, Sendable {
        case preview
        case send
    }

    /// The dialog cancels itself after 120 s; the call waits at least this long.
    public static let minimumSendTimeout: Double = 130
    public static let previewTimeout: Double = 20

    public var kind: Kind
    public var chat: String?
    public var chatID: String?
    /// The message (text) or the image path (image).
    public var payload: String
    public var mode: Mode
    public var keepWindow: Bool
    public var traceAX: Bool
    public var idleSeconds: Double?
    public var waitForIdleSeconds: Double?
    public var allowActivate: Bool

    public init(
        kind: Kind,
        chat: String? = nil,
        chatID: String? = nil,
        payload: String,
        mode: Mode = .preview,
        keepWindow: Bool = false,
        traceAX: Bool = false,
        idleSeconds: Double? = nil,
        waitForIdleSeconds: Double? = nil,
        allowActivate: Bool = false
    ) {
        self.kind = kind
        self.chat = chat
        self.chatID = chatID
        self.payload = payload
        self.mode = mode
        self.keepWindow = keepWindow
        self.traceAX = traceAX
        self.idleSeconds = idleSeconds
        self.waitForIdleSeconds = waitForIdleSeconds
        self.allowActivate = allowActivate
    }

    /// `mode` from the tool arguments: nil or "preview" → preview, "send" → send, anything
    /// else invalid.
    public static func mode(from raw: String?) -> Mode? {
        guard let raw else { return .preview }
        return Mode(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    private static func bounded(_ seconds: Double) -> Double {
        min(max(0, seconds), UserActivityPolicy.maximumSeconds)
    }

    public var arguments: [String] {
        var arguments = [kind == .text ? "send" : "send-image"]
        if let chatID, !chatID.isEmpty {
            arguments += ["--chat-id", chatID, payload]
        } else {
            arguments += [chat ?? "", payload]
        }
        arguments.append("--json")
        if mode == .preview { arguments.append("--preview") }
        if keepWindow { arguments.append("--keep-window") }
        if traceAX { arguments.append("--trace-ax") }
        if let idleSeconds { arguments += ["--idle-seconds", Self.format(Self.bounded(idleSeconds))] }
        if let waitForIdleSeconds { arguments += ["--wait-for-idle", Self.format(Self.bounded(waitForIdleSeconds))] }
        if allowActivate { arguments.append("--allow-activate") }
        return arguments
    }

    /// Preview: 20 s; send: at least 130 s (the dialog's 120 s plus margin). Both are extended
    /// by the wait for an idle user.
    public var timeout: Double {
        let wait = Self.bounded(waitForIdleSeconds ?? UserActivityPolicy.defaultWaitSeconds)
        return (mode == .send ? Self.minimumSendTimeout : Self.previewTimeout) + wait
    }

    private static func format(_ seconds: Double) -> String {
        seconds == seconds.rounded() ? String(Int(seconds)) : String(seconds)
    }
}
