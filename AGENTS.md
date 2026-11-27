# AGENTS.md

Guidance for coding agents working in this repository (also read as CLAUDE.md).

## Build

```bash
swift build                      # debug
swift build -c release           # release
.build/debug/kktcli --version    # 0.2.1 (based on kmsg 1.260921.0)
```

## Test

Pure logic lives in `Sources/KktcliCore` and is unit tested without KakaoTalk or the
Accessibility API; the Python tests check source-level contracts.

```bash
make test-core                                          # Swift Testing (KktcliCoreTests)
python3 -m unittest discover -s tests -p "test_*.py"    # contract tests
```

Anything that drives KakaoTalk can only be tested by hand on a Mac with KakaoTalk and
Accessibility permission. Do not run such commands unless the user asked for it; never
use `send` or `send-image` in tests.

```bash
.build/debug/kktcli status --verbose
.build/debug/kktcli chats --json --limit 20
.build/debug/kktcli read --chat-id "<chat_id>" --limit 20 --json --trace-ax
.build/debug/kktcli read --chat-id "<chat_id>" --limit 20 --json --skip-unread
.build/debug/kktcli send "Name" "msg" --dry-run
```

## Layout

```
Sources/kktcli/Commands       CLI commands (ArgumentParser)
Sources/kktcli/KakaoTalk      chat list, opener, transcript reader, recovery, legacy resolver
Sources/kktcli/Send           room session, send preview, verified send
Sources/kktcli/Store          local message store (~/.kktcli/messages)
Sources/kktcli/Accessibility  AX wrappers, batched reads, input guard, permission
Sources/KktcliCore            pure parsing / policy logic (unit tested)
tests/KktcliCoreTests         Swift Testing unit tests
tests/*.py                    contract tests
skills/kktcli                 agent skill
templates                     one-page digest templates (teams copy and edit)
install.sh, make dist         release install (SHA-256 checked) and packaging
```

See [ARCHITECTURE.md](ARCHITECTURE.md) for the design.

## KakaoTalk for Mac 26.10 UI notes

```
Main window (identifier "Main Window"; on another desktop reachable only by element id):
├── AXButton "friends" / "chatrooms" / "more" (tabs; 창 menu: 친구 ⌘1, 채팅 ⌘2, 더보기 ⌘3)
├── 친구 tab: AXScrollArea _NS:93 > AXOutline _NS:8 (never the chat list)
├── 채팅 tab: AXButton "채팅방 추가", and
└── AXScrollArea _NS:101 > AXTable _NS:63 > AXRow > AXCell
    _NS:40 title, Count Label member count, _NS:69 time, _NS:87/_NS:91 preview,
    _NS:138 unread badge ("안읽음 N"); the cell supports AXShowMenu
    (menu item openChatRoom: "채팅방 열기")

Open-chat conversation list (some 1:1 "오픈채팅, …" rows open this instead of a chat;
untitled AXStandardWindow, never press anything in it):
├── AXImage _NS:81 header, AXButton _NS:167 "버튼"
└── AXScrollArea _NS:14 > AXTable _NS:18 > AXRow > AXCell
    _NS:11 "프로필", _NS:40 title, _NS:69 time, _NS:87 preview
    (may have zero rows: then only an AXColumn; the row's chat-list preview reads
    "대화 중인 오픈채팅방이 없습니다.")

A busy KakaoTalk can fail single AX reads (0.25 s default timeout), e.g. right after a
window closed: re-check before concluding a window is missing.

Chat window (title = room name; team, self and open chats drop the "팀채팅, ",
"나와의 채팅, ", "오픈채팅, " row prefix; open chats may have an EMPTY title):
├── AXScrollArea _NS:32 > AXTable > AXRow (transcript; rows 380 pt wide in a default window:
│   profile button 36 pt square 10 pt in, name 55 pt in, others' bubbles 60–65 pt in,
│   mine end 18–23 pt before the right edge, meta left of mine and right of others')
│   long message: AXTextArea value = first 500 chars + "…", then an AXButton with NO
│   title/description/identifier right below it (35 pt tall) = 전체보기
└── AXTextArea _NS:51 "메시지 입력"
```

## Rules

- Bundle ID: `com.kakao.KakaoTalkMac`. Data lives in `~/.kktcli` and `~/.config/kktcli`;
  never read or write `~/.kmsg` or `~/.config/kmsg`.
- No network code in `Sources`.
- The read path must not post keyboard or mouse events. Any code that posts them goes
  through `AXActionRunner`, which checks `KakaoTalkInputGuard` before every press.
- Press only allowlisted elements and re-verify them right before the press.
- Every press that opens or brings up a KakaoTalk window waits for `UserActivityGuard`
  (KakaoTalk in front and used < `--idle-seconds` ago → wait, then `KAKAOTALK_IN_USE`) and
  re-checks it right before the press. The main window is found only through
  `MainWindowAccess.resolve` (order in `MainWindowLookup`): kAXWindows, then by element id
  on another desktop (`KakaoWindowLookup`, read-only), then 창 > 채팅 only when the window
  server shows no main window (closed), then 카카오톡 열기 only with `--allow-activate`,
  else `MAIN_WINDOW_NOT_VISIBLE`. kAXWindows lists only the current desktop's windows.
- `_AXUIElementCreateWithRemoteToken` is private: resolve it with dlsym only
  (`RemoteAXElement`), never `@_silgen_name`, so kktcli still launches without it.
- Before anything uses the main window's table (chats, read, send, watch --all, any
  registry write), verify it is the chat list (`ChatListCheck`: an AXTable, never the 친구
  tab's AXOutline, with chat-row structure). To switch tabs press only the 창 menu item
  titled 채팅 with command key 2 (`ChatTabMenu`), or, only when that item is missing, the
  `chatrooms` tab button, through the activity guard; never press 친구, 더보기, `friends` or
  `more`, and never run list recovery on an unverified table.
- Sending is off unless `kktcli config set send on` (`~/.config/kktcli/config.json`); never
  turn it on from code, tests or skills. There is no confirmation dialog: the preview and the
  user's explicit 보내 are the check.
- `read` opens rooms with unread messages, which sends read receipts like opening them
  by hand; `--skip-unread` leaves them unopened (`UNREAD_REFUSED`, exit status 3) and
  `--allow-unread` is a deprecated no-op. Keep `meta.unread_before`, `unread_after` and
  `marked_read` truthful (null when not checked).
- chat_ids: never pair same-name rooms by position (`ChatIdentityAssignment`: exact title,
  preview + time + members, preview, elimination; identical rows get no ID and their records
  are held as a set); a lookup of one ID uses the same matching and only refreshes that
  record (`ChatIdentityRegistryStore.refresh`).
- Files in `~/.kktcli` are shared by concurrent kktcli processes: change them only through
  a locked re-read-and-replace (`ChatIdentityRegistryFile.update`, `SharedFile`); never
  write back a document cached in memory.
- Keep `read --json` output to exactly one JSON document on stdout.
- Authors fail closed (`TranscriptParser`): `"(me)"` only on positive evidence, never as a
  default. A header-less row's side comes from its own AXCell frame and its meta label (never
  from a frame read at another moment); disagreement, or a break of KakaoTalk's grouping
  (`resolveAuthors`), gives `side: unknown`, `author: null`. A sender name exists only in a
  row with a profile button; other static texts (card titles) are content.
- Commands that need every room (`chats`, `send`, `send-image`, `watch`) clear a query left in
  the chat search field first (`ChatListRecoverer.clearLeftoverQuery`) or do nothing.
- Never put real room names, people's names or chat text in code, tests, docs or commit
  messages; use placeholders such as 홍길동 or 테스트방.
- Version: `VERSION` holds `MAJOR.MINOR.PATCH`.

## Commit convention

Conventional commits: `feat(module):`, `fix(module):`, `perf(module):`, `docs:`,
`chore:`; mark breaking changes with `!`.
