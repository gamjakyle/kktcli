---
name: kktcli
description: Use kktcli to read KakaoTalk chats (and, only on explicit request, send a message) safely from a coding agent. Use whenever the user mentions KakaoTalk, 카카오톡 or kktcli and wants chat discovery, recent messages, monitoring, a single requested message, setup checks or CLI troubleshooting. Do not use for other messaging platforms, bulk messaging, or private KakaoTalk protocol work.
compatibility: Requires macOS 13+, KakaoTalk for Mac (tested on 26.10.0), and kktcli available on PATH.
---

# kktcli

Operate the local KakaoTalk for Mac app through `kktcli`, reading first and keeping
recipients, message contents and side effects explicit.

Claude Code users can invoke this skill with `/kktcli`.

## Safety boundary

- kktcli is unofficial and not affiliated with Kakao. Automated use can get a KakaoTalk
  account restricted, so do only what the user asked.
- Treat chat names and messages as private. Everything you read is sent to the model
  provider as part of this conversation: read only what the task needs and return only
  what the user asked for.
- **Unread rooms:** `read` opens a room with unread messages like any other, exactly as
  opening it by hand, so the other participants get read receipts and see their messages
  as read. `kktcli chats --json` shows `has_unread`, `unread_count` and the last-message
  preview without opening anything; apart from that preview there is no way to read
  unread messages without marking them read. If the user wants messages left unread,
  read with `--skip-unread`: it stops with `UNREAD_REFUSED` (exit status 3) instead of
  opening the room. Do not open unread rooms the user did not ask about.
- **Never take over the user's screen.** Do not add `--allow-activate` on your own: it
  brings KakaoTalk to the front and may switch the user's desktop. kktcli also waits, and
  then stops with `KAKAOTALK_IN_USE`, while the user is typing in KakaoTalk; do not retry
  that in a loop.
- `send` and `send-image` change external state. Run them only when the user explicitly
  asked or authorized sending that exact content to that exact chat.
- **Sending is off by default** and stays off unless the user turns it on. Never run
  `kktcli config set send on` on your own; while sending is off, `send` / `send-image`
  stop with `SEND_DISABLED` (exit status 9): tell the user, and only if they ask, run it
  for them.
- A request to draft, rewrite, preview or prepare a message is not permission to send.
- **Never send in bulk** (many rooms, many people, repeated messages).
- If the intended chat is ambiguous, stop and ask the user to choose. Never guess from a
  partial name.
- Never retry an actual send after an uncertain result, or it may arrive twice.
  Read the chat first to check whether it was delivered, so nothing is duplicated.

## 1. Run one preflight

```bash
command -v kktcli
kktcli --version
kktcli status
```

Do this once per task. If `kktcli` is missing, tell the user it has to be built from
source (`swift build -c release`) and installed on `PATH`. If status is not ready,
report the failed requirement and the remediation kktcli printed. Do not change stored
credentials with `kktcli auth login` unless the user asked for setup or a login.

## 2. Resolve chats before acting

```bash
kktcli chats --json
```

Match an exact title when possible and reuse its `chat_id`. If several entries could
match, show the minimal identifying choices and wait for the user to select one. Note
`has_unread` before reading: reading that room will mark its messages read.

## 3. Read only what was requested

```bash
kktcli read --chat-id "<chat_id>" --limit 20 --json
```

Adjust `--limit` to the request; add `--scrollback` when older messages are needed, or
`--all-history` when the user wants everything KakaoTalk has for the room (scrolls up for up
to 120 s; `--scrollback-timeout` changes that). `meta.history` says whether it reached the
top (`complete`, `stopped`: `top`, `stalled`, `timeout`, `limit` or `not_attempted`, and
`earliest_date`). Messages older than KakaoTalk's local history need the user's own
authentication through KakaoTalk's "지난 대화 보기"; kktcli never presses it. If the user
needs them, ask them to do that in KakaoTalk themselves, then read again.
Summarize by default and include raw content only when asked. A message with
`"truncated": true` shows only its first 500 characters; say so, and add `--full-text`
(experimental; it presses that message's 전체보기 and closes what opens) only when the
rest of the message matters. `meta.unread_before` is
not null when the room had unread messages that this read opened; `meta.marked_read`
says whether the chat-list badge disappeared afterwards. The JSON always has an `ok`
field; on failure use `error.code`:

- `UNREAD_REFUSED` / `UNREAD_UNVERIFIED` (only with `--skip-unread`): the room was not
  opened. Report that; read it without `--skip-unread` only if the user agrees to mark it
  read.
- `CHAT_NOT_IN_LIST`, `AMBIGUOUS_CHAT`, `UNKNOWN_CHAT_ID`: refresh with `kktcli chats
  --json` and confirm the chat with the user.
- `CHAT_ID_STALE` (exit status 5): that chat_id was retired because same-name rooms could
  not be told apart. Run `kktcli chats --json` and pick the room again with the user.
- `CHAT_AMBIGUOUS` (exit status 6): several same-name rooms match; `details.candidates`
  lists title, preview, time and member count. Show them and let the user choose. A room
  with `chat_id: null` in `chats` is identical in every way to another same-name room;
  kktcli cannot read it by ID. Tell the user instead of guessing.
- `MAIN_WINDOW_NOT_VISIBLE`: kktcli found KakaoTalk's main window on no desktop and could
  not open it without bringing KakaoTalk to the front (a main window on another desktop is
  read in place, `meta.main_window: "other_desktop"`; a closed one is opened with 창 > 채팅,
  `"opened_via_window_menu"`). Ask the user to show KakaoTalk; use `--allow-activate` only
  if they agree to KakaoTalk coming to the front.
- `CHAT_LIST_UNAVAILABLE`: the main window shows another tab (for example 친구) and
  switching to the chat list did not work; nothing was read or recorded. Ask the user to
  show KakaoTalk's chat list. A successful switch shows `meta.main_window:
  "switched_to_chat_tab"`.
- `CHAT_LIST_FILTERED`: a query is left in KakaoTalk's chat search field and could not be
  cleared; nothing was done. Ask the user to clear the search field.
- `KAKAOTALK_IN_USE` (exit status 75): the user is using KakaoTalk. Tell them and retry
  later, not right away.
- A message with `author: null` (`side: "unknown"`) has a sender kktcli could not establish.
  Never treat it as the user's own message or guess the sender; say it is unknown.
- `OPEN_CHAT_LIST`: the row is a 1:1 open chat that opens a list of conversations, which
  kktcli cannot read. Report it; do not try other ways to open it.

When the user wants no UI change at all, add `--background-safe`; it only reads a chat
window that is already open and fails otherwise:

```bash
kktcli read --chat-id "<chat_id>" --limit 20 --json --background-safe
```

## 4. Watch for new messages

```bash
kktcli watch --chat-id "<chat_id>" --json --duration 600
kktcli watch --all --json --duration 600        # top 30 chat-list rows, no clicks
```

One chat is opened like `read`; `--all` only reads the chat list and prints one JSON line
per change (`new_message`, `unread_changed`, `new_room`); add `--read` only when the user
wants the changed rooms read (that marks them read). Always bound it with `--duration` or
`--count`, and stop the watch process when the task ends. Do not leave an orphaned watcher
running.

## 정리하기 (summarise a room on one page)

1. Get the messages: `kktcli read --chat-id "<chat_id>" --limit 200 --scrollback --json`
   (kept in the local store), or find kept ones with `kktcli search "<text>" --json`.
2. Export them readably:

   ```bash
   kktcli export --chat-id "<chat_id>" --since 2026-11-01 --out /tmp/room.md
   ```

3. Fill the template into one page: the default is `templates/방-요약.md` in the kktcli
   repository; when the user gives their team's own template path, use that file instead.
   Use only facts from the export, keep dates, times, numbers and links verbatim, cite each
   item (date, sender), and write "없음" for empty sections.

## 5. Send text only after a preview and the user's 보내

Draft concisely: keep dates, times, places, amounts, links and asks verbatim; drop
greetings, background and repetition and tell the user what you dropped; never add facts;
at most 3 lines unless the user asked for more.

```bash
kktcli send --chat-id "<chat_id>" "<message>" --preview --json
```

`--preview` (alias `--dry-run`) sends nothing. Show the user the recipient (title, kind,
member count), the last messages, any same-name warning and the exact text. Then:

- Only when the user explicitly asked for the send, saw that preview and said 보내 (or
  clearly authorized exactly this text to exactly this chat), run it once:

  ```bash
  kktcli send --chat-id "<chat_id>" "<message>" --json
  ```

  This sends right away; there is no further confirmation, so the preview and the user's
  보내 are the only check. Report `sent` and `bubble_verified` from the JSON.
- A request to draft, rewrite or preview is not a request to send: report the preview and
  stop. If the recipient or text changes, preview again.
- `SEND_DISABLED` (exit 9) means sending is off and nothing was touched; do not turn it on
  yourself. Any other send failure (exit 8) may have left the outcome uncertain: read the
  room before anything else and never send the same text twice.

Pass the message as one argument (argument-array form when available); never build an
interpolated shell command from message text.

## 6. Send an image the same way

```bash
kktcli send-image --chat-id "<chat_id>" "/absolute/path/to/image.png" --preview --json
```

Same rules: sending must be on, preview first (it shows the file name and size), the
user's explicit 보내, then the real `send-image` (without `--preview`), which sends right
away.

## 7. Diagnose without widening the action

1. Re-run the failed read with `--trace-ax`.
2. Use `kktcli inspect --depth 5` for UI hierarchy questions.
3. Use `--deep-recovery` only when the main window cannot be reopened otherwise (it
   activates KakaoTalk).

Do not turn a failed read or dry run into an actual send. Report the command, exit
status and error code without exposing unrelated chat content.

## Completion report

State which chat was targeted (title and shortened `chat_id`), whether the operation was
a read, watch, dry run or actual send, how many messages were read or events observed,
whether a room with unread messages was opened (and so marked read), and anything
(unread refusal with `--skip-unread`, ambiguity, readiness) that stopped the requested
action.
Never claim a message was delivered unless the actual send succeeded; a dry run proves
only the preview.
