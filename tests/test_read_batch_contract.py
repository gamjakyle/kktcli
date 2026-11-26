import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
READ_COMMAND = REPO_ROOT / "Sources" / "kktcli" / "Commands" / "ReadCommand.swift"
MCP_MAPPING = REPO_ROOT / "Sources" / "KktcliCore" / "MCPMapping.swift"


class ReadBatchContractTests(unittest.TestCase):
    def test_chat_id_is_repeatable_and_a_file_can_list_chat_ids(self) -> None:
        read = READ_COMMAND.read_text(encoding="utf-8")
        self.assertIn('@Option(name: .customLong("chat-id")', read)
        self.assertIn("var chatIDs: [String] = []", read)
        self.assertIn('name: .customLong("chat-ids-file")', read)
        self.assertIn("var chatIDsFile: String?", read)

    def test_a_batch_sets_up_once_and_reads_every_chat(self) -> None:
        read = READ_COMMAND.read_text(encoding="utf-8")
        body = read[read.index("private func runBatch()"):]
        # One session for the whole batch, created before the loop over the chats.
        self.assertEqual(body.count("try startSession()"), 1)
        self.assertLess(body.index("try startSession()"), body.index("for id in ids {"))
        # One failing chat does not stop the others; every chat gets a result.
        self.assertIn("entries.append((id, .failure(failure)))", body)
        self.assertIn('code: "INTERRUPTED"', body)
        self.assertIn("BatchJSONResponse(", body)

    def test_single_reads_keep_their_document_and_the_mcp_passes_one_chat_id(self) -> None:
        read = READ_COMMAND.read_text(encoding="utf-8")
        self.assertIn("if isBatch {", read)
        self.assertIn("return try readRoom(target, session: session, startedAt: startedAt)", read)
        mapping = MCP_MAPPING.read_text(encoding="utf-8")
        read_request = mapping[mapping.index("public struct MCPReadRequest"):mapping.index("public enum MCPErrorMapping")]
        self.assertEqual(read_request.count('"--chat-id"'), 1)


if __name__ == "__main__":
    unittest.main()


class ReadAllHistoryContractTests(unittest.TestCase):
    def test_all_history_scrolls_to_the_top_then_reads_once(self) -> None:
        read = READ_COMMAND.read_text(encoding="utf-8")
        self.assertIn("var allHistory: Bool = false", read)
        self.assertIn("static let allHistoryScrollbackTimeout: Double = 120", read)
        self.assertIn("limit ?? (allHistory ? Self.maximumLimit : 20)", read)
        self.assertIn("history: HistoryStatus.evaluate(", read)
        self.assertIn("지난 대화 보기", read)
        reader = (REPO_ROOT / "Sources" / "kktcli" / "KakaoTalk" / "StructuredTranscriptReader.swift").read_text(encoding="utf-8")
        body = reader[reader.index("if options.allHistory {"):reader.index("while !options.allHistory,")]
        self.assertEqual(body.count("readTail(parts, options: options)"), 1)
        self.assertIn("historyTopLoaded(parts.table)", body)
        self.assertNotIn("perform(", reader[reader.index("private func historyTopLoaded("):])
