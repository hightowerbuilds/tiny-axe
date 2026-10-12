# Plan: chat with tiny-axe from lobsterattack.yachts

Status (2026-10-12): R1 written (lobsterattack branch `remote-chat`); migration not applied, functions not deployed. Branch `remote-chat` (worktree `../tiny-axe-remote`).

## What the user asked for

Go to lobsterattack.yachts, sign in, and chat with the tiny-axe running on
this machine.

The limits (2026-10-12): no tunnel; only Supabase (edge functions, Realtime,
the database) plus Jev. The user chose the websocket route (Supabase
Realtime). Security gets its own pass later, but the user called it very
important, so the plan still keeps the bare minimum from the start: private
channels, the owner only, no purchases from a remote chat.

## The shape

Nothing reaches into this machine. tiny-axe dials out to Supabase Realtime
over a normal `wss://` connection, the same way a browser tab does, and both
ends meet on one private channel per account.

```
browser (lobsterattack.yachts)          Supabase                     this machine
  supabase-js, signed in        ── wss ──▶ Realtime ◀── wss ──   TinyAxe.Remote
  remote-send (edge fn) ────────────▶ buster_ta_remote ──trigger──▶ channel
                                     remote-reply (edge fn) ◀──────── final reply
```

- **One channel per account:** `remote:<account_id>`, private (Realtime
  Authorization: RLS on `realtime.messages`).
- **Messages are kept.** The browser sends through the `remote-send` edge
  function, which inserts a row into `buster_ta_remote`. A trigger
  (`realtime.broadcast_changes`) puts it on the channel. A message sent while
  tiny-axe is off waits in the table.
- **Replies stream.** While it works, tiny-axe broadcasts `delta` events
  (text pieces, every ~250 ms) and `status` events ("thinking", "running a
  command") straight on the socket. These are temporary. The finished reply
  is saved through `remote-reply`, which marks the message answered.
- **Online/offline:** Realtime Presence. tiny-axe tracks itself on the
  channel; the page shows a green dot while it's there.
- **Catch-up:** on every (re)connect, tiny-axe calls `remote-pending` for
  unanswered messages, oldest first, before it listens.

## Edge functions (Supabase, Deno)

| Function | Called by | Does |
|---|---|---|
| `remote-token` | tiny-axe | checks the site key (sha256 against `buster_ta_keys`, like the site API does) and returns a short-lived JWT (15 min, `role: authenticated`, `sub` = the owner) for Realtime. tiny-axe renews it before it runs out |
| `remote-send` | browser | checks the Supabase session, that the user owns the account, and inserts the message |
| `remote-pending` | tiny-axe | unanswered messages for its account |
| `remote-reply` | tiny-axe | saves the finished reply (redacted on the machine first) and marks the message answered |

Decided in R1: the project signs sessions with ES256 (its JWKS lists one EC
key), so nothing can be minted. `ta-remote-token` instead asks Auth's admin
API for a magic-link token for the owner (no email is sent) and verifies it on
the spot: an ordinary session of the owner, no refresh token handed out. The
old session is signed out when tiny-axe renews (`previous`). Both ends are
then the same user, so the Realtime rule is just `topic = 'remote:' ||
auth.uid()`.

Functions are named `ta-remote-token`, `-send`, `-pending`, `-reply`, and
`-history` (the page's first load), since the Supabase project is shared.

## Database (migration 0009)

- `buster_ta_remote`: `id`, `account_id`, `chat_id`, `role` (`user` |
  `assistant`), `body`, `status` (`pending` | `working` | `answered` |
  `failed`), `reply_to`, `created_at`. RLS on, no grants to anon (the same as
  0006).
- Broadcast trigger on insert/update → `remote:<account_id>`.
- `realtime.messages` policies: the account's owner (browser session) and the
  machine token for that account may join, send and listen on
  `remote:<their account_id>`, and nothing else.

## tiny-axe side

- **`TinyAxe.Remote`**, supervised next to `TinyAxe.Sync`: a Phoenix-channels
  client over `mint_web_socket` (or `slipstream`, which wraps it and handles
  heartbeats and rejoin; to be decided in R2). It gets a token, joins the
  channel, tracks presence, sends a heartbeat every 25 s, reconnects with
  backoff, and renews the token.
- **Where a remote message runs:** in a chat of its own in the running TUI,
  named "remote", through the same `Run.request` path (the router, Jev,
  Gemma/Haiku, and every gate). You see it locally and can stop it. It works
  only while tiny-axe is open; a headless service mode can come later.
- **Approvals:** for now any step that would ask y/n is refused in the remote
  chat ("needs approval at the machine"). Purchases are never allowed from
  remote. Proper approvals are part of the security pass.
- **Redaction:** replies and deltas go through `TinyAxe.Tools.Redact` before
  they leave, like Sync.
- **Off switch:** `/remote on|off` in the TUI and `remote: false` in
  settings; off is the default until R4.

## Site side (lobsterattack)

- A `/remote` page: transcript, input box, the online dot, and the live
  status line. supabase-js `channel('remote:<id>', { config: { private: true } })`.
- Supabase CLI needed to deploy functions (not installed here). Install it
  through mise and run `! supabase login` once; secrets are set with
  `supabase secrets set`, typed by the user and never pasted into chat.

## Steps

- **R1 – Supabase:** migration 0009, the four edge functions, Realtime
  policies. Prove with a script: a fake machine joins, the browser-side
  client sends, the row lands and the broadcast arrives.
- **R2 – `TinyAxe.Remote`:** connect, join, presence, heartbeat, reconnect,
  catch-up. Tests against a local fake Phoenix socket (Bandit is already a
  dependency).
- **R3 – Remote chat in the TUI:** a remote message → the "remote" chat →
  streamed deltas → saved reply. Approvals refused, purchases blocked.
- **R4 – `/remote` page,** deployed. Real check: phone on cell data → reply
  from this machine.
- **Later – security pass:** web approvals, members other than the owner,
  rate limits, audit log, a key rotation story.

## Open questions

- HS256 JWT minting vs a machine Auth user (R1 decides).
- `slipstream` vs plain `mint_web_socket` (R2).
- Headless mode, so remote chat works without the TUI open (after R4).
