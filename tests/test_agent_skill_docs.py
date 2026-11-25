import re
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
README_KO = REPO_ROOT / "README.md"
README_EN = REPO_ROOT / "README.en.md"
USAGE = REPO_ROOT / "USAGE.md"
LICENSE = REPO_ROOT / "LICENSE"
UPSTREAM = "https://github.com/channprj/kmsg"


class ProjectDocumentationTests(unittest.TestCase):
    def test_readmes_credit_the_upstream_fork(self) -> None:
        for path in (README_KO, README_EN):
            with self.subTest(path=path.name):
                readme = path.read_text(encoding="utf-8")
                self.assertIn(UPSTREAM, readme)
                self.assertIn("MIT", readme)
                self.assertIn("skills/kktcli", readme)
                self.assertIn("0.1.0 (based on kmsg 1.260921.0)", readme)

    def test_korean_readme_has_safety_policy_and_results(self) -> None:
        readme = README_KO.read_text(encoding="utf-8")
        self.assertIn("## 안전과 정책", readme)
        self.assertIn("카카오와 무관합니다", readme)
        self.assertIn("계정이 제한될 수 있습니다", readme)
        self.assertIn("대량 발송에 쓰지 마세요", readme)
        self.assertIn("읽음 표시", readme)
        self.assertIn("UNREAD_REFUSED", readme)
        self.assertIn("AI 서비스", readme)
        self.assertIn("26.10.0", readme)
        for number in ("20/20", "17/20", "3.2초", "99.7%", "87.9%", "98.1%", "182/182"):
            self.assertIn(number, readme)

    def test_english_readme_has_safety_policy_and_results(self) -> None:
        readme = README_EN.read_text(encoding="utf-8")
        self.assertIn("## Safety and policy", readme)
        self.assertIn("Not affiliated with Kakao", readme)
        self.assertIn("Accounts can be restricted", readme)
        self.assertIn("Never mass-send", readme)
        self.assertIn("read receipts", readme)
        self.assertIn("AI service", readme)
        self.assertIn("Tested only on 26.10.0", readme)
        for number in ("20/20", "17/20", "3.2 s", "99.7%", "87.9%", "98.1%", "182/182"):
            self.assertIn(number, readme)

    def test_docs_mention_kmsg_only_as_credit_or_comparison(self) -> None:
        usage = USAGE.read_text(encoding="utf-8")
        # USAGE mentions kmsg only for the version credit and the data it never touches.
        for line in usage.splitlines():
            if "kmsg" in line:
                self.assertTrue(
                    "based on kmsg" in line or "~/.kmsg" in line or "an installed kmsg" in line,
                    line,
                )
        self.assertNotRegex(usage, r"\bkmsg (?:read|chats|send|status|update)\b")

    def test_license_keeps_the_original_notice_and_adds_the_fork(self) -> None:
        license_text = LICENSE.read_text(encoding="utf-8")
        self.assertTrue(license_text.startswith("MIT License"))
        self.assertIn("Copyright (c) 2026 Park Hee Chan", license_text)
        self.assertIn("Copyright (c) 2026 gamjakyle", license_text)
        self.assertEqual(len(re.findall(r"Permission is hereby granted", license_text)), 1)


if __name__ == "__main__":
    unittest.main()
