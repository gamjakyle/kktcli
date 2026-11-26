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

### Install a release (Apple silicon)

```bash
curl -fsSL https://raw.githubusercontent.com/gamjakyle/kktcli/main/install.sh | bash   # the latest release
curl -fsSL https://raw.githubusercontent.com/gamjakyle/kktcli/main/install.sh | bash -s -- --version 0.2.0
```

`install.sh` downloads `kktcli-<version>-macos-arm64.tar.gz` and its `.sha256` from the
GitHub release (without `--version`, `KKTCLI_VERSION` or a checkout's `VERSION` file: the
latest release, found from where `releases/latest` redirects), installs only if the SHA-256 matches, and puts `kktcli` in `~/.local/bin`.
On other Macs, when the download fails, or with `--from-source` it builds from a checkout
instead. It then prints the Accessibility steps. `make dist` builds the release files.

### Build from source

```bash
swift build -c release
mkdir -p ~/.local/bin
install -m 0755 .build/release/kktcli ~/.local/bin/kktcli
kktcli --version   # 0.2.0 (based on kmsg 1.260921.0)
```

Make sure `~/.local/bin` is on `PATH`. kktcli has no self-update; install a newer release
or rebuild from source to update. It keeps its own state (see [Local state](#local-state)) and never touches the
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

Preview a send (nothing is sent):

```bash
kktcli send --chat-id "<chat_id>" "Hello" --preview
```

Sending is off until `kktcli config set send on`. Only after the user explicitly asked for
that exact message to that exact chat, omit `--preview` to send it once.

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
kktcli --version   # 0.2.0 (based on kmsg 1.260921.0)
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
| `-k`, `--keep-window` | No effect (kept for compatibility). A main window opened with 창 > 채팅 is left open. |
| `--idle-seconds SEC` | While KakaoTalk is in front, press nothing that opens or brings up a KakaoTalk window until the keyboard and mouse were idle this long (0–600). Default: `10`. See [Desktops and the activity guard](#desktops-and-the-activity-guard). |
| `--wait-for-idle SEC` | Wait at most this long for that, then fail with `KAKAOTALK_IN_USE` (0–600; `0` fails at once). Default: `30`. |
| `--allow-activate` | When KakaoTalk's main window can be found on no desktop and not opened with 창 > 채팅, allow 카카오톡 열기 even though that brings KakaoTalk to the front and may switch desktops. |

Each entry has a local synthetic `chat_id` (stored in `~/.kktcli/chat-registry.json`),
the title from the row's title label, `has_unread` / `unread_count` from its unread
badge, and the last-message preview (`last_message`; in text output with `--verbose`).
`chats` opens no room, so this preview is the only way kktcli can show an unread message
without marking it read. `kktcli read` opens rooms with `has_unread: true` like any
other, which marks them read (see [Unread rooms](#unread-rooms)).

Rooms whose names are the same after removing spaces and punctuation keep their chat_ids by
their exact title, then by preview + time + member count, then by preview, then when only
one room and one ID are left; never by list position. Rooms identical in all of these get
`chat_id: null` (`read` cannot tell them apart; their earlier IDs answer `CHAT_AMBIGUOUS`).
When a room cannot be matched any more its old ID is retired (`CHAT_ID_STALE`) and it gets
a new one.

### `read`

```bash
kktcli read <chat> [options]
kktcli read --chat-id <chat-id> [options]
kktcli read --chat-id <a> --chat-id <b> ... [options]
kktcli read --chat-ids-file <file> [options]
```

| Option | Description |
|---|---|
| `--chat-id ID` | A `chat_id` from `kktcli chats`. Mutually exclusive with a chat name. Repeat it to read several chats in one run. |
| `--chat-ids-file PATH` | Read every `chat_id` in the file, one per line (blank lines and `#` lines are ignored). |
| `-l N`, `--limit N` | Maximum messages to return (1–50000). Default: `20`. |
| `--json` | Exactly one JSON document on stdout, also on failure. |
| `--skip-unread` | Do not open a room whose chat-list row shows unread messages; fail with `UNREAD_REFUSED` / `UNREAD_UNVERIFIED` (exit status 3) instead, so no read receipts are sent. |
| `--allow-unread` | Deprecated, no effect: unread rooms are opened by default. Kept so old scripts still run. |
| `--scrollback` / `--no-scrollback` | Load older messages when fewer than `--limit` are loaded. Automatic by default; opt-in with `--background-safe`. |
| `--scrollback-timeout SEC` | Time budget for loading older messages (0–600). Default: `4`. Automatic scrollback also stops about 6.5 s after the command started. |
| `--include-system` | Include system messages (joins, notices). |
| `--no-save` | Do not keep the messages read in the [local message store](#local-message-store). |
| `--all-history` | Read everything KakaoTalk has locally: scroll up until the top of the local history or until no more rows load (budget 120 s, `--scrollback-timeout` overrides it), with no `--limit`. See `meta.history`. |
| `--full-text` | Experimental. Fetch the full text of long messages (see [Long messages](#long-messages)). Not with `--background-safe`. |
| `--idle-seconds SEC` | While KakaoTalk is in front, press nothing that opens or brings up a KakaoTalk window until the keyboard and mouse were idle this long (0–600). Default: `10`. See [Desktops and the activity guard](#desktops-and-the-activity-guard). |
| `--wait-for-idle SEC` | Wait at most this long for that, then fail with `KAKAOTALK_IN_USE` (0–600; `0` fails at once). Default: `30`. |
| `--allow-activate` | When KakaoTalk's main window can be found on no desktop and not opened with 창 > 채팅, allow 카카오톡 열기 even though that brings KakaoTalk to the front and may switch desktops. |
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

#### Desktops and the activity guard

**Another desktop or full-screen Space.** Accessibility's window list shows only the
windows on the current desktop, so a main window on another desktop or Space looks exactly
like a closed one. `read`, `chats`, `watch`, `send --preview` and list recovery look for it
in this order, and never bring KakaoTalk to the front unless you allow it:

1. The current desktop, looked at again for about 0.6 s with longer Accessibility timeouts
   (a busy KakaoTalk, for example right after a window closed, can fail a single read).
2. Another desktop or Space: the window is looked up by its Accessibility element id
   (the technique window switchers such as AltTab use) and read where it is; nothing is
   pressed and your desktop does not change. `meta.main_window` is `other_desktop`. The id
   is cached in `~/.kktcli/main-window-id.json`; without it a search takes about 2 s (at most 4 s). This uses a
   private macOS function looked up at run time; where it is missing, this step is skipped.
   `KKTCLI_NO_ELEMENT_ID_SCAN=1` turns it off.
3. Closed (the window server shows no KakaoTalk window that could be it): KakaoTalk's own
   창 menu item **채팅** (⌘2), which opens the main window on the current desktop, on the
   chat tab, without bringing KakaoTalk to the front (`opened_via_window_menu`). It waits
   like opening a room (below) and is re-checked right before the press.
4. **카카오톡 열기**, which brings KakaoTalk to the front and may switch your desktop, only
   with `--allow-activate` (then `open KakaoTalk.app` with `--deep-recovery`).
5. Otherwise `MAIN_WINDOW_NOT_VISIBLE`; nothing was pressed. Its `details` give
   `kakao_frontmost`, `ax_window_count`, `element_id_scan` (what the id lookup did), the
   window server's layer-0 KakaoTalk window counts (`cg_layer0_window_count`,
   `cg_layer0_offscreen_count`) and `cg_unaccounted_window_count`, the windows kktcli could
   not reach.

Since KakaoTalk is logged in when its main window is found on another desktop, the login
check (which would bring KakaoTalk to the front) is skipped then. A room opened from a main
window on another desktop may open on that desktop; kktcli looks for it there too and
closes it with its close button. `send` and `send-image` preview such a room but do not send
to a window on another desktop (`SEND_TARGET_UNCERTAIN`).

**While you use KakaoTalk.** When KakaoTalk is in front, a window opened by 채팅방 열기 or
전체보기 becomes the key window: what you are typing goes into that room, and Enter would
send it there. So while KakaoTalk is (or may be) in front and the keyboard or mouse was used
less than `--idle-seconds` ago (default 10), kktcli presses nothing that opens or brings up
a KakaoTalk window: the room's context menu and 채팅방 열기, 전체보기, the list recovery
buttons, 창 > 채팅, the legacy open, and each chat of a batch. 카카오톡 열기 activates KakaoTalk, so
it always waits for an idle user, whatever app is in front. kktcli checks every 0.5 s and
goes on as soon as KakaoTalk is in the background or idle; the check is repeated right before
each press. After `--wait-for-idle` seconds (default 30) it gives up with `KAKAOTALK_IN_USE`
(exit status 75) and presses nothing. `meta.waited_for_user_ms` is the time spent waiting;
it does not count against the automatic scrollback budget. The idle time is the system's
time since the last keyboard or mouse input and needs no extra permission. When KakaoTalk is
in the background, opening rooms leaves it there.

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

**Open-chat conversation lists (known limitation).** Some "오픈채팅, …" rows (1:1 open
chats) do not open a chat but an untitled window listing the 1:1 conversations, possibly
none. kktcli recognises that window by its structure (header image, list table, no
transcript and no input), presses nothing in it, closes it with its close button and fails
with `OPEN_CHAT_LIST` (exit status 4); `details` give `opened` (`true`),
`conversation_count` and `conversations` (each title and time). A row whose chat-list
preview is exactly "대화 중인 오픈채팅방이 없습니다." is not opened at all: the same code
with `opened: false` and `conversation_count: 0`. Reading those conversations is not
supported.

**The chat list is checked first.** kktcli reads the main window's list as the chat list
only when it is a table (the 친구 tab's list is an outline and never counts) and its first
rows look like chat-list rows (title plus a time or a preview). On another tab (for example
친구) it presses KakaoTalk's own 창 menu item 채팅 (⌘2) once, after the activity guard; only
if that menu item is missing, the main window's `chatrooms` tab button instead (not yet
tried live). It never presses 친구 or 더보기, and waits up to 2 s for the chat list
(`meta.main_window` then includes `switched_to_chat_tab`; several values are joined with a
comma, for example `other_desktop,switched_to_chat_tab`). If the chat list still does not show,
it fails with `CHAT_LIST_UNAVAILABLE` and reads and records nothing; list recovery never
presses anything on a table that is not the chat list.

**History.** `meta.history` is `{complete, stopped, earliest_date}`. `stopped` is `top` (the
top of KakaoTalk's local history is loaded; `complete` is true), `stalled` (no more rows
loaded), `timeout`, `limit` (`--limit` messages returned) or `not_attempted` (no scrollback).
Messages older than the local history sit behind KakaoTalk's "지난 대화 보기", which needs
your own authentication; kktcli never presses it. `--all-history` reads up to that point.

Recovery, only when the wanted row is missing:

- **Filtered chat list.** If a search field is showing, or the list is suspiciously short,
  kktcli presses only the **취소** button inside the search field and the top-bar
  **검색** toggle (for a hidden filter the toggle is pressed first to reveal the old
  query), then scans once more. Nothing is typed and Enter is never sent.
  `meta.list_recovery` lists what was pressed.
- **Closed main window.** See [Desktops and the activity guard](#desktops-and-the-activity-guard):
  창 > 채팅 first, 카카오톡 열기 only with `--allow-activate`, `open KakaoTalk.app` only
  with `--deep-recovery` as well. Reported as `meta.main_window`.

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
kktcli watch --chat-id <chat-id> [options]     # one chat
kktcli watch <chat> [options]                  # one chat by its (unique) name
kktcli watch --all [--top 30] [--read]         # the top of the chat list
```

| Option | Description |
|---|---|
| `--all` | Watch the top chat-list rows instead of one chat. Reads only: no scrolling, no clicks. |
| `--top N` | Rows to watch with `--all` (1–200). Default: `30`. |
| `--read` | With `--all`: open each changed room (activity guard, chat-list menu; read receipts are sent as when you open it), print its newest messages and keep them in the local store. |
| `--poll-interval S` | Seconds between polls (0.2–3600). Default: `1`, or `3` with `--all`. |
| `--duration S` | Stop after this many seconds. |
| `--count N` | Stop after this many events. |
| `--json` | One JSON object per line. |
| `--include-system` | Include system rows (one chat). |
| `-k`, `--keep-window` | Keep a chat window kktcli opened. |
| `--idle-seconds`, `--wait-for-idle`, `--allow-activate` | As for `read`. |
| `--trace-ax` | Print AX details. |

One chat is opened like `read` (activity guard, main-window policy, chat-list menu; no
search typing, no Enter, no activation) and polled; new messages are printed as
`{"event": "message", "chat", "chat_id", "message", "gap", "detected_at"}`, where `gap` is
true when the previous messages could not be found again (everything shown is new to the
watch). `--all` prints `{"event": "change", "change", "chat_id", "title", "preview", "time",
"unread", "detected_at"}` with `change` = `new_message`, `unread_changed` or `new_room`; the
first poll is the baseline and prints nothing. A main window on another desktop is read
there (`{"event": "status", "status": "main_window", "location": "other_desktop"}` when that
changes). When it cannot be found it prints `{"event": "status", "status":
"main_window_not_visible", ...}` once and keeps polling; it never opens the window. When the main window shows another tab it prints
`not_chat_tab` (it never switches tabs itself) and `chat_list_visible` when the chat list is
back. Stop with `--duration`, `--count`, Ctrl-C or
`SIGTERM`; a window kktcli opened is closed again.

### `send`

```bash
kktcli send --chat-id <chat-id> <message> [--preview] [options]
kktcli send <chat> <message> [--preview] [options]
```

| Option | Description |
|---|---|
| `--preview` (alias `--dry-run`) | Send nothing; open the room like `read` and show who it goes to, the last 3 messages, a same-name warning, the exact text with line and character counts, and the method. |
| `--json` | One JSON document (`ok`, `mode`, `sent`, `cancelled`, `bubble_verified`, `preview`, `window`, `method`, `error`, `details`). |
| `-k`, `--keep-window` | Keep the chat window if kktcli opened it. |
| `--idle-seconds`, `--wait-for-idle` | As for `read`. |
| `--allow-activate` | Allow bringing KakaoTalk to the front: 카카오톡 열기 when the main window can be found on no desktop and not opened with 창 > 채팅, and the Enter fallback below. |
| `--trace-ax` | Print AX details. |

Sending is off by default: until `kktcli config set send on`, everything but `--preview`
fails with `SEND_DISABLED` (exit 9) before KakaoTalk is touched. The room is found and
opened like `read` (activity guard, main-window policy, verified chat list, chat-list menu;
no search typing). A `chat_id` must point at exactly one row; a name must be unique; when
other rooms share the name, a window of that name that was already open is refused
(`SEND_TARGET_UNCERTAIN`). Without `--preview` kktcli refuses to overwrite a draft in the
input box, puts the text in with AXValue, checks again right before the press that the same
window still shows the same room, presses the room's own 전송 button once and verifies the
new outgoing bubble. If the button is missing or stays disabled, the input is cleared and
nothing is sent (`SEND_BUTTON_UNAVAILABLE`), unless `--allow-activate` allows an Enter
fallback (KakaoTalk is brought to the front, Enter goes through the frontmost check, and the
previous app is brought back). Failures once a send started exit with 8. One message per
run; never use it for bulk messaging.

### `send-image`

```bash
kktcli send-image --chat-id <chat-id> <image-path> [--preview] [options]
kktcli send-image <chat> <image-path> [--preview] [options]
```

The same setting, preview (with the file name and size) and checks. Pasting needs
KakaoTalk in front, so it is brought to the front only for the paste; the clipboard is saved
before and restored after, the previous app is brought back, and the new image bubble is
verified.

### `config`

```bash
kktcli config get send
kktcli config set send on|off
```

Settings live in `~/.config/kktcli/config.json` (directory 0700, file 0600;
`KKTCLI_CONFIG_DIR` overrides the directory). `send` (default `off`): while off, `send` and
`send-image` refuse to send (`SEND_DISABLED`, exit 9; `--preview` still works) and the MCP
server does not list `kktcli_send` / `kktcli_send_image`. Only turn it on when you want
kktcli to send.

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
| `kktcli_read` | Read by `chat` or `chat_id`. Options: `limit` (1–500), `skip_unread` (default `false`; `allow_unread` is accepted and ignored), `scrollback` (true/false; omit for automatic), `scrollback_timeout` (seconds), `idle_seconds`, `wait_for_idle`, `allow_activate`, `include_system`, `background_safe`, `keep_window`, `layout`, `deep_recovery`, `trace_ax`. |
| `kktcli_send` | Listed only while sending is on (`kktcli config set send on`); a call while it is off returns `SEND_DISABLED`. One text message to `chat_id` (or a unique `chat`). `mode`: `preview` (default; sends nothing, returns the preview and a human block) or `send` (sends; the call waits up to 40 s plus `wait_for_idle`). Result: `sent`, `cancelled` (always false since there is no dialog), `bubble_verified`. Also `idle_seconds`, `wait_for_idle`, `allow_activate`, `keep_window`, `trace_ax`. `confirm` was removed in 0.2.0. |
| `kktcli_send_image` | The same for `image_path`. |

A read call times out after 8 s (15 s with `deep_recovery`) plus `wait_for_idle` (default
30 s, the most kktcli waits for an idle user); an explicit `scrollback: true` extends that by
`scrollback_timeout` plus 2 s. Failed reads return
the code kktcli reported (see [Error codes](#error-codes)) with its message, hint and
details; `meta.read` of a successful read carries kktcli's own `meta`.

The send tools exist only while sending is on; even then `mode` defaults to `preview`, and an
agent should show that preview and wait for the user's explicit 보내 before `mode=send`.

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
  "count": 1,
  "ok": true
}
```

On failure `chats --json` prints an error document like `read` does (`"ok": false`, `error`,
`details`).

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
    "history": { "complete": false, "earliest_date": "2026-11-24", "stopped": "limit" },
    "interrupted": false,
    "list_recovery": null,
    "main_window": null,
    "marked_read": null,
    "opened_via": "chat_list_menu",
    "row_title": "홍길동",
    "rows_read": 84,
    "rows_total": 84,
    "scrollback": null,
    "store": { "chat_id": null, "saved": 0, "skipped": "no unique chat_id for this name; read with --chat-id to keep it" },
    "truncated_messages": 0,
    "unread_after": null,
    "unread_before": null,
    "waited_for_user_ms": 0,
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

### Several chats (`--chat-id` repeated or `--chat-ids-file`)

The chats are read one after another in one process: the permission and login checks and
the Accessibility setup happen once, and each chat is found from its registry row hint
(the scan stops at the first match). Each chat is opened, read and closed before the next.
One chat failing does not stop the others. The document has one result per chat, in
order, each exactly the document a single read prints (`ok`, `chat`, `chat_id`,
`messages`, `meta` or `error`, `details`):

```json
{
  "count": 2,
  "fetched_at": "2026-11-25T09:00:00.000Z",
  "meta": { "chats": 2, "elapsed_ms": 5210, "failed": 1, "interrupted": false, "succeeded": 1 },
  "ok": false,
  "results": [
    { "chat": "홍길동", "chat_id": "chat_7f42c5e1d9ab", "count": 20, "messages": [], "meta": {}, "ok": true },
    { "chat": "가족", "chat_id": "chat_0b1d2e3f4a5c", "details": {}, "error": { "code": "CHAT_NOT_IN_LIST", "hint": "…", "message": "…" }, "ok": false }
  ]
}
```

(`messages` and `meta` shortened.) Each chat first waits for the activity guard, with its
own `--wait-for-idle` budget. When a chat fails with `KAKAOTALK_IN_USE`, the remaining chats
are not attempted (they get the same code) instead of each waiting again; any other failure
(for example `OPEN_CHAT_LIST`) is that chat's result and the run continues. Exit status: `0`
when every chat was read, `130` when interrupted (the chats not yet read get `INTERRUPTED`),
`75` when KakaoTalk was in use, otherwise `1`. Problems with the arguments, permission,
login or a main window that is not visible (`MAIN_WINDOW_NOT_VISIBLE`) stop the whole run
with a single error document.

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
| `CHAT_ID_STALE` | 5 | The `chat_id` was retired: a scan could not tell its room apart from another one with the same name. Run `kktcli chats` and use the current chat_id. |
| `CHAT_AMBIGUOUS` | 6 | Same-name rooms cannot be told apart for this `chat_id`; `details.candidates` lists title, preview, time and member count. |
| `CHAT_NOT_IN_LIST` | 1 | No chat-list row matches (after list recovery, if any). |
| `AMBIGUOUS_CHAT` | 1 | Several rows match a partial name equally well. |
| `CHAT_LIST_UNAVAILABLE` | 1 | The main window does not show the chat list (another tab, e.g. 친구) and switching with 창 > 채팅 did not help or was not possible; nothing was read or recorded. |
| `WINDOW_NOT_READY` | 1 | The main window could not be found or reopened. |
| `MAIN_WINDOW_MINIMIZED`, `KAKAO_HIDDEN` | 1 | Restore KakaoTalk's window first. |
| `MAIN_WINDOW_NOT_VISIBLE` | 1 | The main window was found neither on this nor on another desktop, and the window server shows a KakaoTalk window kktcli cannot reach (so it is not simply closed); nothing was pressed. Show KakaoTalk, or pass `--allow-activate`. |
| `KAKAOTALK_IN_USE` | 75 | KakaoTalk stayed in front and in use for the whole `--wait-for-idle`; nothing was pressed. Retry later. |
| `OPEN_CHAT_LIST` | 4 | The row opened a list of 1:1 open-chat conversations, not a chat; it was closed and nothing was read. |
| `ROW_NOT_VISIBLE` | 1 | The row could not be scrolled into view. |
| `ROW_CHANGED` | 1 | The list reordered while opening; retry. |
| `MENU_UNAVAILABLE`, `MENU_ITEM_MISSING`, `MENU_ITEM_BLOCKED` | 1 | The context menu could not be used; nothing was pressed. |
| `CHAT_WINDOW_NOT_OPENED` | 1 | No window was recognised as the room after 채팅방 열기. Every window that appeared after the press is closed with its close button; `details` lists them (`unexpected_new_windows`, untitled ones as `(untitled)`; `closed_new_windows`; `left_open_windows`). |
| `TRANSCRIPT_UNAVAILABLE` | 1 | The window has no readable transcript. |
| `BACKGROUND_SAFE_BLOCKED` | 1 | `--background-safe` and no matching open window. |
| `ACCESSIBILITY_PERMISSION_DENIED`, `KAKAO_NOT_RUNNING`, `KAKAO_LAUNCH_FAILED`, `KAKAO_UNAVAILABLE`, `KAKAO_AUTH_FAILED` | 1 | Setup or login problem. |
| `NOT_FRONTMOST`, `SEARCH_MISS`, `FOCUS_FAIL`, `INPUT_NOT_REFLECTED`, `LEGACY_OPEN_FAILED` | 1 | `--legacy-open` failures. |
| `INTERRUPTED` | 130 | Stopped before a room was opened. |
| `SEND_DISABLED` | 9 | Sending is off (`kktcli config set send on`); nothing was touched. |
| `SEND_TARGET_CHANGED`, `SEND_TARGET_UNCERTAIN`, `SEND_INPUT_NOT_EMPTY`, `SEND_INPUT_REJECTED`, `SEND_INPUT_UNAVAILABLE`, `SEND_BUTTON_UNAVAILABLE` | 8 | Nothing was sent (the input was left empty again). |
| `SEND_UNVERIFIED` | 8 | The bubble could not be verified; `details.probably_sent` says whether KakaoTalk took the text. Read the room before doing anything else; never resend blindly. |

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
| `~/.kktcli/main-window-id.json` | The main window's Accessibility element id for the running KakaoTalk (other desktops). |
| `~/.kktcli/*.lock` | Lock files: several kktcli processes (a `watch`, the MCP server, a `read`) can run at once; each change re-reads the file under the lock and replaces it atomically, so none overwrites another's changes. |
| `~/.kktcli/messages/<chat_id>.jsonl` | Messages kept from reads (see [Local message store](#local-message-store)). |

These files contain private data. Do not publish them or attach them to issues. kktcli
never reads or writes `~/.kmsg` or `~/.config/kmsg`.

## Local message store

Successful reads keep what they read, so it can be searched later without KakaoTalk:
`read` (unless run with `--no-save`) and `watch --read` append the messages and system
lines they read to `~/.kktcli/messages/<chat_id>.jsonl`, one JSON object per line.

**The store holds chat content in plain text on this Mac.** The directory is created with
mode `0700` and each file with `0600` (wider modes are narrowed on the next save), so other
user accounts cannot read it, but anything running as you (backups, sync tools, other
programs) can. Do not publish these files or attach them to issues; `kktcli store clear`
deletes them.

- `KKTCLI_STORE_DIR=<dir>` uses `<dir>` instead of `~/.kktcli/messages` (tests use a
  temporary directory). Only `chat_id`s made of letters, digits, `_` and `-` are accepted,
  so nothing is written outside it.
- Each line has `chat_id`, `chat` (the room title at read time), `date`, `time` (`HH:MM` or
  null), `time_raw`, `author`, `side`, `kind`, `body`, `occurrence`, `edited`, `truncated`
  `image_count`, `attachment_count` and `saved_at` (ISO-8601); unknown values are null.
- Duplicates: a line is added only when no stored line of that chat has the same `date`,
  `time`, `author`, `body` and `occurrence`. `occurrence` numbers identical messages (same
  date, time, author and body) within one read: 0, 1, 2, … So legitimate repeats survive:
  if a read shows three identical "ㅋㅋ" in one minute while two are stored, one is added;
  a later read that shows only one of them adds nothing. A message read once without its
  date, time or author and later with them is stored twice.

```bash
kktcli search <text> [--chat-id ID] [--since D] [--until D] [--author A] [--limit N] [--json]
kktcli store clear [--chat-id ID] [--json]
```

`kktcli search` reads only the store, never KakaoTalk. `<text>` matches the body
case-insensitively, also with spaces ignored (`"안녕 하세요"` finds `안녕하세요`); an empty
text matches everything. `--since`/`--until` are inclusive (`YYYY-MM-DD` or
`YYYY-MM-DDTHH:MM`), `--author` matches a name exactly or as a case-insensitive part
(`(me)` is you), and `--limit` (default 50) keeps the newest hits by date, time, then save
order. Text output is one line per hit, `date time author (chat): body`; `--json` prints
`{"ok": true, "count": N, "results": [...], "store": "<dir>"}`.

A read by name is kept only when that name belongs to exactly one known chat_id (otherwise
`meta.store.skipped` says why); reads with `--chat-id` are always kept. `read --json`
reports `meta.store` as `{"chat_id", "saved", "skipped"}` (null with `--no-save`).

```bash
kktcli export [--chat-id ID ...] [--since D] [--until D] [--author A] [--grep T] [--format md|json|csv] [--out FILE]
```

`kktcli export` also reads only the store. Markdown (default) groups by room and day:

```markdown
# 테스트방

## 2026-11-26 (목)

- 15:12 홍길동: 내일 3시 회의실 A
  자료는 https://example.com/a
- 15:20 나: [사진]
```

Long messages appear as kept (cut ones are labelled), attachments as `[사진]`, `[사진 N장]`
or `[파일: name]`, system lines as `(알림) …`, links unchanged. `--chat-id` can be repeated
and sets the order of the rooms; `--grep` also matches with spaces ignored. `--format json`
prints `{"ok": true, "count": N, "messages": [...]}`; `--format csv` writes UTF-8 with a
byte-order mark and CRLF lines (columns chat, chat_id, date, time, author, body, kind) so
Excel on the Mac shows Korean. To turn an export into a one-page summary, see
[`templates/방-요약.md`](templates/방-요약.md).

`kktcli store clear` deletes every `<chat_id>.jsonl` in the store, or one chat's with
`--chat-id` (other files and the directory stay); `--json` prints
`{"ok": true, "removed": N, "chat_ids": [...], "store": "<dir>"}`. With `--json`, errors are
`{"ok": false, "error": {"code", "message", "hint"}}`: `INVALID_ARGUMENT` (exit 64) for a bad
`--chat-id`, date or `--limit`; `STORE_READ_FAILED` or `STORE_CLEAR_FAILED` (exit 1) when the
store cannot be read or removed.

## Troubleshooting

### Accessibility permission is not granted

Run `kktcli status`, then enable the exact `kktcli` binary under **System Settings →
Privacy & Security → Accessibility**. A rebuilt or moved binary may need to be added
again.

### `MAIN_WINDOW_NOT_VISIBLE`

kktcli found KakaoTalk's main window neither on the current desktop nor, by element id, on
another one, and the window server shows a KakaoTalk window it cannot reach, so the window
is probably not simply closed (where 창 > 채팅 would open it). kktcli did not press
카카오톡 열기 because that would bring KakaoTalk to the front and may switch your desktop.
`details.element_id_scan` says what the id lookup did (`unavailable` when this macOS lacks
the function). Show KakaoTalk on the current desktop and retry, or pass `--allow-activate`.

### `KAKAOTALK_IN_USE`

KakaoTalk was in front and you were using it for the whole `--wait-for-idle`, so kktcli did
not open anything that could take your typing. Retry when you are done, switch to another
app (rooms then open in the background), or raise `--wait-for-idle`.

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
upstream release, e.g. `0.2.0 (based on kmsg 1.260921.0)`.
