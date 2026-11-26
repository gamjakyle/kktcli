import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
MCP_SERVER_COMMAND = REPO_ROOT / "Sources" / "kktcli" / "Commands" / "MCPServerCommand.swift"
MCP_MAPPING = REPO_ROOT / "Sources" / "KktcliCore" / "MCPMapping.swift"


class MCPServerContractTests(unittest.TestCase):
    def test_startup_status_check_allows_slow_ax_ready_state(self) -> None:
        source = MCP_SERVER_COMMAND.read_text(encoding="utf-8")
        self.assertIn('run(["status"], timeoutSec: 15.0)', source)

    def test_subprocess_readers_start_after_successful_launch(self) -> None:
        source = MCP_SERVER_COMMAND.read_text(encoding="utf-8")
        run_index = source.index("try process.run()")
        stdout_reader_index = source.index("let stdoutData = MCPDataBuffer()")
        self.assertLess(run_index, stdout_reader_index)

    def test_mcp_server_accepts_content_length_and_ndjson(self) -> None:
        source = MCP_SERVER_COMMAND.read_text(encoding="utf-8")
        self.assertIn("enum MCPStdioTransport", source)
        self.assertIn("case contentLength", source)
        self.assertIn("case newlineDelimitedJSON", source)
        self.assertIn('trimmed.hasPrefix("{")', source)
        self.assertIn("writeContentLengthMessage", source)
        self.assertIn("writeNewlineDelimitedJSONMessage", source)

    def test_server_and_tools_are_named_kktcli(self) -> None:
        source = MCP_SERVER_COMMAND.read_text(encoding="utf-8")
        for name in ('"name": "kktcli"', '"kktcli_read"', '"kktcli_send"', '"kktcli_send_image"'):
            self.assertIn(name, source)
        self.assertNotIn("kmsg", source)

    def test_read_tool_exposes_unread_and_scrollback_options(self) -> None:
        source = MCP_SERVER_COMMAND.read_text(encoding="utf-8")
        mapping = MCP_MAPPING.read_text(encoding="utf-8")
        for option in ('"skip_unread"', '"scrollback"', '"scrollback_timeout"', '"include_system"'):
            self.assertIn(option, source)
        for flag in ('"--skip-unread"', '"--scrollback"', '"--no-scrollback"', '"--scrollback-timeout"'):
            self.assertIn(flag, mapping)
        # Unread rooms are opened by default; allow_unread stays in the schema (the schema has
        # additionalProperties: false) but is ignored and never turned into a flag.
        self.assertIn('skipUnread: boolValue(arguments["skip_unread"], defaultValue: false)', source)
        self.assertIn('"allow_unread"', source)
        self.assertIn("Deprecated and ignored", source)
        self.assertNotIn('arguments["allow_unread"]', source)
        self.assertNotIn('"--allow-unread"', mapping)
        # The 8 s call timeout (15 s with deep recovery) is kept and only extended for an
        # explicit scrollback request.
        self.assertIn("defaultTimeout: Double = 8", mapping)
        self.assertIn("deepRecoveryTimeout: Double = 15", mapping)
        self.assertIn("timeoutSec: request.timeout", source)

    def test_send_tools_preview_by_default_and_never_send_without_the_dialog(self) -> None:
        source = MCP_SERVER_COMMAND.read_text(encoding="utf-8")
        mapping = MCP_MAPPING.read_text(encoding="utf-8")
        self.assertNotIn('"confirm"', source)
        self.assertNotIn("CONFIRMATION_REQUIRED", source)
        self.assertIn('"enum": ["preview", "send"]', source)
        self.assertIn('"default": "preview"', source)
        self.assertIn("MCPSendRequest.mode(from: arguments[\"mode\"] as? String)", source)
        for key in ('"sent": report.sent', '"cancelled": report.cancelled', '"bubble_verified": report.bubbleVerified'):
            self.assertIn(key, source)
        self.assertIn("public static let minimumSendTimeout: Double = 130", mapping)
        self.assertIn('if mode == .preview { arguments.append("--preview") }', mapping)
        # The drafting rules and the explicit 보내 are in the server instructions.
        for text in ("verbatim", "never add facts", "at most 3 lines", "mode=preview first", "explicit 보내", "never send in bulk"):
            self.assertIn(text, source)

    def test_read_errors_keep_the_codes_kktcli_reports(self) -> None:
        source = MCP_SERVER_COMMAND.read_text(encoding="utf-8")
        mapping = MCP_MAPPING.read_text(encoding="utf-8")
        self.assertIn("MCPErrorMapping.readError(fromStdout: first.stdout)", source)
        self.assertIn("MCPErrorMapping.code(returnCode:", source)
        for code in (
            '"UNREAD_REFUSED"',
            '"UNREAD_UNVERIFIED"',
            '"CHAT_NOT_IN_LIST"',
            '"CHAT_WINDOW_NOT_OPENED"',
            '"MENU_UNAVAILABLE"',
            '"MENU_ITEM_MISSING"',
            '"NOT_FRONTMOST"',
        ):
            self.assertIn(code, mapping)

    def test_focus_fail_has_actionable_mcp_error_code(self) -> None:
        mapping = MCP_MAPPING.read_text(encoding="utf-8")
        self.assertIn('combinedText.contains("FOCUS_FAIL")', mapping)
        self.assertIn('"KAKAO_SEARCH_FOCUS_FAILED"', mapping)
        self.assertIn("search input could not be focused", mapping)


if __name__ == "__main__":
    unittest.main()
