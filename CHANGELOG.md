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
- **BREAKING** A real send always shows a macOS confirmation dialog (room, last messages,
  full text): 취소 is the default, 보내기 counts only for a real mouse click after 1 s, and it
  cancels itself after 120 s (`SEND_CANCELLED`, exit 7). No option skips it. The text is then
  put into the room's input box and its own 전송 button is pressed once; the new bubble is
  verified. A draft already in the input box is never overwritten.
- send-image restores the clipboard and the previously frontmost app.

### MCP
- **BREAKING** `kktcli_send` / `kktcli_send_image`: `confirm` is removed; `mode` is
  `preview` (default, sends nothing) or `send`; results report `sent`, `cancelled` and
  `bubble_verified`.

### Install
- `install.sh` installs a release tarball after checking its SHA-256 (arm64), or builds from
  source; `make dist` builds `kktcli-<version>-macos-arm64.tar.gz` and its `.sha256`.

### Exit statuses
- New: 5 `CHAT_ID_STALE`, 6 `CHAT_AMBIGUOUS`, 7 `SEND_CANCELLED`, 8 other send failures.
  Unchanged: 3 refused (`--skip-unread`), 4 `OPEN_CHAT_LIST`, 64 usage, 75
  `KAKAOTALK_IN_USE`, 130 interrupted.

## 0.1.0 — 2026-11-25

First kktcli release, forked from kmsg 1.260921.0: rooms opened through the chat-list menu
without keystrokes, structured transcript parsing, unread rooms opened by default with
`--skip-unread`, long-message detection and experimental `--full-text`, batch reads, the
user-activity guard (`KAKAOTALK_IN_USE`), the main-window policy (`MAIN_WINDOW_NOT_VISIBLE`),
open-chat list detection (`OPEN_CHAT_LIST`), its own data directories and no network code.
