import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SOURCES = REPO_ROOT / "Sources"
REGISTRY = SOURCES / "kktcli" / "KakaoTalk" / "ChatIdentityRegistry.swift"
LOCATOR = SOURCES / "kktcli" / "KakaoTalk" / "ChatListLocator.swift"
RESOLVER = SOURCES / "kktcli" / "KakaoTalk" / "ChatWindowResolver.swift"
ASSIGNMENT = SOURCES / "KktcliCore" / "ChatIdentityAssignment.swift"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


class ChatIdentityContractTests(unittest.TestCase):
    def test_assignment_lives_in_core_and_never_pairs_by_position(self) -> None:
        registry = read(REGISTRY)
        self.assertIn("ChatIdentityAssignment.assign(rows: rows, records:", registry)
        self.assertNotIn("lastSeenIndex ?? .max", registry)
        self.assertNotIn("zippedCount", registry)
        assignment = read(ASSIGNMENT)
        self.assertNotIn("lastSeenIndex", assignment)
        self.assertIn("leftoverRows.count == 1, leftoverRecords.count == 1", assignment)

    def test_registry_migrates_schema_1_and_keeps_retired_ids(self) -> None:
        registry = read(REGISTRY)
        self.assertIn("static let schemaVersion = 2", registry)
        self.assertIn("static let readableSchemaVersions: Set<Int> = [1, 2]", registry)
        self.assertIn("var retired: Bool?", registry)

    def test_lookups_never_rerun_the_assignment_for_one_row(self) -> None:
        locator = read(LOCATOR)
        self.assertNotIn("assignChatIDs", locator)
        self.assertIn("ChatIdentityRegistryStore.shared.refresh(chatID: chatID, with: Self.discovery(row))", locator)
        self.assertIn("registry.resolution(of: chatID, among: discoveries)", locator)
        for code in ('code: "CHAT_ID_STALE"', 'code: "CHAT_AMBIGUOUS"'):
            self.assertIn(code, locator)
        self.assertIn("ChatListLocator.staleChatID(chatID, record: record)", read(RESOLVER))


if __name__ == "__main__":
    unittest.main()
