"""Source-level contracts for the 0.2.1 fixes (authors fail closed, leftover search queries)."""

import re
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SOURCES = REPO_ROOT / "Sources"
PARSER = SOURCES / "KktcliCore" / "TranscriptParser.swift"
RECOVERER = SOURCES / "kktcli" / "KakaoTalk" / "ChatListRecoverer.swift"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


class AttributionContractTests(unittest.TestCase):
    def test_no_source_defaults_a_missing_author_to_me(self) -> None:
        pattern = re.compile(r'\?\?\s*"\(me\)"|\?\?\s*TranscriptItem\.meAuthor|\?\?\s*meAuthor')
        for path in SOURCES.rglob("*.swift"):
            self.assertIsNone(pattern.search(read(path)), f"{path.name} defaults a missing author to (me)")

    def test_rows_are_measured_against_their_own_frame(self) -> None:
        parser = read(PARSER)
        # No transcript frame read at another moment may decide a side.
        self.assertNotIn("transcriptFrame", parser)
        for path in (SOURCES / "kktcli").rglob("*.swift"):
            self.assertNotIn("transcriptFrame:", read(path), path.name)
        self.assertIn("static func referenceFrame(of nodes: [AXNodeSnapshot]) -> CGRect?", parser)
        # Disagreeing evidence never yields a side; the grouping check runs on every parse.
        self.assertIn("// The two disagree, or neither says anything.", parser)
        self.assertIn("resolveAuthors(&items)", parser)
        self.assertIn("demoteMine(", parser)

    def test_sender_names_come_only_from_header_rows(self) -> None:
        parser = read(PARSER)
        self.assertIn("let names = profile.first.flatMap", parser)
        self.assertIn("hasSenderHeader: !profile.isEmpty", parser)

    def test_commands_that_need_every_room_clear_a_leftover_query(self) -> None:
        recoverer = read(RECOVERER)
        self.assertIn("func clearLeftoverQuery(", recoverer)
        clear = recoverer[recoverer.index("func clearLeftoverQuery("):recoverer.index("private func readControls(")]
        self.assertIn("try activity.waitUntilClear(.listRecovery)", clear)
        self.assertIn('code: "CHAT_LIST_FILTERED"', clear)
        chats = read(SOURCES / "kktcli" / "Commands" / "ChatsCommand.swift")
        self.assertLess(chats.index(".clearLeftoverQuery("), chats.index("ChatListScanner().scan("))
        session = read(SOURCES / "kktcli" / "Send" / "RoomSession.swift")
        access = session[session.index("private func listAccess()"):]
        self.assertIn(".clearLeftoverQuery(", access[: access.index("\n    }\n")])

    def test_inspect_activates_kakaotalk_only_when_allowed(self) -> None:
        inspect = read(SOURCES / "kktcli" / "Commands" / "InspectCommand.swift")
        self.assertIn("var allowActivate: Bool = false", inspect)
        self.assertLess(inspect.index("guard allowActivate else {"), inspect.index("activateAndWaitForWindow("))


if __name__ == "__main__":
    unittest.main()
