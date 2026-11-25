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
- **Unread rooms:** opening a room with unread messages sends read receipts. `read`
  refuses such rooms (`UNREAD_REFUSED` or `UNREAD_UNVERIFIED`, exit status 3). Do not add
  `--allow-unread` on your own; ask the user first and explain that the other participants
  will see the messages as read.
- `send` and `send-image` change external state. Run them only when the user explicitly
  asked or authorized sending that exact content to that exact chat.
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
`has_unread` before reading.

## 3. Read only what was requested

```bash
kktcli read --chat-id "<chat_id>" --limit 20 --json
```

Adjust `--limit` to the request; add `--scrollback` when older messages are needed.
Summarize by default and include raw content only when asked. The JSON always has an
`ok` field; on failure use `error.code`:

- `UNREAD_REFUSED` / `UNREAD_UNVERIFIED`: ask the user (see Safety boundary).
- `CHAT_NOT_IN_LIST`, `AMBIGUOUS_CHAT`, `UNKNOWN_CHAT_ID`: refresh with `kktcli chats
  --json` and confirm the chat with the user.

When the user wants no UI change at all, add `--background-safe`; it only reads a chat
window that is already open and fails otherwise:

```bash
kktcli read --chat-id "<chat_id>" --limit 20 --json --background-safe
```

## 4. Watch for new messages

```bash
kktcli watch "<chat>" --json
```

Use an exact title. `watch` needs KakaoTalk in front to open a closed room. Keep it
bounded by the requested condition or duration, and stop or terminate the watch process
when the task ends. Do not leave an orphaned watcher running.

## 5. Send text only with a dry run first

```bash
kktcli send --chat-id "<chat_id>" "<message>" --dry-run
```

Check the dry-run output for the intended ID and exact text. Then:

- If the user explicitly asked, requested or authorized the actual send, run it once:

  ```bash
  kktcli send --chat-id "<chat_id>" "<message>"
  ```

- If the user asked for a draft or preview, report the dry run and stop.
- If the recipient or content changed after the dry run, run a new dry run.

Sending types into KakaoTalk, so kktcli brings it to the front; if it cannot verify that
KakaoTalk is frontmost it stops with `NOT_FRONTMOST` and sends nothing. Pass the message
as one argument (argument-array form when available); never build an interpolated shell
command from message text.

## 6. Send an image only with explicit intent

```bash
kktcli send-image "<recipient>" "/absolute/path/to/image.png"
```

`send-image` has no dry-run or preview mode and sends immediately, so do not run it for
draft or preview requests. It takes a recipient name, not a `chat_id`; do not send when
names are duplicated or ambiguous.

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
and anything (unread refusal, ambiguity, readiness) that stopped the requested action.
Never claim a message was delivered unless the actual send succeeded; a dry run proves
only the preview.
