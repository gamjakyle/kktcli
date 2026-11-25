import re
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SOURCES = REPO_ROOT / "Sources"
GUARD = SOURCES / "kktcli" / "KakaoTalk" / "UserActivityGuard.swift"
ACCESS = SOURCES / "kktcli" / "KakaoTalk" / "MainWindowAccess.swift"
OPENER = SOURCES / "kktcli" / "KakaoTalk" / "ChatRoomMenuOpener.swift"
FETCHER = SOURCES / "kktcli" / "KakaoTalk" / "FullTextFetcher.swift"
LOCATOR = SOURCES / "kktcli" / "KakaoTalk" / "ChatListLocator.swift"
READ_COMMAND = SOURCES / "kktcli" / "Commands" / "ReadCommand.swift"
CHATS_COMMAND = SOURCES / "kktcli" / "Commands" / "ChatsCommand.swift"
MCP_SERVER = SOURCES / "kktcli" / "Commands" / "MCPServerCommand.swift"
MCP_MAPPING = SOURCES / "KktcliCore" / "MCPMapping.swift"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


class UserActivityContractTests(unittest.TestCase):
    def test_idle_time_comes_from_the_hid_state_without_permission(self) -> None:
        guard = read(GUARD)
        self.assertIn("CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)", guard)
        self.assertIn('code: "KAKAOTALK_IN_USE"', guard)
        self.assertIn("exitCode: UserActivityPolicy.inUseExitCode", guard)

    def test_window_opening_presses_wait_and_are_rechecked_right_before(self) -> None:
        opener = read(OPENER)
        self.assertIn("try activity.waitUntilClear(.openChatRoom)", opener)
        recheck = opener.index("guard activity.mayPressNow(.openChatRoom) else {")
        press = opener.index("AXNodeReader.perform(item.element, kAXPressAction)")
        self.assertLess(recheck, press)
        self.assertLess(opener.index("try activity.waitUntilClear(.openChatRoom)"), opener.index('AXNodeReader.perform(cell, "AXShowMenu")'))

        fetcher = read(FETCHER)
        self.assertIn("try activity.waitUntilClear(.seeAll)", fetcher)
        self.assertLess(fetcher.index("guard activity.mayPressNow(.seeAll) else {"), fetcher.index("target.control, kAXPressAction"))

        locator = read(LOCATOR)
        body = locator[locator.index("func pressShowMainWindowMenuItem(beforePress: () -> Bool) -> MainWindowPress {"):]
        self.assertLess(body.index("guard beforePress() else {"), body.index("AXNodeReader.perform(item.element, kAXPressAction)"))

    def test_main_window_is_reopened_only_in_front_or_with_allow_activate(self) -> None:
        access = read(ACCESS)
        self.assertIn("MainWindowPolicy.decide(kakaoTalkFrontmost: frontmost, allowActivate: allowActivate) == .reopen", access)
        self.assertIn("try activity.waitUntilClear(.showMainWindow)", access)
        self.assertIn('code: "MAIN_WINDOW_NOT_VISIBLE"', access)
        for key in ("kakao_frontmost", "ax_window_count", "cg_layer0_window_count", "cg_layer0_offscreen_count"):
            self.assertIn(f'"{key}"', access)
        self.assertIn("CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID)", access)
        # 카카오톡 열기 is only pressed through MainWindowAccess.
        for path in (READ_COMMAND, CHATS_COMMAND):
            self.assertNotIn("pressShowMainWindowMenuItem(", read(path))
        self.assertIn("try mainWindowAccess.reopen(kakao: early, locator: earlyLocator)", read(READ_COMMAND))
        self.assertIn("try mainWindowAccess.reopen(kakao: early, locator: earlyLocator)", read(CHATS_COMMAND))
        self.assertIn("try access.reopen(kakao: kakao, locator: self)", read(LOCATOR))

    def test_options_meta_and_batch(self) -> None:
        for path in (READ_COMMAND, CHATS_COMMAND):
            source = read(path)
            self.assertIn("var idleSeconds: Double = UserActivityPolicy.defaultIdleSeconds", source)
            self.assertIn("var waitForIdle: Double = UserActivityPolicy.defaultWaitSeconds", source)
            self.assertIn("var allowActivate: Bool = false", source)
        command = read(READ_COMMAND)
        self.assertIn('case waitedForUserMs = "waited_for_user_ms"', command)
        self.assertIn("try session.activity.waitUntilClear(.nextChat)", command)
        self.assertIn("throw ExitCode(UserActivityPolicy.inUseExitCode)", command)
        self.assertIn("var ok = true", read(CHATS_COMMAND))

    def test_mcp_exposes_the_options(self) -> None:
        server = read(MCP_SERVER)
        for option in ('"idle_seconds"', '"wait_for_idle"', '"allow_activate"'):
            self.assertIn(option, server)
        mapping = read(MCP_MAPPING)
        for flag in ('"--idle-seconds"', '"--wait-for-idle"', '"--allow-activate"'):
            self.assertIn(flag, mapping)


class OpenChatListContractTests(unittest.TestCase):
    def test_the_list_window_is_recognised_closed_and_reported(self) -> None:
        opener = read(OPENER)
        self.assertIn("case .openChatList(let list):", opener)
        self.assertIn('code: "OPEN_CHAT_LIST"', opener)
        self.assertIn("exitCode: notAChatExitCode", opener)
        self.assertIn('details["conversation_count"]', opener)
        # Closed with its own close button (no title check), before the error is thrown.
        failure = opener.index("throw Self.openChatListFailure(")
        self.assertLess(opener.index("let details = closeWindowsOpenedByThePress(windowsBefore: windowsBefore)"), failure)

    def test_classification_only_reads(self) -> None:
        locator = read(LOCATOR)
        body = locator[locator.index("func classifyWindow(_ window: UIElement)"):locator.index("func hasTranscript(")]
        self.assertNotIn("perform(", body)
        self.assertNotIn("setNumber(", body)


if __name__ == "__main__":
    unittest.main()
