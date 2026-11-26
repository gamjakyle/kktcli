import Foundation
import Testing
@testable import KktcliCore

@Suite("MCP: read invocation, timeouts and error codes")
struct MCPMappingTests {
    @Test("Defaults: JSON read, no extra flags; 8 s plus the 30 s wait for an idle user")
    func defaults() {
        let request = MCPReadRequest(chat: "가족")
        #expect(request.arguments == ["read", "가족", "--json", "--limit", "20", "--layout", "preserve"])
        #expect(!request.skipUnread)
        #expect(!request.arguments.contains("--skip-unread"))
        #expect(!request.arguments.contains("--allow-unread"))
        #expect(!request.arguments.contains("--allow-activate"))
        #expect(request.timeout == 8 + 30)
        #expect(MCPReadRequest(chat: "가족", deepRecovery: true).timeout == 15 + 30)
    }

    @Test("idle_seconds, wait_for_idle and allow_activate map to read flags and the timeout")
    func activityOptions() {
        let request = MCPReadRequest(chat: "가족", idleSeconds: 5, waitForIdleSeconds: 0, allowActivate: true)
        #expect(request.arguments.suffix(5) == ["--idle-seconds", "5", "--wait-for-idle", "0", "--allow-activate"])
        // Failing at once (wait 0) keeps the plain 8 s call timeout.
        #expect(request.timeout == 8)
        let capped = MCPReadRequest(chat: "가족", idleSeconds: 9999, waitForIdleSeconds: 9999)
        #expect(capped.arguments.contains("600"))
        #expect(capped.timeout == 8 + 600)
        #expect(MCPReadRequest(chat: "가족", waitForIdleSeconds: 12.5).timeout == 8 + 12.5)
    }

    @Test("chat_id wins over a name, and the limit is bounded")
    func chatIDAndLimit() {
        let request = MCPReadRequest(chat: "", chatID: "chat_1", limit: 100_000)
        #expect(request.arguments.prefix(3) == ["read", "--chat-id", "chat_1"])
        #expect(request.arguments.contains(String(MCPReadRequest.maximumLimit)))
        #expect(MCPReadRequest(chat: "x", limit: 0).boundedLimit == 1)
    }

    @Test("skip_unread, include_system and scrollback map to read flags")
    func newReadOptions() {
        let request = MCPReadRequest(chat: "가족", skipUnread: true, includeSystem: true, scrollback: true, scrollbackSeconds: 10)
        #expect(request.arguments.contains("--skip-unread"))
        #expect(!request.arguments.contains("--allow-unread"))
        #expect(request.arguments.contains("--include-system"))
        #expect(request.arguments.contains("--scrollback"))
        #expect(request.arguments.suffix(2) == ["--scrollback-timeout", "10"])
        // Explicit scrollback extends the call timeout by its budget plus a margin.
        #expect(request.timeout == 8 + 30 + 10 + 2)

        let off = MCPReadRequest(chat: "가족", scrollback: false)
        #expect(off.arguments.contains("--no-scrollback"))
        #expect(off.timeout == 8 + 30)

        let automatic = MCPReadRequest(chat: "가족", scrollbackSeconds: 2.5)
        #expect(!automatic.arguments.contains("--scrollback"))
        #expect(!automatic.arguments.contains("--no-scrollback"))
        #expect(automatic.arguments.suffix(2) == ["--scrollback-timeout", "2.5"])
        #expect(automatic.timeout == 8 + 30)

        let capped = MCPReadRequest(chat: "가족", scrollback: true, scrollbackSeconds: 999)
        #expect(capped.arguments.suffix(2) == ["--scrollback-timeout", "60"])
        #expect(capped.timeout == 8 + 30 + 60 + 2)
    }

    @Test("Send tools: preview by default; send without a dialog")
    func sendRequests() {
        let preview = MCPSendRequest(kind: .text, chatID: "chat_1", payload: "내일 3시 회의실 A")
        #expect(preview.arguments == ["send", "--chat-id", "chat_1", "내일 3시 회의실 A", "--json", "--preview"])
        #expect(preview.timeout == 20 + 30)
        let send = MCPSendRequest(kind: .text, chat: "테스트방", payload: "확인했어요", mode: .send, waitForIdleSeconds: 0)
        #expect(send.arguments == ["send", "테스트방", "확인했어요", "--json", "--wait-for-idle", "0"])
        #expect(send.timeout == 40)
        #expect(MCPSendRequest(kind: .text, payload: "a", mode: .send).timeout == 40 + 30)
        let image = MCPSendRequest(kind: .image, chatID: "chat_2", payload: "/tmp/a.png", mode: .send, allowActivate: true)
        #expect(image.arguments == ["send-image", "--chat-id", "chat_2", "/tmp/a.png", "--json", "--allow-activate"])
        #expect(MCPSendRequest.mode(from: nil) == .preview)
        #expect(MCPSendRequest.mode(from: "Send") == .send)
        #expect(MCPSendRequest.mode(from: "now") == nil)
    }

    @Test("read --json error documents keep their own code, message, hint and details")
    func readErrorDocument() {
        let stdout = """
        {"chat":"가족","chat_id":null,"details":{"unread_before":"안읽음 2"},"error":{"code":"UNREAD_REFUSED","hint":"Run without --skip-unread to open it; that sends read receipts like opening it by hand.","message":"'가족' shows unread messages"},"ok":false}
        """
        #expect(MCPErrorMapping.code(returnCode: 3, stdout: stdout, stderr: "") == "UNREAD_REFUSED")
        let parsed = MCPErrorMapping.readError(fromStdout: stdout)
        #expect(parsed?.message == "'가족' shows unread messages")
        #expect(parsed?.hint == "Run without --skip-unread to open it; that sends read receipts like opening it by hand.")
        #expect(parsed?.details == ["unread_before": "안읽음 2"])

        for code in ["UNREAD_UNVERIFIED", "CHAT_NOT_IN_LIST", "CHAT_WINDOW_NOT_OPENED", "MENU_UNAVAILABLE", "MENU_ITEM_MISSING", "ROW_CHANGED", "KAKAOTALK_IN_USE", "MAIN_WINDOW_NOT_VISIBLE", "OPEN_CHAT_LIST"] {
            let document = #"{"ok":false,"error":{"code":"\#(code)","message":"m","hint":null}}"#
            #expect(MCPErrorMapping.code(returnCode: 1, stdout: document, stderr: "") == code)
            #expect(MCPErrorMapping.hint(for: code) != MCPErrorMapping.hint(for: "SOMETHING_ELSE"))
        }
    }

    @Test("Text failures: launch failure, frontmost guard, legacy markers")
    func textFailures() {
        #expect(MCPErrorMapping.code(returnCode: 127, stdout: "", stderr: "launch failed") == "KKTCLI_BIN_NOT_FOUND")
        // A message that merely says "not found" is not a missing binary.
        #expect(MCPErrorMapping.code(returnCode: 1, stdout: "Failed: UI element not found", stderr: "") == "UNKNOWN_EXEC_FAILURE")
        #expect(MCPErrorMapping.code(returnCode: 1, stdout: "Failed to send message: [NOT_FRONTMOST] KakaoTalk is not the frontmost app", stderr: "") == "NOT_FRONTMOST")
        #expect(MCPErrorMapping.code(returnCode: 1, stdout: "[FOCUS_FAIL] Could not focus search field", stderr: "") == "KAKAO_SEARCH_FOCUS_FAILED")
        #expect(MCPErrorMapping.code(returnCode: 1, stdout: "[SEARCH_MISS] No search result", stderr: "") == "CHAT_NOT_FOUND")
        #expect(MCPErrorMapping.code(returnCode: 1, stdout: "", stderr: "[WINDOW_NOT_READY] Usable KakaoTalk window unavailable") == "KAKAO_WINDOW_UNAVAILABLE")
        #expect(MCPErrorMapping.hint(for: "UNREAD_REFUSED").contains("skip_unread"))
        #expect(MCPErrorMapping.hint(for: "UNREAD_REFUSED").contains("read receipts"))
        #expect(!MCPErrorMapping.hint(for: "UNREAD_UNVERIFIED").contains("allow_unread"))
    }
}
