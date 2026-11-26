# Changelog

All notable changes to kktcli. Versions follow `MAJOR.MINOR.PATCH` (see `VERSION`);
breaking changes are marked **BREAKING**.

## 0.2.0 — 2026-11-26

### Chat IDs
- **BREAKING** Same-name rooms are never paired by list position any more. A chat_id is
  kept only on an exact preview match or by one-to-one elimination; otherwise the old IDs are
  retired and the rows get new ones. A retired ID fails with `CHAT_ID_STALE` (exit 5) instead
  of reaching another room; a chat_id that cannot be told apart from same-name rooms fails
  with `CHAT_AMBIGUOUS` (exit 6) and lists the candidates. Fixes chat_ids swapping between
  same-name rooms, which could make `send --chat-id` reach the wrong person.
- The registry (`~/.kktcli/chat-registry.json`) moves to schema 2; existing IDs are kept.

### Reading, keeping and exporting
- Read messages are kept in `~/.kktcli/messages/<chat_id>.jsonl` (plain text, directory
  0700, files 0600); `read --no-save` skips it, `kktcli store clear` deletes it.
- New `kktcli search` over the kept messages.
- New `kktcli export` (Markdown by default, `--format json|csv`; CSV has a BOM for Excel on
  the Mac) with `--chat-id`, `--since`, `--until`, `--author`, `--grep`, `--out`.
- New `templates/방-요약.md`, a one-page room digest frame teams can copy and edit.
- New `read --all-history`: scrolls up until the top of KakaoTalk's local history or until no
  more rows load (120 s budget, `--scrollback-timeout`), without a message limit. New
  `meta.history` (`complete`, `stopped`, `earliest_date`). Older messages need the user's own
  "지난 대화 보기" authentication in KakaoTalk; kktcli never presses it.

### Chat list
- Fixed: `chats` could read the 친구 tab as the chat list and write friends into the chat_id
  registry. The main window's table is now checked to be the chat list before `chats`,
  `read`, `send`, `watch --all` or any registry write uses it. On another tab kktcli presses
  KakaoTalk's 창 > 채팅 (⌘2) menu item once (through the activity guard; never 친구 or
  더보기) and reports `meta.main_window: "switched_to_chat_tab"`; otherwise it fails with
  `CHAT_LIST_UNAVAILABLE` and records nothing. List recovery never presses anything on a
  table that is not the chat list. A registry already polluted this way is not cleaned
  automatically: delete `~/.kktcli/chat-registry.json` to start over.
- Fixed: `watch --all` reported `main_window_not_visible` with `kakao_frontmost: false` when
  the main window was visible but showed another tab; it now reports `not_chat_tab` (and
  `chat_list_visible` once the list is back) and the real frontmost state.

### Watching
- **BREAKING** `watch <chat>` opens the room like `read` (activity guard, main-window policy,
  chat-list menu) instead of search and Enter, and never activates KakaoTalk by itself;
  `--poll-interval` now defaults to 1 s.
- New `watch --all`: polls the top chat-list rows (30, every 3 s) without clicking or
  scrolling and prints one JSON line per change (`new_message`, `unread_changed`,
  `new_room`); `--read` reads the changed rooms; `--duration`, `--count`.

### Sending
- **BREAKING** `send` and `send-image` go through the same activity guard, main-window policy
  and chat-list menu as `read` (no unconditional activate, no search/Enter, no blind-typing
  fallback). `send --preview` (`--dry-run` is an alias) sends nothing and shows the target,
  the last messages, a same-name warning and the exact text. Same-name rooms need a chat_id
  that resolves to exactly one row.
- **BREAKING** Sending is off by default. New `kktcli config get send` / `kktcli config set
  send on|off` (`~/.config/kktcli/config.json`); while off, `send` and `send-image` (except
  `--preview`) fail with `SEND_DISABLED` (exit 9) before touching KakaoTalk.
- A real send puts the text into the room's input box, re-checks right before the press that
  the same window still shows the same room, presses the room's own 전송 button once and
  verifies the new bubble. A draft already in the input box is never overwritten. There is
  no confirmation dialog.
- send-image restores the clipboard and the previously frontmost app.

### MCP
- **BREAKING** `kktcli_send` / `kktcli_send_image` are listed only while sending is on (a
  call while it is off returns `SEND_DISABLED`); `confirm` is removed; `mode` is `preview`
  (default, sends nothing) or `send`; results report `sent`, `cancelled` and
  `bubble_verified`.

### Install
- `install.sh` installs a release tarball after checking its SHA-256 (arm64), or builds from
  source; `make dist` builds `kktcli-<version>-macos-arm64.tar.gz` and its `.sha256`.

### Exit statuses
- New: 5 `CHAT_ID_STALE`, 6 `CHAT_AMBIGUOUS`, 8 send failures, 9 `SEND_DISABLED`.
  Unchanged: 3 refused (`--skip-unread`), 4 `OPEN_CHAT_LIST`, 64 usage, 75
  `KAKAOTALK_IN_USE`, 130 interrupted.

## 0.1.0 — 2026-11-25

First kktcli release, forked from kmsg 1.260921.0: rooms opened through the chat-list menu
without keystrokes, structured transcript parsing, unread rooms opened by default with
`--skip-unread`, long-message detection and experimental `--full-text`, batch reads, the
user-activity guard (`KAKAOTALK_IN_USE`), the main-window policy (`MAIN_WINDOW_NOT_VISIBLE`),
open-chat list detection (`OPEN_CHAT_LIST`), its own data directories and no network code.
