# kktcli — KakaoTalk CLI for macOS

[한국어](README.md) · [Usage](USAGE.md) · [Architecture](ARCHITECTURE.md)

`kktcli` (KaKaoTalk CLI) is an unofficial command-line tool for KakaoTalk for Mac,
built for terminals and coding agents with a focus on **reading** chat lists and
messages. It reads the KakaoTalk app on screen through the macOS Accessibility API; it
never talks to Kakao's servers or the private LOCO protocol.

kktcli is a fork of [channprj/kmsg](https://github.com/channprj/kmsg) (MIT). Thanks to
Park Hee Chan and the kmsg contributors. See [What changed from kmsg](#what-changed-from-kmsg).

## Safety and policy

Please read this first.

- **Not affiliated with Kakao.** kktcli is not made or endorsed by Kakao Corp., and
  there is no official permission to automate KakaoTalk.
- **The risk depends on how a tool connects and how you use it.**
  - kktcli only operates the official KakaoTalk app through macOS Accessibility; it never
    connects to Kakao's servers or to the private LOCO protocol.
  - Reports of permanent bans concern unofficial clients that speak LOCO directly; the kmsg
    developer notes ([ARCHITECTURE.md](https://github.com/channprj/kmsg/blob/main/ARCHITECTURE.md))
    mention them too. These are unsourced reports, not figures published by Kakao.
  - As of November 2026 we found no report of an account suspended for using an
    Accessibility-based tool such as kmsg (GitHub issues and web search). Such tools are new
    and have few users, so the absence of reports is not a guarantee.
  - Whatever the method, sending many messages or creating many chat rooms in a short time
    can trigger Kakao's automatic restrictions
    ([KakaoTalk operating policy – automatic detection](https://talksafety.kakao.com/measure/detection)).
  - Kakao has not officially permitted this kind of automation, and its operating policy
    allows restricting use "by methods KakaoTalk does not permit"
    ([operating policy](https://talksafety.kakao.com/policy/stability/abnormalusage)).
    You use kktcli at your own risk.
- **Read-first design.** `chats` and `read` post no synthetic keystrokes or clicks; they
  read the screen through Accessibility and press only specific buttons and menu
  items. They work while KakaoTalk stays in the background.
- **Never mass-send.** `send` and `send-image` remain for single messages the user
  explicitly asked for. Repeated sending to many rooms or people looks like spam and
  can get the account restricted.
- **Unread rooms are opened, and opening marks them read.** `read` opens a room with
  unread messages just as a person opening it by hand would, so the other participants
  get read receipts. To avoid that, pass `--skip-unread`: a room whose chat-list row
  shows an unread badge is then not opened and `read` stops with `UNREAD_REFUSED` (exit
  status 3). kktcli currently has no way to see unread messages without marking them
  read, apart from the last-message preview that `chats` shows.
- **Nothing is opened while you use KakaoTalk.** When KakaoTalk is in front, a room
  window kktcli opens becomes the key window: what you are typing goes into that room, and
  Enter could send it to the wrong room. So while KakaoTalk is in front and the keyboard or
  mouse was used less than 10 s ago (`--idle-seconds`), kktcli presses nothing that opens or
  brings up a window and waits; after 30 s (`--wait-for-idle`) it stops with
  `KAKAOTALK_IN_USE` (exit status 75). With KakaoTalk in the background, rooms open in the
  background.
- **KakaoTalk is not brought to another desktop or full-screen Space.** While you work in
  another full-screen Space, Accessibility shows no KakaoTalk windows at all. Reopening the
  main window with 카카오톡 열기 would bring KakaoTalk to the front and switch your desktop,
  so unless KakaoTalk is already in front kktcli presses nothing and stops with
  `MAIN_WINDOW_NOT_VISIBLE`. Show KakaoTalk on the current desktop, or pass
  `--allow-activate`.
- **Chat contents stay on this Mac.** kktcli contains no network code. If you pipe its
  output into an AI service (a coding agent, a chatbot), that content is transferred to
  that company, together with your chat partners' personal data. Read only what the
  task needs.
- **Local files:** `~/.kktcli` (chat registry, AX path cache) and `~/.config/kktcli`
  (encrypted login; the key is on the same Mac). kktcli never reads or writes an
  installed kmsg's `~/.kmsg` or `~/.config/kmsg`.

## What changed from kmsg

| Area | kmsg 1.260921.0 | kktcli 0.1.0 |
|---|---|---|
| Opening a room | Row select + Enter, typing into search, double-click (key and mouse events) | Presses only the row's context-menu item **채팅방 열기** through Accessibility; no keystrokes, works with KakaoTalk in the background |
| Unread rooms | Opened, which sends read receipts | Opened like by hand, which sends read receipts; `--skip-unread` leaves them unopened (`UNREAD_REFUSED`); JSON reports the badge before and after (`unread_before`, `unread_after`, `marked_read`) |
| `read --chat-id` | Rescans about 200 chat-list rows on every call | Starts at the registry's last known row and stops at the first match |
| `chats` titles | Unread badge text could appear as the room title | Title read only from the title label (`_NS:40`); adds `has_unread` / `unread_count` |
| Message parsing | `date` empty; unlabeled burst messages took the previous message's time | `date` from date separators, burst times inferred (`time_source`: `label` / `inferred`), sender carried forward, channel banners never attributed to `(me)` |
| Older messages | Only the initially loaded rows | Scrollback (`--scrollback`, time-bounded) |
| Long messages | Only what the bubble shows, not flagged | Cut messages flagged (`truncated`); `--full-text` fetches the full text (experimental) |
| Closing windows | First button found, or Cmd+W | Only the window's close button; otherwise left open and reported |
| Keyboard paths | No check of the frontmost app | Paths that still type (send, login, legacy open) post input only while KakaoTalk is frontmost |
| `--json` | Plain text when empty or failing | Always exactly one JSON document (error code and exit status) |
| List state recovery | None | Restores a search-filtered chat list and a closed main window by pressing only specific buttons / menu items |
| Team and open chats | Could fail in the search fallback | Matches row titles `팀채팅, <name>` / `오픈채팅, <name>` with window title `<name>`; recognises an untitled open-chat window when it shows a chat; a row that opens the list of 1:1 open-chat conversations is closed and reported as `OPEN_CHAT_LIST` (those conversations cannot be read) |
| Distribution | `update` command, Homebrew, release automation | Build from source; no network code; separate data directories |
| MCP | `kmsg_*` tools | `kktcli_*` tools, `skip_unread` and scrollback options, read error codes passed through |

## Measured results

Setup: one Mac, KakaoTalk for Mac 26.10.0, one account, 20 rooms, the latest 20
messages of each. The same Codex model drove all three tools.

| | kktcli 0.1.0 | kmsg 1.260921.0 | Codex Computer Use |
|---|---|---|---|
| Rooms read successfully | 20/20 | 17/20 | 20/20 |
| Time per room (median) | 3.2 s (2.4–9.9 s) | 33 s (32 s of it in kmsg) | 59 s |
| Messages recalled | 99.7% | 87.9% (failures included) | 98.1% |
| Sender correct | 100% | 97% | 99.7% |
| Time correct (messages with a time label) | 100% | 98% | 100% |

kktcli details:

- Zero synthetic key or click events; KakaoTalk stayed in the background; every
  opened window was closed with its close button. Team chats, a self chat and four
  channel rooms all worked.
- `chats`: 6.8 s for 182 rows, titles and unread flags 182/182 correct.
- Scrollback: 200 messages with dates in 17 s.
- Recovery: a visible search was restored (취소, then 검색); a closed main window was
  reopened through **카카오톡 열기** (this brings KakaoTalk to the front, so it is now pressed
  only when KakaoTalk is already in front or with `--allow-activate`); a missing
  room returns `CHAT_NOT_IN_LIST`; bad arguments return JSON with exit status 64. The
  hidden-filter state (no search field, filtered list) could not be reproduced live and
  is **unverified**.

kmsg failures: two channel rooms and one team chat failed; another team chat failed
once and left the search box filled. Root cause for the team chats: kmsg's search
fallback searches for `팀채팅, <name>`, which KakaoTalk search never matches (0 results;
1 result without the prefix), so when its row select + Enter step misses, team chats
cannot recover. Row select + Enter itself worked 10/10 when the chat list had focus.

Additional measurements (2026-11-25, same Mac and account):

- Reading more: the latest 100 messages of 4 rooms (400 messages) took kktcli 43.6 s and
  Codex Computer Use without a CLI 1,606.5 s (about 37x; one of the Codex rooms had human
  input during the run). 374/400 messages (93.5%) paired up between the two results, and
  every paired message had the same text, sender and time; the rest were messages that
  arrived in between, messages cut at 500 characters, and system messages.
- Long messages: all 9 messages cut at 500 characters (6 rooms) were fetched in full with
  `--full-text`, and every window that opened was closed again.
- 19 rows that open a list of 1:1 open-chat conversations: all reported `OPEN_CHAT_LIST`
  (12 opened, checked and closed; the 7 with zero conversations were not opened). These 19
  plus 2 ordinary rooms took 36 s in one batch run.
- Working in another full-screen Space: `chats` and `read` stopped with
  `MAIN_WINDOW_NOT_VISIBLE` in 0.7 s, pressed nothing and left the frontmost app alone. With
  another app in front on the same desktop, `read` succeeded in 2.3 s and the frontmost app
  stayed in front.
- The in-use guard (`KAKAOTALK_IN_USE`) is covered by unit tests only; it has not been
  checked live yet.

Caveats: one Mac, one account, n=20 rooms. The reference read used for accuracy was
produced by an Accessibility reader, the same data source as kktcli, which may favor
kktcli.

## Requirements

- macOS 13 or later
- KakaoTalk for Mac. **Tested only on 26.10.0 (build 2010)**; other versions may lay
  out their windows differently.
- Accessibility permission for the `kktcli` binary you run
- Swift 6 or later to build (Xcode or the Command Line Tools)

## Install

On an Apple silicon (arm64) Mac, one line downloads the release binary from GitHub, checks
its SHA-256 and installs it as `~/.local/bin/kktcli`:

```bash
curl -fsSL https://raw.githubusercontent.com/gamjakyle/kktcli/main/install.sh | bash -s -- --version 0.2.0
```

To build from source instead, run `./install.sh --from-source` in a clone of this
repository; from a clone the script also builds from source on Intel Macs or when the
download fails. Then add the installed binary under **System Settings → Privacy & Security
→ Accessibility**, turn it on and check with `kktcli status`. An updated or rebuilt binary
may need to be added again.

## Build and install from source

```bash
swift build -c release
mkdir -p ~/.local/bin
install -m 0755 .build/release/kktcli ~/.local/bin/kktcli
kktcli --version   # 0.1.0 (based on kmsg 1.260921.0)
kktcli status      # Accessibility permission, KakaoTalk running and logged in
```

Make sure `~/.local/bin` is on `PATH`, and enable that exact binary under **System
Settings → Privacy & Security → Accessibility**. A rebuilt or moved binary may need to
be added again.

## Quick start

```bash
kktcli chats --json --limit 30                    # rooms, chat_id, unread state
kktcli read --chat-id "<chat_id>" --limit 20 --json
kktcli read --chat-ids-file ids.txt --json          # several rooms in one run, one result each
kktcli read "Room name" --limit 200 --scrollback   # include older messages
kktcli read "Room name" --json --background-safe   # only read an already open window
```

`read` reads an open window in place; otherwise it finds the room in the chat list,
opens it, reads it and closes it again. All commands and options are in
[USAGE.md](USAGE.md).

## Coding agent skill

[`skills/kktcli`](skills/kktcli/SKILL.md) tells coding agents how to use kktcli safely
(read first, say that opening an unread room marks it read, send only on explicit request
and after a dry run, once). For Claude Code, copy the folder to `~/.claude/skills/kktcli`
and invoke it with `/kktcli`. For other agents, follow their skill installation
instructions.

## MCP server

```bash
kktcli mcp-server
```

A stdio MCP server with the tools `kktcli_read`, `kktcli_send` and `kktcli_send_image`.
`kktcli_read` accepts `skip_unread`, `scrollback` and `scrollback_timeout`, and on
failure returns kktcli's own error code such as `UNREAD_REFUSED`. The old `allow_unread`
option is still accepted and ignored. See
[USAGE.md](USAGE.md#mcp-server) for a configuration example.

## Documentation

- [USAGE.md](USAGE.md) — commands, options, JSON output, error codes, configuration,
  troubleshooting
- [ARCHITECTURE.md](ARCHITECTURE.md) — structure and design decisions

## Acknowledgements

kktcli started from [channprj/kmsg](https://github.com/channprj/kmsg), which was
inspired by [steipete/imsg](https://github.com/steipete/imsg) and
[OpenClaw](https://github.com/openclaw/openclaw).

## License

[MIT License](LICENSE). The original kmsg copyright notice is kept, with a notice added
for this fork's modifications.
