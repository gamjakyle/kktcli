import re
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
FETCHER = REPO_ROOT / "Sources" / "kktcli" / "KakaoTalk" / "FullTextFetcher.swift"
READER = REPO_ROOT / "Sources" / "kktcli" / "KakaoTalk" / "StructuredTranscriptReader.swift"
READ_COMMAND = REPO_ROOT / "Sources" / "kktcli" / "Commands" / "ReadCommand.swift"
PARSER = REPO_ROOT / "Sources" / "KktcliCore" / "TranscriptParser.swift"
OUTPUT = REPO_ROOT / "Sources" / "KktcliCore" / "ReadOutput.swift"


class FullTextContractTests(unittest.TestCase):
    def test_truncation_is_detected_by_default_without_pressing(self) -> None:
        parser = PARSER.read_text(encoding="utf-8")
        output = OUTPUT.read_text(encoding="utf-8")
        read = READ_COMMAND.read_text(encoding="utf-8")
        self.assertIn("LongMessage.isTruncated(text:", parser)
        self.assertIn("case truncated", output)
        self.assertIn('case fullTextFetched = "full_text_fetched"', output)
        self.assertIn('case truncatedMessages = "truncated_messages"', read)
        self.assertIn('case fullText = "full_text"', read)
        self.assertNotIn("perform(", parser)

    def test_full_text_is_opt_in_and_not_background_safe(self) -> None:
        read = READ_COMMAND.read_text(encoding="utf-8")
        self.assertIn("var fullText: Bool = false", read)
        self.assertIn("fullText: fullText ? FullTextFetcher(kakao: kakao, runner: runner) : nil", read)
        self.assertIn("if fullText && backgroundSafe {", read)
        reader = READER.read_text(encoding="utf-8")
        self.assertIn("if let fullText {", reader)

    def test_fetcher_presses_only_the_see_all_control_and_closes_what_opened(self) -> None:
        fetcher = FETCHER.read_text(encoding="utf-8")
        performs = re.findall(r"AXNodeReader\.perform\(([^)]*)\)", fetcher)
        self.assertEqual(sorted(performs), sorted(["target.control, kAXPressAction", "overlay, kAXCancelAction"]))
        # The control is re-identified and compared right before the press.
        self.assertLess(fetcher.index("CFEqual(again.control, target.control)"), fetcher.index("target.control, kAXPressAction"))
        self.assertIn("LongMessage.seeAllControl(for: textIndex, in: snapshots)", fetcher)
        # Windows that appeared after the press are closed with their own close button only.
        self.assertIn("closer.close(window, expectedTitle: nil)", fetcher)
        for forbidden in ("CGEvent", "keyboard", "postKey", "kAXRaiseAction", "setFrontmost"):
            self.assertNotIn(forbidden, fetcher)


if __name__ == "__main__":
    unittest.main()
