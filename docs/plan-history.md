# Plan: chat history

Status (2026-10-11): being built on branch `chat-history` (worktree
`../tiny-axe-history`).

## What the user asked for

(Since 2026-10-11 the website is tiny-axe's hosted home, which gets the chats
from `TinyAxe.Sync`; see `plan-lobsterattack.md`. The local `tiny-axe graph`
below is gone.)

tiny-axe keeps a history of its sessions, and the website (`tiny-axe graph`)
gets a route showing the entire history of the user's chats.

The user's choices (2026-10-11):

- **In the TUI: browse and reopen.** `/history` lists past chats; reopening one
  brings it back as a chat with its context, and talking continues in it.
- **Messages and activity.** What's kept is what the chat showed: the user's
  messages, tiny-axe's replies, and the activity lines between them (tools
  used, commands run, approvals).
- **Redacted, same key.** Saved with card numbers and token-like strings
  (keys, tokens) removed (`TinyAxe.Tools.Redact.secrets/1`), read by the
  website straight from tiny-axe's state folder (never copied into the
  vault), behind the same 127.0.0.1 address and key as the graph.

## Where it's kept (the contract between tiny-axe and the website)

`<state_dir>/history/`, where `state_dir` is `TinyAxe.Ops.Journal.state_dir/0`
(by default `${XDG_STATE_HOME:-~/.local/state}/tiny-axe`). One file per chat,
`<chat id>.json`, written whole and atomically (a temporary file, then
renamed), readable only by the user (0600). A chat is written once it has a
message from the user, and again whenever what it shows changes.

A chat id is the UTC time the chat started and four hex digits:
`20261011-153012-a1b2`. A session is one launch of tiny-axe, with an id of the
same form.

```json
{
  "version": 1,
  "id": "20261011-153012-a1b2",
  "session": "20261011-152900-77ff",
  "started": "2026-10-11T15:30:12Z",
  "updated": "2026-10-11T15:41:00Z",
  "title": "how much free space do I have?",
  "folder": "~/Desktop/Projects",
  "entries": [
    {"kind": "user", "text": "how much free space do I have?"},
    {"kind": "meta", "text": "🔧 shell_run {\"command\":\"df -h\"} (only reads)"},
    {"kind": "assistant", "text": "You have **105G** free…"}
  ],
  "context": {"history": [{"role": "user", "content": "…"}], "summary": null}
}
```

- `session`: the launch the chat started in. A chat reopened in a later
  launch keeps its id, file and `session`; `updated` moves on.
- `title`: the first line of the chat's first message, at most 80
  characters.
- `folder`: where tiny-axe was when the chat started, as `~/…`.
- `entries`: what the chat showed, in order. `kind` is `user`, `assistant`
  (Markdown) or `meta` (an activity line, plain text).
- `context`: what reopening the chat gives the model (the conversation sent
  to it, and the compacted summary of older turns, if any). The website never
  shows it.

Every text in the file is redacted before it's written.

## The website

- `tiny-axe graph` reads `--history FOLDER` (default
  `${XDG_STATE_HOME:-~/.local/state}/tiny-axe/history`), in both modes.
- `GET /api/chats` lists every chat, grouped by session, newest first;
  `?q=words` keeps the chats whose entries have them, each with a snippet.
- `GET /api/chat?id=…` is one chat, its entries in order, user and assistant
  text rendered from Markdown to HTML on the server (escaped; no raw HTML).
- The event stream says when chats change: event `history`,
  `{"changed": [ids]}`, so the pages update live.
- Routes `/chats` (every session and chat, searchable) and `/chats/<id>` (one
  chat), linked as "Chats" beside Graph and Overview.

## The TUI

- `/history` lists the 20 most recent chats, numbered, newest first;
  `/history N` reopens chat N from that list (or shows it, if it's already
  open); `/history words` lists the chats that have those words.
- A reopened chat opens as a new chat (`/new`), with its transcript and
  context, and goes on writing to the same file.
