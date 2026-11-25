# AGENTS.md

Guidance for coding agents working in this repository (also read as CLAUDE.md).

## Build

```bash
swift build                      # debug
swift build -c release           # release
.build/debug/kktcli --version    # 0.1.0 (based on kmsg 1.260921.0)
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
Sources/kktcli/Accessibility  AX wrappers, batched reads, input guard, permission
Sources/KktcliCore            pure parsing / policy logic (unit tested)
tests/KktcliCoreTests         Swift Testing unit tests
tests/*.py                    contract tests
skills/kktcli                 agent skill
```

See [ARCHITECTURE.md](ARCHITECTURE.md) for the design.

## KakaoTalk for Mac 26.10 UI notes

```
Main window (identifier "Main Window"):
└── AXScrollArea > AXTable > AXRow > AXCell
    _NS:40 title, Count Label member count, _NS:69 time, _NS:87/_NS:91 preview,
    _NS:138 unread badge ("안읽음 N"); the cell supports AXShowMenu
    (menu item openChatRoom: "채팅방 열기")

Chat window (title = room name; team chats drop the "팀채팅, " row prefix):
├── AXScrollArea _NS:32 > AXTable > AXRow (transcript)
└── AXTextArea _NS:51 "메시지 입력"
```

## Rules

- Bundle ID: `com.kakao.KakaoTalkMac`. Data lives in `~/.kktcli` and `~/.config/kktcli`;
  never read or write `~/.kmsg` or `~/.config/kmsg`.
- No network code in `Sources`.
- The read path must not post keyboard or mouse events. Any code that posts them goes
  through `AXActionRunner`, which checks `KakaoTalkInputGuard` before every press.
- Press only allowlisted elements and re-verify them right before the press.
- `read` opens rooms with unread messages, which sends read receipts like opening them
  by hand; `--skip-unread` leaves them unopened (`UNREAD_REFUSED`, exit status 3) and
  `--allow-unread` is a deprecated no-op. Keep `meta.unread_before`, `unread_after` and
  `marked_read` truthful (null when not checked).
- Keep `read --json` output to exactly one JSON document on stdout.
- Version: `VERSION` holds `MAJOR.MINOR.PATCH`.

## Commit convention

Conventional commits: `feat(module):`, `fix(module):`, `perf(module):`, `docs:`,
`chore:`; mark breaking changes with `!`.
