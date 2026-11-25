# kktcli Usage

This guide covers installation, first-run setup, every command, output formats, the MCP
server, configuration and troubleshooting. Read the safety and policy section of the
[README](README.en.md#safety-and-policy) first.

## Installation

### Requirements

- macOS 13 or later
- KakaoTalk for Mac (tested only on 26.10.0, build 2010)
- Accessibility permission for the `kktcli` binary you run
- Swift 6 or later to build

### Build from source

```bash
swift build -c release
mkdir -p ~/.local/bin
install -m 0755 .build/release/kktcli ~/.local/bin/kktcli
kktcli --version   # 0.1.0 (based on kmsg 1.260921.0)
```

Make sure `~/.local/bin` is on `PATH`. kktcli has no self-update; rebuild from source to
update. It keeps its own state (see [Local state](#local-state)) and never touches the
files of an installed kmsg.

## Quick start

```bash
kktcli status
```

macOS may open the Accessibility settings pane. Enable the binary you actually run,
then retry `kktcli status`.

```bash
kktcli chats --json --limit 30
kktcli read --chat-id "<chat_id>" --limit 20
```

Preview a send without changing KakaoTalk:

```bash
kktcli send "Chat name" "Hello" --dry-run
```

Only after the user explicitly asked for that exact message to that exact chat, omit
`--dry-run` to send it once.

## Authentication

Commands that need KakaoTalk check the login state. If saved credentials are
unavailable, kktcli prompts in the terminal and stores them locally.

```bash
kktcli auth login          # enter fresh credentials
kktcli auth login --auto   # reuse stored credentials when available
```

The password is encrypted with AES-GCM; the credential document and the key are
stored separately with owner-only permissions:

```text
~/.config/kktcli/credentials.json
~/.config/kktcli/credentials/primary.key
```

### Lock mode

When KakaoTalk's lock screen is showing, commands unlock it before continuing. The
passcode comes from what is stored: the passcode remembered from an earlier unlock,
otherwise the account password saved by `kktcli auth login`; kktcli prompts only when
neither is available. Only one unlock attempt is made per command, because KakaoTalk
signs the account out after repeated wrong passcodes. Typing the passcode needs
KakaoTalk in front; if it is not, nothing is submitted and the stored passcode is kept.

Callers without a terminal (`kktcli mcp-server`, `kktcli watch`, cron) cannot prompt
and depend on stored credentials.

## Command reference

### Global

```bash
kktcli
kktcli --help
kktcli --version   # 0.1.0 (based on kmsg 1.260921.0)
kktcli -v
```

Running `kktcli` without a subcommand runs `status`.

### `status`

```bash
kktcli status [--verbose]
```

Checks Accessibility permission, launches KakaoTalk if needed, verifies the login, and
prints readiness. `--verbose` lists window titles, positions and sizes.

### `auth login`

```bash
kktcli auth login [--auto] [--trace-ax]
```

| Option | Description |
|---|---|
| `--auto` | Use stored credentials when available; otherwise prompt and save. |
| `--trace-ax` | Print AX traversal and retry details to `stderr`. |

### `chats`

```bash
kktcli chats [options]
```

| Option | Description |
|---|---|
| `-v`, `--verbose` | Include the last message preview. |
| `-l N`, `--limit N` | Return at most `N` chats. Default: `20`. |
| `--trace-ax` | Print AX traversal details. |
| `--json` | Return one JSON document. |
| `-k`, `--keep-window` | Keep a chat-list window that the command opened. |

Each entry has a local synthetic `chat_id` (stored in `~/.kktcli/chat-registry.json`),
the title from the row's title label, `has_unread` / `unread_count` from its unread
badge, and the last-message preview (`last_message`; in text output with `--verbose`).
`chats` opens no room, so this preview is the only way kktcli can show an unread message
without marking it read. `kktcli read` opens rooms with `has_unread: true` like any
other, which marks them read (see [Unread rooms](#unread-rooms)).

### `read`

```bash
kktcli read <chat> [options]
kktcli read --chat-id <chat-id> [options]
```

| Option | Description |
|---|---|
| `--chat-id ID` | A `chat_id` from `kktcli chats`. Mutually exclusive with a chat name. |
| `-l N`, `--limit N` | Maximum messages to return (1–50000). Default: `20`. |
| `--json` | Exactly one JSON document on stdout, also on failure. |
| `--skip-unread` | Do not open a room whose chat-list row shows unread messages; fail with `UNREAD_REFUSED` / `UNREAD_UNVERIFIED` (exit status 3) instead, so no read receipts are sent. |
| `--allow-unread` | Deprecated, no effect: unread rooms are opened by default. Kept so old scripts still run. |
| `--scrollback` / `--no-scrollback` | Load older messages when fewer than `--limit` are loaded. Automatic by default; opt-in with `--background-safe`. |
| `--scrollback-timeout SEC` | Time budget for loading older messages (0–600). Default: `4`. Automatic scrollback also stops about 6.5 s after the command started. |
| `--include-system` | Include system messages (joins, notices). |
| `--full-text` | Experimental. Fetch the full text of long messages (see [Long messages](#long-messages)). Not with `--background-safe`. |
| `--background-safe` | Only read an already open chat window; never launch, activate, log in, open, resize or close anything. |
| `-k`, `--keep-window` | Keep a chat window the command opened. |
| `--layout MODE` | `preserve` (default), `left`, `right`, `split-left` or `split-right`. Non-default layouts activate and resize the window. |
| `--deep-recovery` | Allow `open KakaoTalk.app` (activates KakaoTalk) when the main window cannot be reopened otherwise. |
| `--legacy-open` | Open rooms the old way (search typing, row select + Enter, double-click). Input is posted only while KakaoTalk is frontmost. |
| `--debug` | Compact per-message parsing details in text output. |
| `--trace-ax` | Print AX details to `stderr`. |

How a room is opened:

1. An open chat window with the room's title is read in place and left open.
2. Otherwise the row is found in the main window's chat list. For `--chat-id` the
   registry's last known row is checked first and the scan stops at the first match;
   a name query prefers an exact title, then a unique partial match.
3. The row is scrolled into view (scroll-bar value), its context menu is shown, and only
   the item **채팅방 열기** (`openChatRoom:`) is pressed, after re-checking the title (and,
   with `--skip-unread`, the unread badge). No keystrokes or clicks are posted; KakaoTalk
   can stay in the background. Anything unexpected cancels the menu.
4. After reading, the window is closed with its own close button (never Cmd+W). If it
   has none, it is left open and `meta.window` says why.
5. If the row showed an unread badge, the row is read again (see below).

#### Unread rooms

A room whose chat-list row shows an unread badge is opened like any other, exactly as if
you opened it by hand, so the other participants get read receipts. `read --json`
reports the badge in `meta`:

| Field | Meaning |
|---|---|
| `unread_before` | Badge seen on the row right before the room was opened (for example `"안읽음 3"`); `null` when there was none, when the window was already open, or (`--legacy-open`) when the row was not found. |
| `unread_after` | Badge on the same row after the window was closed (with `--keep-window`, after reading); `null` when there is none or the row was not checked. |
| `marked_read` | `true` if the badge seen before is gone, `false` if a badge is still shown, `null` if there was no badge before or the row could not be checked again. |

While the badge is still shown the row is re-read for up to 1.5 s (less when the
automatic time budget is nearly used), because KakaoTalk may clear it a moment after the
window closes. The text output prints the same information as a note on stderr.

`--skip-unread` leaves such rooms unopened: a row showing an unread badge (or a
badge-like number, or a row that could not be read completely) is not opened, and `read`
fails with `UNREAD_REFUSED` or `UNREAD_UNVERIFIED` and exit status `3`. Without
`--skip-unread` a badge that cannot be read does not block the read. Apart from the
last-message preview in `kktcli chats`, kktcli currently has no way to read unread
messages without marking them read. `--allow-unread` is still accepted and has no effect.

#### Long messages

KakaoTalk shows only the first 500 characters of a long message in its bubble, followed
by "…" and a **전체보기** (see all) control. By default kktcli returns that visible part and
marks the message `"truncated": true`; `meta.truncated_messages` counts them. Nothing is
pressed for this.

`--full-text` (experimental, not yet tested against KakaoTalk) fetches the rest: for each
truncated message (at most 20 per read) it presses only that message's 전체보기 control,
re-checked right before the press, reads the full text from what opens (a window, sheet or
popover, or the bubble itself), and closes exactly that again (a window with its close
button, a sheet or popover with AXCancel). The message then has `"truncated": false` and
`"full_text_fetched": true`. When nothing recognisable opens, it is closed and the message
keeps its cut text and `"truncated": true`. `meta.full_text` reports `requested`, `fetched`,
`failures` (`message_index`, `reason`) and `left_open`. On KakaoTalk 26.10.0 the control
has no Accessibility label: kktcli recognises it as the unlabeled button right below a text
that ends in "…" at about 500 characters.

Recovery, only when the wanted row is missing:

- **Filtered chat list.** If a search field is showing, or the list is suspiciously short,
  kktcli presses only the **취소** button inside the search field and the top-bar
  **검색** toggle (for a hidden filter the toggle is pressed first to reveal the old
  query), then scans once more. Nothing is typed and Enter is never sent.
  `meta.list_recovery` lists what was pressed.
- **Closed main window.** kktcli presses only KakaoTalk's menu item **카카오톡 열기**
  (`showFirstWindow:`) and waits for the main window; this brings KakaoTalk to the front.
  `open KakaoTalk.app` is used only with `--deep-recovery`. Reported as
  `meta.main_window`.

Message fields: `author` is `"(me)"` for your own messages and `null` when the sender
cannot be established (system lines, banners); `side` is `me`, `other`, `unknown` or
`system`. `date` comes from the transcript's date separators. KakaoTalk prints a time
only on the last message of a same-author run, so earlier messages of the run take that
time with `time_source: "inferred"`; messages with their own label have
`time_source: "label"`.

Ctrl-C or `SIGTERM` after login stops early, still closes a window the command opened,
and prints what was read with `meta.interrupted: true`.

### `watch`

```bash
kktcli watch <chat> [options]
```

| Option | Description |
|---|---|
| `--poll-interval S` | Poll interval in seconds. Default: `0.2` (clamped to 0.2–10). |
| `--json` | One pretty-printed JSON object per event. |
| `--include-system` | Include system rows. |
| `-k`, `--keep-window` | Keep a chat window opened by the command. |
| `--deep-recovery` | Deeper window recovery. |
| `--trace-ax` | Print AX details. |

`watch` opens the room through KakaoTalk's search when it is not open (this needs
KakaoTalk in front; keystrokes are posted only while it is). At startup it stabilizes a
baseline for up to two seconds and does not replay the existing history. Stop it with
Ctrl-C or `SIGTERM`.

### `send`

```bash
kktcli send <recipient> <message> [options]
kktcli send --chat-id <chat-id> <message> [options]
```

| Option | Description |
|---|---|
| `--chat-id ID` | A `chat_id` from `kktcli chats`. |
| `--dry-run` | Print the target and message without touching KakaoTalk. |
| `--no-cache` | Do not use the AX path cache. |
| `--refresh-cache` | Clear the relevant cached paths first. |
| `-k`, `--keep-window` | Keep windows opened by the command. |
| `--deep-recovery` | Deeper window recovery. |
| `--trace-ax` | Print AX details. |

Sending needs keystrokes (Enter). kktcli brings KakaoTalk to the front and posts input
only while KakaoTalk is verifiably frontmost; otherwise it stops with `NOT_FRONTMOST`,
clears the unsent text from the input field, and sends nothing. Send one message per
explicit request. Never use it for bulk messaging.

### `send-image`

```bash
kktcli send-image <recipient> <image-path> [options]
```

Options: `--no-cache`, `-k`/`--keep-window`, `--deep-recovery`, `--trace-ax`. The image is
placed on the pasteboard and pasted with Cmd+V (only while KakaoTalk is frontmost).
There is no dry run.

### `inspect`

```bash
kktcli inspect [options]
```

| Option | Description |
|---|---|
| `-d N`, `--depth N` | Maximum hierarchy depth. Default: `4`. |
| `-w N`, `--window N` | Inspect a window by zero-based index. |
| `--show-attributes`, `--show-path`, `--show-frame`, `--show-index`, `--show-flags`, `--show-actions` | Extra detail. |
| `--debug-layout` | Path, frame, index and state together. |
| `--row-summary`, `--row-range A:B` | Message-row parsing diagnostics. |

### `cache`

```bash
kktcli cache [status | clear | export <path> | import <path> | warmup [--recipient NAME]]
```

Manages the AX path cache (`~/.kktcli/ax-cache.json`) used by `send` and the legacy
paths. `kktcli cache` alone runs `status`.

### `mcp-server`

```bash
kktcli mcp-server
```

Starts a stdio MCP server (Content-Length framing or one JSON-RPC request per line).
Each tool call runs the same `kktcli` binary as a subprocess.

| Tool | Purpose |
|---|---|
| `kktcli_read` | Read by `chat` or `chat_id`. Options: `limit` (1–500), `skip_unread` (default `false`; `allow_unread` is accepted and ignored), `scrollback` (true/false; omit for automatic), `scrollback_timeout` (seconds), `include_system`, `background_safe`, `keep_window`, `layout`, `deep_recovery`, `trace_ax`. |
| `kktcli_send` | Send a text message by chat name. |
| `kktcli_send_image` | Send a local image by chat name. |

A read call times out after 8 s (15 s with `deep_recovery`); an explicit
`scrollback: true` extends that by `scrollback_timeout` plus 2 s. Failed reads return
the code kktcli reported (see [Error codes](#error-codes)) with its message, hint and
details; `meta.read` of a successful read carries kktcli's own `meta`.

For the send tools, `confirm=false` or an omitted `confirm` sends immediately;
`confirm=true` returns `CONFIRMATION_REQUIRED` without sending, so a supervisor can ask
the user first.

Example client configuration:

```json
{
  "mcpServers": {
    "kktcli": {
      "command": "/Users/<you>/.local/bin/kktcli",
      "args": ["mcp-server"],
      "env": {
        "KKTCLI_DEFAULT_BACKGROUND_SAFE": "false",
        "KKTCLI_TRACE_DEFAULT": "false"
      }
    }
  }
}
```

## JSON output

All JSON is written to stdout with sorted keys; `--trace-ax` diagnostics go to stderr.

### `chats --json`

```json
{
  "chats": [
    {
      "chat_id": "chat_7f42c5e1d9ab",
      "has_unread": true,
      "last_message": "곧 도착해요",
      "title": "홍길동",
      "unread_count": 2
    }
  ],
  "count": 1
}
```

### `read --json`

```json
{
  "chat": "홍길동",
  "chat_id": null,
  "count": 1,
  "fetched_at": "2026-11-24T01:23:45.678Z",
  "messages": [
    {
      "attachment_count": 0,
      "author": "홍길동",
      "body": "밤이 깊었네",
      "date": "2026-11-24",
      "edited": false,
      "full_text_fetched": false,
      "has_attachment": false,
      "has_image": false,
      "image_count": 0,
      "kind": "message",
      "link_count": 0,
      "side": "other",
      "time": "00:27",
      "time_raw": "오전 12:27",
      "time_source": "label",
      "truncated": false,
      "unread_count": null
    }
  ],
  "meta": {
    "date_from_earlier_separator": false,
    "full_text": null,
    "interrupted": false,
    "list_recovery": null,
    "main_window": null,
    "marked_read": null,
    "opened_via": "chat_list_menu",
    "row_title": "홍길동",
    "rows_read": 84,
    "rows_total": 84,
    "scrollback": null,
    "truncated_messages": 0,
    "unread_after": null,
    "unread_before": null,
    "window": "closed",
    "window_detail": null,
    "window_title_empty": false
  },
  "ok": true
}
```

`chat` is the window title; `meta.row_title` is the chat-list title, which differs for
team chats, the self chat and open chats (`팀채팅, <name>` and `오픈채팅, <name>` open a
window titled `<name>`). Open chats can open a window with an empty title on KakaoTalk
26.10.0: kktcli accepts it only as the single window that appeared after its own press and
that shows a transcript or message input, then reports `meta.window_title_empty: true` and
uses `<name>` as `chat`. `meta.opened_via` is
`existing_window`, `chat_list_menu`, `legacy_chat_list` or `legacy_search`;
`meta.window` is `untouched`, `closed`, `kept_open` or `left_open`. `meta.unread_before`,
`meta.unread_after` and `meta.marked_read` are described under
[Unread rooms](#unread-rooms).

### Errors

`kktcli read 가족 --skip-unread --json` for a room with unread messages:

```json
{
  "chat": "가족",
  "chat_id": null,
  "details": { "unread_before": "안읽음 2" },
  "error": {
    "code": "UNREAD_REFUSED",
    "hint": "Run without --skip-unread to open it; that sends read receipts like opening it by hand.",
    "message": "'가족' shows unread messages (안읽음 2); --skip-unread does not open it because that would send read receipts."
  },
  "ok": false
}
```

### Error codes

| Code | Exit | Meaning |
|---|---:|---|
| `INVALID_ARGUMENT` | 64 | Bad or conflicting arguments (also argument parse errors with `--json`). |
| `UNREAD_REFUSED` | 3 | Only with `--skip-unread`: the row shows unread messages; not opened. |
| `UNREAD_UNVERIFIED` | 3 | Only with `--skip-unread`: the row could not be read completely, or the legacy path could not find it; not opened. |
| `UNKNOWN_CHAT_ID` | 1 | The `chat_id` is not in the registry; run `kktcli chats`. |
| `CHAT_NOT_IN_LIST` | 1 | No chat-list row matches (after list recovery, if any). |
| `AMBIGUOUS_CHAT` | 1 | Several rows match a partial name equally well. |
| `CHAT_LIST_UNAVAILABLE` | 1 | The main window shows no chat list (e.g. another tab). |
| `WINDOW_NOT_READY` | 1 | The main window could not be found or reopened. |
| `MAIN_WINDOW_MINIMIZED`, `KAKAO_HIDDEN` | 1 | Restore KakaoTalk's window first. |
| `ROW_NOT_VISIBLE` | 1 | The row could not be scrolled into view. |
| `ROW_CHANGED` | 1 | The list reordered while opening; retry. |
| `MENU_UNAVAILABLE`, `MENU_ITEM_MISSING`, `MENU_ITEM_BLOCKED` | 1 | The context menu could not be used; nothing was pressed. |
| `CHAT_WINDOW_NOT_OPENED` | 1 | No window was recognised as the room after 채팅방 열기. Every window that appeared after the press is closed with its close button; `details` lists them (`unexpected_new_windows`, untitled ones as `(untitled)`; `closed_new_windows`; `left_open_windows`). |
| `TRANSCRIPT_UNAVAILABLE` | 1 | The window has no readable transcript. |
| `BACKGROUND_SAFE_BLOCKED` | 1 | `--background-safe` and no matching open window. |
| `ACCESSIBILITY_PERMISSION_DENIED`, `KAKAO_NOT_RUNNING`, `KAKAO_LAUNCH_FAILED`, `KAKAO_UNAVAILABLE`, `KAKAO_AUTH_FAILED` | 1 | Setup or login problem. |
| `NOT_FRONTMOST`, `SEARCH_MISS`, `FOCUS_FAIL`, `INPUT_NOT_REFLECTED`, `LEGACY_OPEN_FAILED` | 1 | `--legacy-open` failures. |
| `INTERRUPTED` | 130 | Stopped before a room was opened. |

## Configuration

### Environment variables

| Variable | Default | Behavior |
|---|---:|---|
| `KKTCLI_AX_TIMEOUT` | `0.25` | Default AX messaging timeout in seconds (0.05–5.0). |
| `KKTCLI_DEFAULT_DEEP_RECOVERY` | `false` | Default `deep_recovery` for MCP tools. |
| `KKTCLI_DEFAULT_BACKGROUND_SAFE` | `false` | Default `background_safe` for `kktcli_read`. |
| `KKTCLI_TRACE_DEFAULT` | `false` | Default `trace_ax` for MCP tools. |
| `KKTCLI_DEFAULT_READ_LAYOUT` | `preserve` | Default MCP read layout. |
| `KKTCLI_MCP_STARTUP_STATUS_CHECK` | `false` | When `true`, MCP initialization also runs `kktcli status`. |
| `KKTCLI_MCP_VERSION` | build version | Overrides the MCP server version metadata. |

### Local state

| Path | Contents |
|---|---|
| `~/.config/kktcli/credentials.json` | Encrypted credential document. |
| `~/.config/kktcli/credentials/primary.key` | Local AES-GCM key. |
| `~/.kktcli/chat-registry.json` | Synthetic chat identities and last seen rows. |
| `~/.kktcli/ax-cache.json` | Cached AX paths. |

These files contain private data. Do not publish them or attach them to issues. kktcli
never reads or writes `~/.kmsg` or `~/.config/kmsg`.

## Troubleshooting

### Accessibility permission is not granted

Run `kktcli status`, then enable the exact `kktcli` binary under **System Settings →
Privacy & Security → Accessibility**. A rebuilt or moved binary may need to be added
again.

### `UNREAD_REFUSED`

`--skip-unread` was given and the room has unread messages, so it was not opened. Run
without `--skip-unread` to read it; that sends read receipts, as opening it by hand
would. To see the newest message without marking anything read, use the `last_message`
preview from `kktcli chats --json`.

### `CHAT_NOT_IN_LIST` or a wrong room

Refresh the registry with `kktcli chats --json` and use the `chat_id`. A renamed room
gets a new identity. Make sure the main window shows the 채팅 tab.

### Messages cannot be parsed

```bash
kktcli inspect --window 0 --depth 20 --row-summary
kktcli read "Chat name" --trace-ax
```

Remove private message content before sharing any output.

### MCP initialization fails

```bash
kktcli --version
kktcli status
```

The MCP server skips the interactive status check by default; set
`KKTCLI_MCP_STARTUP_STATUS_CHECK=true` to validate KakaoTalk at startup.

## Development

```bash
swift build
swift build -c release
.build/debug/kktcli --version
make test-core                      # pure-logic unit tests (never touch KakaoTalk)
python3 -m unittest discover -s tests -p "test_*.py"   # source contract tests
```

`make test-core BUILD_PATH=<dir>` builds into another directory. The version comes from
the `VERSION` file (`MAJOR.MINOR.PATCH`); `--version` prints it together with the
upstream release, e.g. `0.1.0 (based on kmsg 1.260921.0)`.
