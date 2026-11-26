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


CHATS = SOURCES / "kktcli" / "Commands" / "ChatsCommand.swift"
WATCH = SOURCES / "kktcli" / "Commands" / "WatchCommand.swift"
READ = SOURCES / "kktcli" / "Commands" / "ReadCommand.swift"
SESSION = SOURCES / "kktcli" / "Send" / "RoomSession.swift"


class ChatListVerificationContractTests(unittest.TestCase):
    def test_nothing_is_recorded_from_an_unverified_table(self) -> None:
        chats = read(CHATS)
        self.assertLess(chats.index("try locator.verifiedAccess(in: mainWindow, activity: activity)"), chats.index("registry.assignChatIDs("))
        self.assertLess(chats.index("if case .notChatList = verification {"), chats.index("registry.assignChatIDs("))
        resolver = read(RESOLVER)
        self.assertLess(resolver.index("ChatListCheck.verify(snapshots.compactMap(\\.summary)).isChatList"), resolver.index("registry.assignChatIDs("))

    def test_read_send_and_watch_use_only_a_verified_chat_list(self) -> None:
        self.assertIn("try locator.verifiedAccess(in: mainWindow, activity: session.activity)", read(READ))
        self.assertIn("tableVerified: verified.verified", read(READ))
        self.assertIn("try locator.verifiedAccess(in: mainWindow, activity: activity).access", read(SESSION))
        watch = read(WATCH)
        self.assertIn('output.status("not_chat_tab"', watch)
        self.assertIn("frontmost: FrontmostPolicy.keyboard(evidence).allowed", watch)
        self.assertNotIn("frontmost: false", watch)

    def test_the_tab_switch_presses_only_the_chat_menu_item(self) -> None:
        locator = read(LOCATOR)
        body = locator[locator.index("func pressChatTabMenuItem("):locator.index("func verifiedAccess(")]
        self.assertIn("ChatTabMenu.isChatTabItem(role: node.role, title: node.title, commandCharacter: commandCharacter)", body)
        self.assertIn("guard isItem(item), beforePress() else {", body)
        self.assertEqual(body.count("AXNodeReader.perform("), 1)
        for forbidden in ('"친구"', '"더보기"', "kAXMenuItemCmdCharAttribute, ", "CGEvent", "pressKey"):
            self.assertNotIn(forbidden, body)
        self.assertIn("try activity.waitUntilClear(.switchToChatTab)", locator)
