import Foundation
import Testing
@testable import KktcliCore

@Suite("MCP: read invocation, timeouts and error codes")
struct MCPMappingTests {
    @Test("Defaults: JSON read with an 8 s call timeout, no extra flags (unread rooms are opened)")
    func defaults() {
        let request = MCPReadRequest(chat: "가족")
        #expect(request.arguments == ["read", "가족", "--json", "--limit", "20", "--layout", "preserve"])
        #expect(!request.skipUnread)
        #expect(!request.arguments.contains("--skip-unread"))
        #expect(!request.arguments.contains("--allow-unread"))
        #expect(request.timeout == 8)
        #expect(MCPReadRequest(chat: "가족", deepRecovery: true).timeout == 15)
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
        #expect(request.timeout == 8 + 10 + 2)

        let off = MCPReadRequest(chat: "가족", scrollback: false)
        #expect(off.arguments.contains("--no-scrollback"))
        #expect(off.timeout == 8)

        let automatic = MCPReadRequest(chat: "가족", scrollbackSeconds: 2.5)
        #expect(!automatic.arguments.contains("--scrollback"))
        #expect(!automatic.arguments.contains("--no-scrollback"))
        #expect(automatic.arguments.suffix(2) == ["--scrollback-timeout", "2.5"])
        #expect(automatic.timeout == 8)

        let capped = MCPReadRequest(chat: "가족", scrollback: true, scrollbackSeconds: 999)
        #expect(capped.arguments.suffix(2) == ["--scrollback-timeout", "60"])
        #expect(capped.timeout == 8 + 60 + 2)
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

        for code in ["UNREAD_UNVERIFIED", "CHAT_NOT_IN_LIST", "CHAT_WINDOW_NOT_OPENED", "MENU_UNAVAILABLE", "MENU_ITEM_MISSING", "ROW_CHANGED"] {
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
