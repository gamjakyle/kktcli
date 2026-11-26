import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
OPENER = REPO_ROOT / "Sources" / "kktcli" / "KakaoTalk" / "ChatRoomMenuOpener.swift"
LOCATOR = REPO_ROOT / "Sources" / "kktcli" / "KakaoTalk" / "ChatListLocator.swift"
RESOLVER = REPO_ROOT / "Sources" / "kktcli" / "KakaoTalk" / "ChatWindowResolver.swift"
READ_COMMAND = REPO_ROOT / "Sources" / "kktcli" / "Commands" / "ReadCommand.swift"


class OpenChatWindowContractTests(unittest.TestCase):
    def test_opener_accepts_an_untitled_window_only_through_the_rule(self) -> None:
        opener = OPENER.read_text(encoding="utf-8")
        self.assertIn("OpenedWindowRule.match(rowTitle: title, candidates: candidates)", opener)
        self.assertIn("OpenedWindowRule.untitledNewWindow(in: candidates)", opener)
        self.assertIn("let classified = locator.classifyWindow(windows[index])", opener)

    def test_a_failed_open_closes_every_window_that_appeared_after_the_press(self) -> None:
        opener = OPENER.read_text(encoding="utf-8")
        self.assertIn("var details = closeWindowsOpenedByThePress(windowsBefore: windowsBefore, offDesktop: offDesktop)", opener)
        self.assertIn('"unexpected_new_windows"', opener)
        self.assertIn('details["closed_new_windows"]', opener)
        self.assertIn('details["left_open_windows"]', opener)
        # Titles are read before closing: a closed window can no longer be read.
        self.assertIn("let labels = windows.map { OpenedWindowRule.label($0.title) }", opener)
        self.assertLess(opener.index("let labels = windows.map"), opener.index("closer.close(window, expectedTitle: nil)"))
        self.assertNotIn("Left open on purpose", opener)

    def test_title_lookups_skip_untitled_windows(self) -> None:
        locator = LOCATOR.read_text(encoding="utf-8")
        self.assertIn("chatWindows().filter { !OpenedWindowRule.isUntitled($0.title) }", locator)
        self.assertEqual(locator.count("titledChatWindows()"), 3)  # definition + both lookups
        resolver = RESOLVER.read_text(encoding="utf-8")
        self.assertIn("guard let title = window.title, !OpenedWindowRule.isUntitled(title) else { return nil }", resolver)

    def test_read_reports_and_closes_untitled_windows(self) -> None:
        read = READ_COMMAND.read_text(encoding="utf-8")
        self.assertIn('case windowTitleEmpty = "window_title_empty"', read)
        # Menu-opened windows are provably new, so their (possibly empty) title is not checked
        # when closing; a window that was already open before the press is left open.
        self.assertIn("expectedTitle: opened.method == .chatListMenu ? nil : opened.expectedTitle", read)
        self.assertIn("if !openedRoom.isNewWindow {", read)


if __name__ == "__main__":
    unittest.main()
