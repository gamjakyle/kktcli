import json
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SKILL_DIR = REPO_ROOT / "skills" / "kktcli"
SKILL_PATH = SKILL_DIR / "SKILL.md"
OPENAI_METADATA_PATH = SKILL_DIR / "agents" / "openai.yaml"
EVALS_PATH = SKILL_DIR / "evals" / "evals.json"


class AgentSkillContractTests(unittest.TestCase):
    def test_skill_package_has_cross_agent_metadata(self) -> None:
        skill = SKILL_PATH.read_text(encoding="utf-8")
        metadata = OPENAI_METADATA_PATH.read_text(encoding="utf-8")

        self.assertRegex(skill, r"(?m)^name: kktcli$")
        self.assertRegex(skill, r"(?m)^description: .*(?:KakaoTalk|카카오톡).*$")
        self.assertRegex(skill, r"(?m)^compatibility: .*(?:macOS|kktcli).*$")
        self.assertIn('display_name: "kktcli"', metadata)
        self.assertIn("$kktcli", metadata)
        self.assertNotIn("kmsg", skill + metadata)

    def test_skill_starts_with_preflight_and_structured_discovery(self) -> None:
        skill = SKILL_PATH.read_text(encoding="utf-8")

        self.assertIn("command -v kktcli", skill)
        self.assertIn("kktcli status", skill)
        self.assertIn("kktcli chats --json", skill)
        self.assertIn('kktcli read --chat-id "<chat_id>" --limit 20 --json', skill)
        self.assertIn("--background-safe", skill)

    def test_unread_rooms_are_read_with_receipts_unless_skipped(self) -> None:
        skill = SKILL_PATH.read_text(encoding="utf-8")

        self.assertIn("--skip-unread", skill)
        self.assertIn("UNREAD_REFUSED", skill)
        self.assertIn("meta.unread_before", skill)
        self.assertIn("meta.marked_read", skill)
        self.assertRegex(skill, r"(?i)read receipts")
        self.assertRegex(skill, r"(?i)no way to read\s+unread messages without marking them read")
        self.assertRegex(skill, r"(?i)do not open unread rooms the user did not ask about")
        self.assertNotIn("--allow-unread", skill)

    def test_text_sending_requires_dry_run_and_explicit_authorization(self) -> None:
        skill = SKILL_PATH.read_text(encoding="utf-8")

        dry_run = 'kktcli send --chat-id "<chat_id>" "<message>" --preview --json'
        actual_send = 'kktcli send --chat-id "<chat_id>" "<message>" --json'
        self.assertIn(dry_run, skill)
        self.assertIn(actual_send, skill)
        self.assertLess(skill.index(dry_run), skill.rindex(actual_send))
        self.assertRegex(skill, r"(?i)explicit(?:ly)? (?:asked|authorized|requested)")
        self.assertRegex(skill, r"(?i)ambiguous")
        self.assertRegex(skill, r"(?i)(?:never|do not).*(?:duplicate|twice)")
        self.assertRegex(skill, r"(?i)never send in bulk")

    def test_image_and_watch_workflows_name_their_safety_boundaries(self) -> None:
        skill = SKILL_PATH.read_text(encoding="utf-8")

        self.assertIn('kktcli send-image --chat-id "<chat_id>" "/absolute/path/to/image.png" --preview --json', skill)
        self.assertIn("said 보내", skill)
        self.assertRegex(skill, r"(?i)at most 3 lines")
        self.assertRegex(skill, r"(?i)never add facts")
        self.assertIn('kktcli watch --chat-id "<chat_id>" --json --duration 600', skill)
        self.assertIn("kktcli watch --all --json --duration 600", skill)
        self.assertRegex(skill, r"(?i)(?:stop|terminate).*(?:watch|process)")

    def test_summarise_workflow_uses_export_and_the_template(self) -> None:
        skill = SKILL_PATH.read_text(encoding="utf-8")
        self.assertIn("## 정리하기", skill)
        self.assertIn("kktcli export --chat-id", skill)
        self.assertIn("templates/방-요약.md", skill)
        self.assertRegex(skill, r"(?i)team's own template")
        self.assertIn("CHAT_ID_STALE", skill)
        self.assertIn("CHAT_AMBIGUOUS", skill)

    def test_eval_set_covers_read_unread_text_send_and_image_intents(self) -> None:
        payload = json.loads(EVALS_PATH.read_text(encoding="utf-8"))

        self.assertEqual(payload["skill_name"], "kktcli")
        self.assertEqual(len(payload["evals"]), 4)
        prompts = "\n".join(item["prompt"] for item in payload["evals"])
        self.assertIn("최근 메시지", prompts)
        self.assertIn("보내줘", prompts)
        self.assertIn("이미지", prompts)
        expectations = "\n".join("\n".join(item["expectations"]) for item in payload["evals"])
        self.assertIn("UNREAD_REFUSED", expectations)
        self.assertIn("--skip-unread", expectations)
        self.assertNotIn("--allow-unread", expectations)
        for item in payload["evals"]:
            self.assertTrue(item["expected_output"])
            self.assertEqual(item["files"], [])
            self.assertGreaterEqual(len(item["expectations"]), 2)


if __name__ == "__main__":
    unittest.main()
