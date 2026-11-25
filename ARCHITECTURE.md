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
| `Sources/kktcli/kktcli.swift` | Registers commands, prints `0.1.0 (based on kmsg 1.260921.0)`, turns argument errors of `read --json` into JSON. |
| `Sources/kktcli/Commands/` | Argument parsing, permission and login checks, human or JSON output. |
| `AXNodeReader` | One `AXUIElementCopyMultipleAttributeValues` call per element; depth-first flatten with node budgets; marks failed reads. |
| `ChatListLocator` | Finds open chat windows, the main window ("Main Window") and its chat-list table; reads row titles from `_NS:40`; resolves `--chat-id` from the registry hint with early termination; reopens a closed main window via the **카카오톡 열기** menu item. |
| `ChatRoomMenuOpener` | Scrolls the list with the scroll-bar value, shows the row's context menu (AXShowMenu) and presses only **채팅방 열기** (`openChatRoom:`) after re-checking the title (and, with `--skip-unread`, the unread badge); cancels anything else. Returns the badge seen right before the press. |
| `ChatListRecoverer` | Restores a search-filtered chat list by pressing only **취소** inside the search field and the top-bar **검색** toggle. |
| `StructuredTranscriptReader` | Locates the transcript (`_NS:32` scroll area), reads rows newest-first until the limit and its context are covered, loads older rows by setting the scroll bar to 0 and polling the row count, probes for an earlier date separator. |
| `KakaoTalkInputGuard` | Checks, immediately before every posted key press or click, that KakaoTalk is frontmost (and owns the click point). |
| `ChatWindowResolver`, `MessageContextResolver`, `KakaoTalkTranscriptReader` | Older search/keyboard based paths used by `send`, `send-image`, `watch` and `read --legacy-open`. |
| `ChatIdentityRegistryStore` | Local synthetic `chat_id` values derived from normalized names, with last seen row and preview. |
| `CredentialStore`, `KakaoTalkAuthenticator` | Encrypted local credentials, login and lock-screen handling. |
| `KktcliCore` | `ChatRowAnalyzer` (titles, unread badges), `TranscriptParser` (dates, sides, authors, burst times), `ChatQueryMatcher`, `RoomTitle`, `ListRecovery`, `SafetyPolicies` (frontmost policy, menu-item allowlist), `MCPMapping`, JSON output types. |
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
`showFirstWindow:` / 카카오톡 열기, a window's close button) and re-verified right before
the press. Context menus are cancelled rather than guessed at.

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

kktcli is a fork of [kmsg](https://github.com/channprj/kmsg) and deliberately uses
different paths, so an installed kmsg keeps its own data.
