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
                self.assertIn("0.2.0 (based on kmsg 1.260921.0)", readme)

    def test_korean_readme_has_safety_policy_and_results(self) -> None:
        readme = README_KO.read_text(encoding="utf-8")
        self.assertIn("## 안전과 정책", readme)
        self.assertIn("카카오와 무관합니다", readme)
        self.assertIn("정지 위험은 '접속 방식'과 '쓰는 패턴'에 따라 다릅니다", readme)
        self.assertIn("자동 감지로 이용이 제한될 수 있습니다", readme)
        self.assertIn("공식으로 허용한 적은 없고", readme)
        self.assertIn("대량 발송에 쓰지 마세요", readme)
        self.assertIn("읽음 표시", readme)
        self.assertIn("UNREAD_REFUSED", readme)
        self.assertIn("--skip-unread", readme)
        self.assertIn("마지막 메시지 미리보기뿐입니다", readme)
        self.assertNotIn("--allow-unread", readme)
        self.assertIn("AI 서비스", readme)
        self.assertIn("26.10.0", readme)
        for number in ("20/20", "17/20", "3.2초", "99.7%", "87.9%", "98.1%", "182/182"):
            self.assertIn(number, readme)

    def test_english_readme_has_safety_policy_and_results(self) -> None:
        readme = README_EN.read_text(encoding="utf-8")
        self.assertIn("## Safety and policy", readme)
        self.assertIn("Not affiliated with Kakao", readme)
        self.assertIn("The risk depends on how a tool connects and how you use it", readme)
        self.assertIn("automatic restrictions", readme)
        self.assertIn("has not officially permitted", readme)
        self.assertIn("Never mass-send", readme)
        self.assertIn("read receipts", readme)
        self.assertIn("--skip-unread", readme)
        self.assertIn("no way to see unread messages without marking them", readme)
        self.assertNotIn("--allow-unread", readme)
        self.assertIn("AI service", readme)
        self.assertIn("Tested only on 26.10.0", readme)
        for number in ("20/20", "17/20", "3.2 s", "99.7%", "87.9%", "98.1%", "182/182"):
            self.assertIn(number, readme)

    def test_docs_explain_the_activity_guard_and_spaces(self) -> None:
        for path in (README_KO, README_EN, USAGE):
            with self.subTest(path=path.name):
                text = path.read_text(encoding="utf-8")
                for code in ("KAKAOTALK_IN_USE", "MAIN_WINDOW_NOT_VISIBLE", "--allow-activate", "--idle-seconds", "--wait-for-idle"):
                    self.assertIn(code, text)
        usage = USAGE.read_text(encoding="utf-8")
        for text in ("#### Desktops and the activity guard", "`meta.waited_for_user_ms`", "| `KAKAOTALK_IN_USE` | 75 |", "| `OPEN_CHAT_LIST` | 4 |", '"ok": true\n}'):
            self.assertIn(text, usage)

    def test_usage_documents_unread_rooms_and_the_meta_fields(self) -> None:
        usage = USAGE.read_text(encoding="utf-8")
        for text in (
            "#### Unread rooms",
            "`--skip-unread`",
            "`unread_before`",
            "`unread_after`",
            "`marked_read`",
            '"unread_before": null',
            "no way to read unread",
        ):
            self.assertIn(text, usage)
        self.assertNotIn("unread_badge", usage)

    def test_docs_say_sending_is_off_and_there_is_no_dialog(self) -> None:
        for path, needle in ((README_KO, "보내기는 기본으로 꺼져 있습니다"), (README_EN, "Sending is off by default"), (USAGE, "Sending is off by default")):
            with self.subTest(path=path.name):
                text = path.read_text(encoding="utf-8")
                self.assertIn(needle, text)
                self.assertIn("kktcli config set send on", text)
                self.assertIn("SEND_DISABLED", text)
                for gone in ("SEND_CANCELLED", "확인 창", "confirmation dialog", "CONFIRMATION_REQUIRED"):
                    self.assertNotIn(gone, text)
        usage = USAGE.read_text(encoding="utf-8")
        for text in ("### `config`", "| `SEND_DISABLED` | 9 |", "~/.config/kktcli/config.json"):
            self.assertIn(text, usage)

    def test_usage_documents_the_chat_list_check_and_history(self) -> None:
        usage = USAGE.read_text(encoding="utf-8")
        for text in (
            "**The chat list is checked first.**",
            "`switched_to_chat_tab`",
            "never 친구 or 더보기",
            "`not_chat_tab`",
            "| `--all-history` |",
            '"history": {',
            "지난 대화 보기",
            "kktcli never presses it",
        ):
            self.assertIn(text, usage)

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
