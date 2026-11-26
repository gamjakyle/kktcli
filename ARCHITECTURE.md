# Architecture

kktcli is a Swift 6 executable for macOS 13 and later. It drives KakaoTalk for Mac only
through the macOS Accessibility (AX) API: it reads the app's UI tree and performs a few
named AX actions. It has no network code and never speaks KakaoTalk's private protocol.

```text
CLI commands (Sources/kktcli/Commands)
    |
    +-- KakaoTalk services (Sources/kktcli/KakaoTalk)
    |     chat list locator, context-menu opener, transcript reader,
    |     list / main-window recovery, legacy search resolver, registry
    |
    +-- Accessibility helpers (Sources/kktcli/Accessibility)
    |     batched AX reads, AX path cache, input guard, permission
    |
    +-- KktcliCore (Sources/KktcliCore): pure logic, unit tested
          row and transcript parsing, matching, safety policies, MCP mapping
```

## Modules

| Path | Responsibility |
|---|---|
| `Sources/kktcli/kktcli.swift` | Registers commands, prints the `VERSION` (e.g. `0.2.0 (based on kmsg 1.260921.0)`), turns argument errors of `read --json` into JSON. |
| `Sources/kktcli/Commands/` | Argument parsing, permission and login checks, human or JSON output. |
| `AXNodeReader` | One `AXUIElementCopyMultipleAttributeValues` call per element; depth-first flatten with node budgets; marks failed reads. |
| `ChatListLocator` | Finds open chat windows, the main window ("Main Window") and its chat-list table; reads row titles from `_NS:40`; verifies the table is the chat list (`ChatListCheck`) and otherwise switches tabs with the **창 > 채팅** (⌘2) menu item; resolves `--chat-id` from the registry hint with early termination; reopens a closed main window via the **카카오톡 열기** menu item. |
| `ChatRoomMenuOpener` | Scrolls the list with the scroll-bar value, shows the row's context menu (AXShowMenu) and presses only **채팅방 열기** (`openChatRoom:`) after re-checking the title (and, with `--skip-unread`, the unread badge); cancels anything else. Returns the badge seen right before the press. Accepts a window titled for the row, or the single new window even when untitled (open chats) if it shows a transcript or message input; if none is accepted, closes every window that appeared after the press. |
| `ChatListRecoverer` | Restores a search-filtered chat list by pressing only **취소** inside the search field and the top-bar **검색** toggle. |
| `StructuredTranscriptReader` | Locates the transcript (`_NS:32` scroll area), reads rows newest-first until the limit and its context are covered, loads older rows by setting the scroll bar to 0 and polling the row count, probes for an earlier date separator. |
| `UserActivityGuard` | Before each press that opens or brings up a KakaoTalk window: waits while KakaoTalk may be frontmost and the HID idle time is below `--idle-seconds` (always for 카카오톡 열기), re-checks right before the press, gives up with `KAKAOTALK_IN_USE`. Decision in `KktcliCore/UserActivityPolicy`. |
| `MainWindowAccess` | Reopens a main window that Accessibility does not show only when KakaoTalk is frontmost or `--allow-activate` (`MainWindowPolicy`); otherwise `MAIN_WINDOW_NOT_VISIBLE` with Accessibility and window-server counts. |
| `KakaoTalkInputGuard` | Checks, immediately before every posted key press or click, that KakaoTalk is frontmost (and owns the click point). |
| `ChatWindowResolver`, `MessageContextResolver`, `KakaoTalkTranscriptReader` | Older search/keyboard based paths kept for `read --legacy-open`, `chats` refreshes and the cache command; `send`, `send-image` and `watch` open rooms like `read`. |
| `ChatIdentityRegistryStore` | Local synthetic `chat_id` values derived from normalized names, with last seen row and preview. |
| `CredentialStore`, `KakaoTalkAuthenticator` | Encrypted local credentials, login and lock-screen handling. |
| `KktcliCore` | `ChatRowAnalyzer` (titles, unread badges), `TranscriptParser` (dates, sides, authors, burst times), `ChatQueryMatcher`, `RoomTitle`, `ListRecovery`, `SafetyPolicies` (frontmost policy, menu-item allowlist, the send button), `ChatIdentityAssignment` (chat_ids), `MessageStore` and `ExportFormatter` (local store, search, export), `WatchDiff`, `SendModel` (send preview and checks), `ChatListCheck` (is this table the chat list), `HistoryStatus` (`meta.history`), `KktcliConfig` (the `send` setting), `MCPMapping`, JSON output types. |
| `MCPServerCommand` | stdio MCP server; runs the same binary as a subprocess per tool call. |
| `VersionGenPlugin` / `VersionGenTool` | Validate `VERSION` (`MAJOR.MINOR.PATCH`) and generate `BuildVersion` at build time. |

## Reading a chat

1. Resolve the target: a `chat_id` from the registry, or a name.
2. If an open chat window has that title, read it in place.
3. Otherwise make sure the main window exists (menu item **카카오톡 열기** if it is
   closed) and find the row in its chat list. With `--skip-unread`, refuse it when it
   shows an unread badge.
4. If the row is missing, restore a filtered list once and scan again.
5. Open the row through its context menu, wait for the window, wait until the
   transcript row count settles.
6. Read and parse rows; optionally load older rows (scrollback) within a time budget.
7. Close a window the command opened with its own close button.
8. If the row showed an unread badge, read the row again (for up to 1.5 s while the
   badge is still shown).
9. Print one JSON document (or text); its `meta` reports `unread_before`,
   `unread_after` and `marked_read`.

No step of this path posts keyboard or mouse events.

## Design decisions

### Accessibility, not a private protocol

KakaoTalk has no official CLI. kktcli reads the same UI a user sees, through Apple's
Accessibility API, instead of reverse engineering the LOCO protocol. That does not make
it an official or risk-free integration: KakaoTalk's terms and their enforcement remain
Kakao's decision.

### Read first, and no input events where avoidable

Keyboard and mouse events go to whichever app is in front, so the read path uses only
AX reads, attribute sets (scroll position) and named actions on verified elements. The
remaining keyboard paths (sending, login, legacy opening) post input only after a live
frontmost check, one press at a time.

### Explicit allowlists for every press

Every element kktcli presses is identified by role, identifier and title or description
(`openChatRoom:` / 채팅방 열기, 취소 inside the search field, the top-bar 검색 toggle,
`showFirstWindow:` / 카카오톡 열기, the 창 menu item 채팅 with command key 2, a room's own 전송
button, a window's close button) and re-verified right before the press. Context menus are
cancelled rather than guessed at.

### The chat list is verified before it is used

The main window shows one table for whichever tab is selected, and the 친구 tab's rows also
carry an `_NS:40` title. Reading it as the chat list once filled the chat_id registry with
friends. So the first rows are checked to look like chat-list rows (title plus a time or a
preview, `ChatListCheck`) before `chats`, `read`, `send`, `watch --all` or any registry write
uses the table. On another tab kktcli presses the 창 menu item 채팅 (⌘2) once, through the
activity guard, and waits up to 2 s for a verified list; it never presses 친구 or 더보기, and
list recovery never presses anything on an unverified table. `watch --all` never presses at
all and reports `not_chat_tab`.

### Sending is off until the user turns it on

`send` and `send-image` refuse (`SEND_DISABLED`) unless `kktcli config set send on`, and the
MCP server lists its send tools only then. There is no confirmation dialog: the preview and
the user's explicit 보내 are the check. A real send keeps the narrow path: a chat_id or a
unique name, a re-check right before the press that the same window still shows the same
room and the input holds exactly the text, the room's own 전송 button, and a verified new
bubble.

### Never take the user's keyboard or desktop

Two live findings shape every press. A window opened while KakaoTalk is in front becomes
key and takes whatever the user is typing (Enter would send it to that room), so
window-opening presses wait for an idle user or a KakaoTalk in the background, and are
re-checked right before they happen. And while the user works in another full-screen Space,
Accessibility reports no KakaoTalk windows, which looks exactly like a closed main window;
reopening it there would switch the user's desktop, so it is done only when KakaoTalk is
already in front or the caller explicitly allows activation. The idle time comes from the
HID system state (no permission needed); the window-server counts in the error are reported,
not interpreted, because they cannot tell a closed window from one on another Space.

### Long messages are flagged, and fetched only on request

KakaoTalk cuts long messages at 500 characters plus "…" with a 전체보기 control below.
The parser flags them (`truncated`) from the AX snapshot alone. `--full-text` is opt-in
because it presses: only that message's control, which has no Accessibility label on
26.10.0 and is therefore recognised by shape (an unlabeled button right below a text that
ends in "…" at about 500 characters, re-checked right before the press), then the close
button or AXCancel of exactly what the press opened.

### Unread rooms are opened, like by hand

Active rooms almost always have unread messages, so refusing them made the most
important rooms unreadable. `read` therefore opens a room with an unread badge just as a
person would, which sends read receipts. `--skip-unread` keeps the old refusal (rows
with an unread badge, a badge-like number, or an incomplete read are not opened;
`UNREAD_REFUSED` / `UNREAD_UNVERIFIED`, exit status 3), and `--allow-unread` is a
deprecated no-op. Whether KakaoTalk really marks a room read when it is opened in the
background is reported, not assumed: the row's badge is read before opening and again
after the window is closed (`unread_before`, `unread_after`, `marked_read`). Apart from
the chat-list preview (`chats`), kktcli cannot show unread messages without marking them
read.

### chat_ids are never guessed by position

KakaoTalk exposes no room id, so chat_ids are synthetic. Several rooms can share a name; a
record keeps its ID only when its last preview matches exactly one row, or when exactly one
record and one row are left in that name group. Anything else retires the leftover IDs
(they are never reused) and gives the rows new ones: a stale ID fails (`CHAT_ID_STALE`)
rather than reaching another room. A lookup of one ID never re-runs the assignment; it only
refreshes that record.

### What was read is kept locally, and exports are read-only

Successful reads append to one JSON-lines file per chat under `~/.kktcli/messages`
(0700/0600), deduplicated on date, time, author, body and the occurrence within that group,
so legitimate repeats survive. `search` and `export` only read those files; they never touch
KakaoTalk.

### `watch --all` only reads the list

It reads the top chat-list rows every few seconds and diffs them (`WatchDiff`); it never
scrolls, clicks or reopens the main window. Opening the changed rooms is opt-in (`--read`)
and goes through the same guard as `read`.

### Pure logic is separated and tested

Everything that can be decided from captured AX snapshots lives in `KktcliCore` and is
covered by Swift Testing unit tests that never touch KakaoTalk. Python contract tests
check source-level guarantees (separate data paths, no network code, MCP options).

### Local state only

| Path | Purpose |
|---|---|
| `~/.config/kktcli/credentials.json`, `credentials/primary.key` | Encrypted credentials and their key (owner-only permissions). |
| `~/.kktcli/chat-registry.json` | Synthetic chat identities. |
| `~/.kktcli/ax-cache.json` | Cached AX paths for the legacy paths. |
| `~/.kktcli/messages/<chat_id>.jsonl` | Messages kept from reads (plain text; `read --no-save`, `kktcli store clear`). |

kktcli is a fork of [kmsg](https://github.com/channprj/kmsg) and deliberately uses
different paths, so an installed kmsg keeps its own data.
