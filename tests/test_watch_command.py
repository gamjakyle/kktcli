import re
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
ENTRYPOINT = REPO_ROOT / "Sources" / "kktcli" / "kktcli.swift"
WATCH = REPO_ROOT / "Sources" / "kktcli" / "Commands" / "WatchCommand.swift"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


class WatchCommandContractTests(unittest.TestCase):
    def test_watch_command_is_registered(self) -> None:
        self.assertIn("WatchCommand.self", read(ENTRYPOINT))

    def test_one_chat_is_opened_like_read(self) -> None:
        source = read(WATCH)
        self.assertIn("try RoomSession(traceAX: traceAX, idleSeconds: idleSeconds, waitForIdle: waitForIdle, allowActivate: allowActivate)", source)
        self.assertIn("try session.open(located)", source)
        self.assertIn("WatchDiff.newTranscriptItems(", source)
        for forbidden in ("ChatWindowResolver(", "kakao.activate()", ".activate(", "pressEnterKey", "KakaoTalkTranscriptReader("):
            self.assertNotIn(forbidden, source)

    def test_all_mode_reads_the_list_without_clicking_or_scrolling(self) -> None:
        source = read(WATCH)
        body = source[source.index("private func watchList("):source.index("/// Opens one changed room")]
        for forbidden in ("perform(", "setNumber(", "pressShowMainWindowMenuItem", "reopen(", "AuthBootstrap"):
            self.assertNotIn(forbidden, body)
        self.assertIn("KakaoTalkApp(autoLaunch: false)", body)
        self.assertIn('output.status("main_window_not_visible"', body)
        self.assertIn("WatchDiff.chatListChanges(previous: previous, current: current, knownChatIDs: known)", body)
        self.assertIn("var top: Int = 30", source)
        self.assertIn("pollInterval ?? 3.0", body)

    def test_read_opens_changed_rooms_with_the_guard(self) -> None:
        source = read(WATCH)
        body = source[source.index("/// Opens one changed room"):]
        self.assertIn("ChatRoomMenuOpener(kakao: kakao, runner: runner, activity: activity).open(row, access: access, skipUnread: false)", body)
        self.assertIn("ChatWindowCloser(kakao: kakao, runner: runner).close(room.window, expectedTitle: nil)", body)

    def test_stop_conditions(self) -> None:
        source = read(WATCH)
        for option in ("var duration: Double?", "var count: Int?", "var read: Bool = false", "var all: Bool = false"):
            self.assertIn(option, source)
        self.assertIn("ReadInterruption.install()", source)


if __name__ == "__main__":
    unittest.main()
