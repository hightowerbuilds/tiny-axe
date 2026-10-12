# Plan: LobsterAttack, tiny-axe's hosted home

Status (2026-10-11): L1 and L2 built (lobsterattack branch `tiny-axe-home`,
not pushed or deployed; migration 0006 applied to the Supabase project 2026-10-11). Site work in
`../lobsterattack` (repo hightowerbuilds/lobsterattack, deployed by Vercel);
tiny-axe work on branch `lobsterattack` (worktree `../tiny-axe-lobster`).

## What the user asked for

LobsterAttack is rebuilt as the place where everything tiny-axe does is
shown. The local website (`tiny-axe graph` on 127.0.0.1) goes away; the
hosted site replaces it. Because the site is on the internet, it needs a way
in: an MCP lets tiny-axe's model reach the site, log in, and add to the
graph. Security starts very simple and is strengthened as we go.

The user's choices (2026-10-11):

- **Login to view.** Nothing on the site is visible without signing in.
- **Graph and chats.** Both go up: the know-how notes (`docs/vault-format.md`)
  and every chat's messages and activity (`docs/plan-history.md`).
- **The posts feed goes.** The BusterClaws feed UI and its API are removed.
  The `buster_posts` and `buster_profiles` tables stay in Supabase, untouched.
- **Built in the lobsterattack repo**, which Vercel already deploys.

## What's there now

- LobsterAttack: React 19 + Vite Plus + TanStack Router; a Hono API on
  Vercel Edge (`api/index.ts`, every route under `/api`); Supabase project
  `gbnizxzurmbzeelacztr`, **shared production**, so every new table is
  prefixed `buster_`. Email + password sign-in already works. `/notes`,
  `/board`, `/comments`, `/media`, `/agents` are dead (their tables don't
  exist).
- tiny-axe's viewer (`graph/`): SolidJS + Three.js pages (graph, note,
  search, chats) served by a Node server that reads the vault and
  `<state_dir>/history/` from disk. `TinyAxe.Graph` runs it as the MCP
  server `graph` (`graph_open`/`graph_close`).
- Size today: 321 notes (1.4 MB, the largest 1.5 KB) and 3 chats (44 KB).
  Small enough to upload whole on first sync.

## The shape

```
tiny-axe (this computer)                      Vercel                Supabase
  TinyAxe.Vault ──┐                      ┌── /api/mcp  (agent key)
  TinyAxe.History ├─ MCP over HTTP ──────┤                         buster_ta_* tables
  agent (gate) ───┘  key from keyring    ├── /api/*    (viewer login)  (RLS: deny anon)
                                         └── /  the site (Solid)
```

- **One way in for tiny-axe: MCP over HTTP** at `/api/mcp`. tiny-axe's MCP
  client already speaks streamable HTTP with headers (`TinyAxe.MCP.Client`),
  so the site is connected as the reserved server `graph`, like the local
  one today. Both tiny-axe's own code (pushing notes and chats) and the
  model (adding to the graph) go through it.
- **The model never holds the credential.** The key lives in the keyring
  (`secret-tool`, like other MCP secrets) and is sent as a header by
  tiny-axe. "Logging in" happens inside the connection.
- **Redaction stays in Elixir**, before anything leaves the machine (the
  vault writer's escaping and `Tools.Redact.secrets/1` on chats). The site
  runs the same card/token pattern again as a second net.

## Security, version 1 (simple)

- **tiny-axe → site: one API key.** 32 random bytes, made once by a script,
  shown once, stored in the keyring. The site keeps only its SHA-256
  (`buster_ta_keys`, the hashing LobsterAttack's old `auth.ts` already does),
  mapped to the owner's Supabase user. Every `/api/mcp` call needs
  `Authorization: Bearer <key>`; a wrong or missing key is 401.
- **People → site: username + password** (Supabase Auth underneath: a username stands for `<username>@users.tiny-axe.invalid`). Sign-up is turned
  off: the owner makes accounts with `tinyaxe-key add-user`. The
  API checks the session's JWT (`auth.getUser`) on every `/api/*` read, and
  the user must be in `buster_ta_members`, which says whose site they see.
  Signing in alone isn't enough: the Supabase project is shared with other
  apps, and their users are in `auth.users` too.
- **Data: one owner.** Every row carries `owner_id`. The API uses the
  service-role key (server-side only, never in the bundle) after checking the
  key or JWT, and filters by owner. RLS is on with no policies for `anon` or
  `authenticated`, so the browser can't read tables directly even with the
  public anon key.
- Rate limit stays (the existing in-memory bucket: per instance, not global;
  fine for v1). CORS limited to the site's own origin.

Later, in rough order: per-device keys with names, last-used and revoke
(UI); scopes (push-only vs. model-write); viewer roles (read-only guests);
audit log of every write; durable rate limit (Upstash/Supabase); key
rotation from the TUI; email confirmation via Resend.

## Accounts, made in tiny-axe (2026-10-11)

The user's choices: the model helps the user make a username in tiny-axe
itself, the first time it opens; **every tiny-axe user owns their own space**
on the site (their graph and chats, seen by them and whoever they let in);
the step is **required** (tiny-axe doesn't go on without an account). The
account is the identity later things (card settings, ...) hang on.

- `TinyAxe.TUI.AccountFlow`, a popup like `/credit-card`: make a new account
  or sign in to one. For a new one, the user says what they'd like to be
  called and the local model suggests usernames (`TinyAxe.Account.suggest/2`),
  of which the site's free ones are offered; or they type their own (checked;
  a taken one brings suggestions close to it). The password is typed twice.
- The password is typed into `TinyAxe.Account` a keystroke at a time (as a
  card goes into `TinyAxe.Cards`); the TUI holds only how many dots to show.
  It's sent once to the site and forgotten. tiny-axe's key comes back and goes
  into the keyring (`service tiny-axe key site`); the username and site go in
  `<state_dir>/account.json`.
- Site: `POST /api/signup` (makes the account, confirmed at once so Supabase
  never mails the `.invalid` address, makes it the owner of its own space and
  returns a key once; undone if any part fails), `POST /api/device` (a new key
  for an existing account), `GET /api/username`. Usernames are kept in
  `buster_ta_accounts` (migration 0007). Each is rate limited per address.
- `config :tiny_axe, :site, url: "https://www.lobsterattack.yachts", required:
  true`; `TINY_AXE_SITE_URL` points tiny-axe at a local API in development.
  `/account` shows the account (or starts the flow if there's none).

## Data (Supabase, migration `0006_buster_ta.sql`)

| Table | Holds | Key |
|---|---|---|
| `buster_ta_keys` | key hash, owner, label, created, last used, revoked | id |
| `buster_ta_members` | who may see whose site (owner or viewer) | user |
| `buster_ta_notes` | basename, folder, kind, title, the note's whole text, content hash, source (push/agent), updated | (owner, basename) |
| `buster_ta_chats` | chat id, session, started, updated, title, the chat JSON (jsonb, as in `plan-history.md`, without `context`) | (owner, chat id) |
| `buster_ta_vault` | the manifest (schema, templates, writer, generated_at) | owner |

- Notes are stored as the vault's own text, so the site builds the graph
  exactly as `graph/src/vault.ts` + `graph.ts` do now (ported into
  `api/_lib/vault/`; a test checks the fixture still gives `graph.json`). Upserts skip a note whose hash didn't
  change.
- Nothing is ever deleted by tiny-axe (matching the vault writer, which
  never deletes a note). A model-added note is an ordinary note with
  `trust: "observed"` and `source: "agent"`.

## The MCP tools (`/api/mcp`)

Stateless JSON-RPC over HTTP (no sessions, so it suits Edge functions).

| Tool | Who | Class in tiny-axe's gate |
|---|---|---|
| `graph_search {q}` / `graph_note {id}` | model | read |
| `graph_link {focus?, page?}`: the site URL to give the user | model | read |
| `graph_add_note {folder, title, body, links}` | model | outward (asks, v1) |
| `graph_overview` | model | read |
| `vault_push {manifest, notes[]}` (≤ 200 notes / call) | tiny-axe code only | not offered to models |
| `chat_push {chat}` | tiny-axe code only | not offered to models |

The push tools are called by `TinyAxe.Vault` and `TinyAxe.History`
directly, as `/graph` calls `graph_open` now, and the gate hides them from
agents. Whether `graph_add_note` should run without asking (it only writes
to the user's own private site) is the first thing to revisit once it works.

## tiny-axe's side

- `TinyAxe.Graph` connects to `<site>/api/mcp` over HTTP instead of
  starting `graph/dist/server.js`. Config: `config :tiny_axe, :graph, url:`;
  the key from the keyring (`mix tiny_axe.graph_key set` stores it).
- **Pushing, crash-safe.** `TinyAxe.Sync` (L3, above): the record of what was
  last sent, compared with the disk, is the outbox.
- `/graph` prints the site's link (no local port); `/graph close` goes.
  `graph_open`'s 127.0.0.1 server, its token cookie and SSE are removed;
  `mix tiny_axe.install` stops installing `graph/`. `graph/` itself stays
  in the repo until the site has the same pages, then is deleted.

## The site

- **Switch React → Solid**, so `graph/web` (app, graph-page, views, chats,
  store, filter, layout, the Three.js renderer and its d3-force worker) moves
  over almost unchanged. TanStack Router has a Solid build; or keep the
  viewer's own small router. Vite stays (`vite-plugin-solid`).
- Pages: sign in, overview, graph (2D, 3D switch), note, search, chats, chat.
  The coral-reef look and the ASCII hero can frame the sign-in page.
- Live updates: polling every 15 s (`/api/changes?since=`) in v1, in place of
  SSE (Edge functions can't hold connections open cheaply). Supabase
  Realtime later.
- Removed: the posts feed, `src/lib/posts.ts`, `api/_routes/posts.ts`,
  `profile.ts`, and the dead `/notes`, `/board`, `/comments`, `/media`,
  `/agents` routes and their middleware.

## Phases

Each phase is one commit; nothing is pushed or deployed without the user's
go-ahead.

1. **L1, data and auth.** Done 2026-10-11: migration `0006_buster_ta.sql`,
   `scripts/tinyaxe-key.ts` (key, let-in, list, revoke), `/api/mcp`, the
   viewer reads (`/api/me`, `vault`, `graph`, `note`, `search`, `chats`,
   `chat`, `changes`, the local viewer's JSON shapes). `bun test api/test`
   runs against an in-memory store; tiny-axe's own `TinyAxe.MCP.Client`
   connected, listed the tools and pushed the fixture.
2. **L2, the site.** Done 2026-10-11: React, TanStack and the posts feed
   are gone; `src/` is the viewer (its own small router kept), with a sign-in
   page and a Sign out button. `/api/changes?since=` says which notes and
   chats changed, so polling (every 15 s, paused while the tab is hidden)
   updates the page as the event stream did. `vercel.json` adds the viewer's
   CSP (plus the Supabase origin for signing in), `noindex` and HSTS. Checked
   in headless Chrome on the built site with Vercel's headers, the fixture
   pushed through `/api/mcp`, and Supabase's sign-in faked: sign-in, wrong
   password, graph, overview, note after reload, chats, a chat pushed while
   open appearing, sign out, an account not let in, phone width; no CSP
   errors. The coral-reef images and ASCII hero went with the feed (in git
   history if wanted back).
3. **L3, tiny-axe pushes.** Done 2026-10-11. `TinyAxe.Graph` connects to
   `<site>/api/mcp` over HTTP with the account's key; agents get the read
   tools (they run without asking) and the gate hides `vault_push` /
   `chat_push`. `TinyAxe.Sync` sends what changed: `<state_dir>/site-sync.json`
   records each note's and chat's hash as last sent, so the difference between
   it and the disk is the outbox (crash- and offline-safe, no separate queue);
   runs a moment after the vault writer or the history writes, at start, after
   an account is made, and every 5 minutes after a failure. A chat's `context`
   never leaves. `/graph` and `/graph chats` print the site's link. The MCP
   client's status redacts headers and env. Tested against a fake site (real
   MCP client over HTTP), through the gate as an agent sees it, and end to end
   against the real site API (memory store): 28 notes and a chat sent, read
   back through the viewer API, nothing sent twice.
4. **L4, the model writes.** Done 2026-10-11. `graph_add_note {title, body}`
   saves a note in a Notes folder on the site (kind `note`, `source: "agent"`,
   named slug + hash8 of the title, so the same title replaces the model's
   earlier note; `[[id]]` links join it to the graph; titles escaped, cards
   removed, sizes capped; migration 0008). In tiny-axe it's `outward`: the
   gate asks each time (y once, a for the session, n). The viewer shows Notes
   in their own colour. Tested through the gate (no sends nothing, yes sends
   it) and end to end against the real site API.
5. **L5, local site removed.** Done 2026-10-11: `graph/` is deleted (its
   reader, viewer and tests live in lobsterattack now), with
   `tiny-axe graph`, its install step and the dev launcher's build; the next
   `mix tiny_axe.install` removes an installed copy
   (`~/.local/share/tiny-axe/graph`).

## What the user has to do

- **Supabase access:** apply the migration (dashboard SQL editor, or the
  Supabase CLI logged in), and create the viewer account(s) with "Auto
  Confirm". The service-role key is needed in Vercel's env (it's already
  there for the posts API).
- **Vercel:** env vars for the deploy (`SUPABASE_URL`,
  `SUPABASE_SERVICE_ROLE_KEY`, `CORS_ORIGIN`); approving each deploy. For
  local development, the same values in `../lobsterattack/.env` (not in the
  fresh clone: the old one was on the Mac).
- Neither the `vercel` nor the `supabase` CLI is installed here.

## Open questions

- Site URL / domain (the current Vercel one, or a new name).
- Should model-added notes run without asking? (v1: ask.)
- Keep the LobsterAttack name and look, or rename the site for tiny-axe?
