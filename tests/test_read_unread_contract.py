import re
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
READ_COMMAND = REPO_ROOT / "Sources" / "kktcli" / "Commands" / "ReadCommand.swift"
OPENER = REPO_ROOT / "Sources" / "kktcli" / "KakaoTalk" / "ChatRoomMenuOpener.swift"
LOCATOR = REPO_ROOT / "Sources" / "kktcli" / "KakaoTalk" / "ChatListLocator.swift"


class ReadUnreadContractTests(unittest.TestCase):
    def test_unread_rooms_open_by_default_and_skip_unread_refuses(self) -> None:
        read = READ_COMMAND.read_text(encoding="utf-8")
        opener = OPENER.read_text(encoding="utf-8")

        self.assertIn("var skipUnread: Bool = false", read)
        self.assertIn("open(row, access: listAccess, skipUnread: skipUnread)", read)
        self.assertIn("if summary.unread.isUnread, skipUnread {", opener)
        self.assertIn("if row.summary.unread.isUnread, skipUnread {", read)
        self.assertNotIn("allowUnread", opener)
        # --allow-unread is still accepted, documented as deprecated, and only prints a note.
        self.assertIn("var allowUnread: Bool = false", read)
        self.assertIn("Deprecated, no effect", read)
        self.assertEqual(len(re.findall(r"\ballowUnread\b", read)), 2)

    def test_read_json_reports_the_badge_before_and_after(self) -> None:
        read = READ_COMMAND.read_text(encoding="utf-8")
        for key in (
            'case unreadBefore = "unread_before"',
            'case unreadAfter = "unread_after"',
            'case markedRead = "marked_read"',
        ):
            self.assertIn(key, read)
        self.assertNotIn('"unread_badge"', read)
        self.assertIn("UnreadReceipt.markedRead(before: opened.unreadBefore, after: unreadAfter)", read)
        # The re-check reads the list only and stays inside the automatic time budget.
        self.assertIn("static let unreadRecheckDuration: TimeInterval = 1.5", read)
        self.assertIn("startedAt.addingTimeInterval(Self.automaticWorkDeadline)", read)

    def test_row_recheck_only_reads(self) -> None:
        locator = LOCATOR.read_text(encoding="utf-8")
        start = locator.index("func currentUnreadBadge(of row: LocatedChatRow) -> UnreadBadge?")
        end = locator.index("private func previewMatches", start)
        body = locator[start:end]
        for forbidden in ("perform(", "setNumber(", "kAXPressAction", "CGEvent", "AXShowMenu"):
            self.assertNotIn(forbidden, body)


if __name__ == "__main__":
    unittest.main()
