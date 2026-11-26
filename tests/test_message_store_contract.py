import json
import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SOURCES = REPO_ROOT / "Sources"
ENTRYPOINT = SOURCES / "kktcli" / "kktcli.swift"
CORE = SOURCES / "KktcliCore" / "MessageStore.swift"
ARCHIVE = SOURCES / "kktcli" / "Store" / "MessageArchive.swift"
SEARCH_COMMAND = SOURCES / "kktcli" / "Commands" / "SearchCommand.swift"
STORE_COMMAND = SOURCES / "kktcli" / "Commands" / "StoreCommand.swift"
USAGE = REPO_ROOT / "USAGE.md"
# SwiftPM build directory, as in test_version_gen_tool.py (e.g. KKTCLI_BUILD_PATH=.build-next).
BUILD_PATH = REPO_ROOT / os.environ.get("KKTCLI_BUILD_PATH", ".build")

PLAIN_TEXT_NOTICE = "The store contains chat content in plain text on this Mac"
RECORD_KEYS = {
    "chat_id", "chat", "date", "time", "time_raw", "author", "side", "kind", "body", "occurrence",
    "edited", "truncated", "saved_at",
}
# Anything that reaches KakaoTalk or the Accessibility API.
KAKAOTALK_OR_AX = re.compile(
    r"\bAX[A-Z]\w*|\bkAX\w*|\b(?:KakaoTalkApp|UIElement|AccessibilityPermission|AuthBootstrap|"
    r"ChatWindowResolver|ChatListScanner|ChatListLocator|ChatRoomMenuOpener|MainWindowAccess|"
    r"UserActivityGuard|KakaoTalkInputGuard|KakaoTalkTranscriptReader|MessageContextResolver|"
    r"FullTextFetcher|NSWorkspace|NSRunningApplication|CGEvent\w*)\b"
    r"|import (?:ApplicationServices|AppKit|Cocoa)"
)


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


class MessageStoreSourceContractTests(unittest.TestCase):
    def test_search_and_store_commands_are_registered(self) -> None:
        entrypoint = read(ENTRYPOINT)
        subcommands = entrypoint[entrypoint.index("subcommands: ["):]
        subcommands = subcommands[: subcommands.index("]")]
        self.assertIn("SearchCommand.self", subcommands)
        self.assertIn("StoreCommand.self", subcommands)
        self.assertIn('commandName: "search"', read(SEARCH_COMMAND))
        store = read(STORE_COMMAND)
        self.assertIn('commandName: "store"', store)
        self.assertIn('commandName: "clear"', store)
        self.assertIn("subcommands: [StoreClearCommand.self]", store)

    def test_store_code_never_touches_kakaotalk_or_accessibility(self) -> None:
        for path in (SEARCH_COMMAND, STORE_COMMAND, ARCHIVE, CORE):
            with self.subTest(path=path.name):
                self.assertIsNone(KAKAOTALK_OR_AX.search(read(path)))

    def test_archive_keeps_the_store_owner_only(self) -> None:
        archive = read(ARCHIVE)
        self.assertIn("static let directoryMode: mode_t = 0o700", archive)
        self.assertIn("static let fileMode: mode_t = 0o600", archive)
        # New directories are created 0700 and files 0600; symbolic links are never followed.
        self.assertIn("attributes: [.posixPermissions: NSNumber(value: Int(Self.directoryMode))]", archive)
        self.assertIn("open(path, access | O_CLOEXEC | O_NOFOLLOW, Self.fileMode)", archive)
        # Wider modes found on an existing directory or file are narrowed.
        self.assertIn("if info.st_mode & 0o077 != 0, chmod(path, Self.directoryMode) != 0 {", archive)
        self.assertIn("if info.st_mode & 0o077 != 0, fchmod(descriptor, Self.fileMode) != 0 {", archive)
        append = archive[archive.index("func append(chatID:"):archive.index("func records(chatID:")]
        self.assertLess(append.index("try prepareDirectory()"), append.index("openLocked(url, forWriting: true)"))
        self.assertLess(append.index("openLocked(url, forWriting: true)"), append.index("try restrictFileMode("))
        self.assertLess(append.index("try restrictFileMode("), append.index("try writeAll("))
        # The read-merge-append runs under an exclusive lock.
        self.assertIn("flock(descriptor, forWriting ? LOCK_EX : LOCK_SH)", archive)

    def test_store_directory_honours_kktcli_store_dir(self) -> None:
        archive = read(ARCHIVE)
        self.assertIn('static let environmentVariable = "KKTCLI_STORE_DIR"', archive)
        self.assertIn('static let defaultRelativePath = ".kktcli/messages"', archive)
        self.assertIn("environment[environmentVariable]", archive)
        self.assertIn(".appendingPathComponent(defaultRelativePath, isDirectory: true)", archive)
        self.assertIn("init(directory: URL = MessageArchive.defaultDirectory())", archive)
        self.assertIn("MessageArchive()", archive)
        for source in (archive, read(SEARCH_COMMAND), read(STORE_COMMAND)):
            self.assertNotIn(".kmsg", source)
        # The commands always go through the shared archive, never a hard-coded path.
        self.assertIn("let archive = MessageArchive.shared", read(SEARCH_COMMAND))
        self.assertIn("let archive = MessageArchive.shared", read(STORE_COMMAND))

    def test_chat_ids_are_validated_before_any_path_is_built(self) -> None:
        core = read(CORE)
        self.assertIn("case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x5F, 0x2D:  // 0-9 A-Z a-z _ -", core)
        self.assertIn("isValidChatID(chatID) ? \"\\(chatID).\\(fileExtension)\" : nil", core)
        archive = read(ARCHIVE)
        self.assertIn(
            "guard let name = MessageStore.fileName(chatID: chatID) else {\n"
            "            throw MessageArchiveError.invalidChatID(chatID)",
            archive,
        )
        # Every path below the store directory is built from a validated name.
        self.assertEqual(
            sorted(re.findall(r"appendingPathComponent\(([^)]*)\)", archive)),
            sorted(["defaultRelativePath, isDirectory: true", "name", "name, isDirectory: false"]),
        )
        self.assertIn("guard let id = MessageStore.chatID(fromFileName: name) else { return nil }", archive)
        for api in ("func append(chatID:", "func records(chatID:", "func clearChats(chatID:"):
            body = archive[archive.index(api):]
            body = body[: body.index("\n    }\n")]
            self.assertIn("fileURL(chatID: ", body, api)
        # The commands reject a bad --chat-id themselves too (INVALID_ARGUMENT).
        self.assertIn("StoreCommandProblem.chatIDProblem(chatID)", read(SEARCH_COMMAND))
        self.assertIn("StoreCommandProblem.chatIDProblem(chatID)", read(STORE_COMMAND))

    def test_help_says_the_store_holds_plain_text_chat_content(self) -> None:
        self.assertIn(PLAIN_TEXT_NOTICE, read(SEARCH_COMMAND))
        # `store` and `store clear`.
        self.assertGreaterEqual(read(STORE_COMMAND).count(PLAIN_TEXT_NOTICE), 2)

    def test_json_documents(self) -> None:
        search = read(SEARCH_COMMAND)
        for key in ("case ok", "case count", "case results", "case store"):
            self.assertIn(key, search)
        store = read(STORE_COMMAND)
        for key in ("case ok", "case error", "case code", "case message", "case hint"):
            self.assertIn(key, store)
        self.assertIn("try error.encode(problem.hint, forKey: .hint)", store)
        for source in (search, store):
            self.assertIn("throw ExitCode(problem.exitCode)", source)

    def test_usage_documents_the_store(self) -> None:
        usage = read(USAGE)
        self.assertIn("## Local message store", usage)
        section = usage[usage.index("## Local message store"):]
        section = section[: section.index("\n## ", 1)]
        for needle in (
            "~/.kktcli/messages/<chat_id>.jsonl", "0700", "0600", "plain text", "KKTCLI_STORE_DIR",
            "occurrence", "kktcli search", "kktcli store clear", "--no-save",
        ):
            self.assertIn(needle, section, needle)


def kktcli_binary() -> Path | None:
    candidates = [BUILD_PATH / configuration / "kktcli" for configuration in ("debug", "release")]
    existing = [path for path in candidates if path.exists()]
    return max(existing, key=lambda path: path.stat().st_mtime) if existing else None


class MessageStoreCommandTests(unittest.TestCase):
    """Runs only `search`, `store clear` and `--help` of a built binary, always with
    KKTCLI_STORE_DIR (and HOME) inside a temporary directory. Neither command uses KakaoTalk
    (see the source checks above)."""

    def setUp(self) -> None:
        binary = kktcli_binary()
        if binary is None:
            self.skipTest(f"no kktcli binary under {BUILD_PATH}; build first")
        shown = subprocess.run([str(binary), "search", "--help"], capture_output=True, text=True, timeout=30)
        if shown.returncode != 0 or PLAIN_TEXT_NOTICE not in " ".join(shown.stdout.split()):
            self.skipTest(f"{binary} has no search command yet; rebuild")
        self.binary = binary
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.store = self.root / "store"
        home = self.root / "home"
        home.mkdir()
        self.env = {key: value for key, value in os.environ.items() if not key.startswith("KKTCLI_")}
        self.env.update({"KKTCLI_STORE_DIR": str(self.store), "HOME": str(home), "CFFIXED_USER_HOME": str(home)})

    def kktcli(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        self.assertIn(arguments[0], ("search", "store"))
        return subprocess.run(
            [str(self.binary), *arguments], capture_output=True, text=True, env=self.env, timeout=30
        )

    def json_of(self, result: subprocess.CompletedProcess[str]) -> dict:
        return json.loads(result.stdout)

    def assert_store_is_temporary(self) -> None:
        document = self.json_of(self.kktcli("search", "", "--json"))
        self.assertEqual(os.path.realpath(document["store"]), os.path.realpath(self.store))

    def record(self, chat_id: str, body: str, author: str | None, date: str, time: str | None, kind: str = "message") -> dict:
        return {
            "chat_id": chat_id, "chat": "테스트방", "date": date, "time": time, "time_raw": None,
            "author": author, "side": "system" if kind == "system" else "other", "kind": kind,
            "body": body, "occurrence": 0, "edited": False, "truncated": False,
            "saved_at": "2026-11-21T00:00:00.000Z",
        }

    def seed(self, chat_id: str, records: list[dict]) -> Path:
        self.store.mkdir(mode=0o700, exist_ok=True)
        path = self.store / f"{chat_id}.jsonl"
        path.write_text("".join(json.dumps(record, ensure_ascii=False) + "\n" for record in records), encoding="utf-8")
        path.chmod(0o600)
        return path

    def test_search_reads_only_the_store_directory(self) -> None:
        empty = self.kktcli("search", "안녕", "--json")
        self.assertEqual(empty.returncode, 0, empty.stderr)
        document = self.json_of(empty)
        self.assertEqual(document["ok"], True)
        self.assertEqual(document["count"], 0)
        self.assertEqual(document["results"], [])
        self.assertEqual(os.path.realpath(document["store"]), os.path.realpath(self.store))
        self.assertFalse(self.store.exists(), "search must not create the store")

        path = self.seed("chat_test", [
            self.record("chat_test", "안녕하세요", "홍길동", "2026-11-20", "14:05"),
            self.record("chat_test", "김철수님이 들어왔습니다.", None, "2026-11-20", None, kind="system"),
            self.record("chat_test", "안녕 하세요 반가워요", "김철수", "2026-11-21", "09:00"),
            self.record("chat_test", "잘 가요", "홍길동", "2026-11-21", "09:05"),
        ])
        before = path.read_bytes()

        found = self.kktcli("search", "안녕하세요", "--json")
        self.assertEqual(found.returncode, 0, found.stderr)
        document = self.json_of(found)
        self.assertEqual(document["count"], 2)
        self.assertEqual([result["body"] for result in document["results"]], ["안녕 하세요 반가워요", "안녕하세요"])
        self.assertEqual(set(document["results"][0]), RECORD_KEYS)

        text = self.kktcli("search", "안녕하세요")
        self.assertEqual(text.returncode, 0, text.stderr)
        self.assertEqual(text.stdout.splitlines(), [
            "2026-11-21 09:00 김철수 (테스트방): 안녕 하세요 반가워요",
            "2026-11-20 14:05 홍길동 (테스트방): 안녕하세요",
        ])

        filtered = self.kktcli("search", "", "--author", "홍길동", "--since", "2026-11-21", "--limit", "1", "--json")
        self.assertEqual([result["body"] for result in self.json_of(filtered)["results"]], ["잘 가요"])
        other_chat = self.kktcli("search", "안녕", "--chat-id", "chat_other", "--json")
        self.assertEqual(self.json_of(other_chat)["count"], 0)
        self.assertEqual(path.read_bytes(), before, "search must not write to the store")

    def test_bad_arguments_are_reported_without_touching_files(self) -> None:
        for arguments in (
            ("search", "안녕", "--chat-id", "../escape", "--json"),
            ("search", "안녕", "--since", "2026-02-30", "--json"),
            ("search", "안녕", "--since", "2026-11-21", "--until", "2026-11-20", "--json"),
            ("search", "안녕", "--limit", "0", "--json"),
            ("store", "clear", "--chat-id", "../escape", "--json"),
        ):
            with self.subTest(arguments=arguments):
                result = self.kktcli(*arguments)
                self.assertEqual(result.returncode, 64, result.stderr)
                document = self.json_of(result)
                self.assertEqual(document["ok"], False)
                self.assertEqual(document["error"]["code"], "INVALID_ARGUMENT")
                self.assertTrue(document["error"]["message"])
                self.assertIn("hint", document["error"])
        text = self.kktcli("search", "안녕", "--chat-id", "a/b")
        self.assertEqual(text.returncode, 64)
        self.assertEqual(text.stdout, "")
        self.assertIn("--chat-id", text.stderr)
        self.assertEqual(sorted(path.name for path in self.root.iterdir()), ["home"])

    def test_store_clear_removes_only_store_files(self) -> None:
        self.assert_store_is_temporary()
        self.seed("chat_a", [self.record("chat_a", "안녕하세요", "홍길동", "2026-11-20", "14:05")])
        self.seed("chat_b", [self.record("chat_b", "안녕하세요", "김철수", "2026-11-20", "14:06")])
        (self.store / "notes.txt").write_text("keep\n", encoding="utf-8")

        one = self.kktcli("store", "clear", "--chat-id", "chat_a", "--json")
        self.assertEqual(one.returncode, 0, one.stderr)
        self.assertEqual(self.json_of(one)["chat_ids"], ["chat_a"])
        self.assertEqual(self.json_of(one)["removed"], 1)
        self.assertFalse((self.store / "chat_a.jsonl").exists())
        self.assertTrue((self.store / "chat_b.jsonl").exists())

        everything = self.kktcli("store", "clear", "--json")
        document = self.json_of(everything)
        self.assertEqual((document["ok"], document["removed"], document["chat_ids"]), (True, 1, ["chat_b"]))
        self.assertEqual(os.path.realpath(document["store"]), os.path.realpath(self.store))
        self.assertEqual(sorted(path.name for path in self.store.iterdir()), ["notes.txt"])

        again = self.kktcli("store", "clear")
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertIn("No saved messages", again.stdout)


if __name__ == "__main__":
    unittest.main()
