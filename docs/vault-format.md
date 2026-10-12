# The vault format, version 1

The contract between tiny-axe's Elixir writer (`TinyAxe.Vault`, G1) and the
TypeScript reader on tiny-axe's website (lobsterattack `api/_lib/vault/`,
which replaced the local `graph/` viewer; `docs/plan-lobsterattack.md`) for
the know-how graph. See
[the plan](plan-knowledge-graph.md) for why it exists.

Schema name: `tiny-axe-vault/1`. A reader refuses a vault whose schema it
doesn't know. Additions that a version 1 reader can ignore (a new
frontmatter key, a new section) keep the version; anything that changes an
existing name, key or link bumps it.

The fixture in [`test/fixtures/vault/`](../test/fixtures/vault/) is the
worked example: the journals in `journals/` must produce the notes in
`vault/` byte for byte, and reading `vault/` must give `graph.json`.

## Files

```
vault/
  .tiny-axe/vault.json     the manifest
  Sites/  Pages/  Controls/  Paths/  Tools/  Tasks/
  Workflows/               reserved for G5
```

- UTF-8, LF line endings, every file ends with exactly one `\n`.
- A note is `<folder>/<basename>.md`. Basenames are unique across the whole
  vault, so a link names a basename, never a folder (as in Obsidian).
- Every file is written to a temporary name in the same folder and renamed
  into place.
- `.tiny-axe/` belongs to tiny-axe: the manifest, what has been ingested
  (below), and later the user's own notes (G6). Readers ignore other files
  in it.

### What the writer keeps

`.tiny-axe/ingested.json` (schema `tiny-axe-vault-state/1`, JSON with sorted
keys) is the writer's own record, which readers ignore: for each task, how
many `calls.jsonl` lines are in and where its tab was after the last of
them; and for each note, what it adds up to (counts, dates, provenance,
the pages a path led to, a task's steps). Notes are rendered from it, not
rebuilt from the journals, so a task whose journal has been pruned keeps
its share of every count. It holds nothing a note doesn't show, plus page
keys (never URLs).

- A run reads only the lines not yet in, and only whole lines (the gate may
  be writing the last one). Running again adds nothing and writes nothing.
- Notes are written first, then the manifest, then `ingested.json`. A run
  cut short leaves the old record, so the next run redoes it in full:
  nothing is lost or counted twice. Temporary files it left are removed.
- `.tiny-axe/lock` (created exclusively; broken when older than 2 minutes)
  keeps two writers from interleaving.
- A note is written only when its text changed; the manifest only when
  something else was.
- The writer leaves alone a vault whose manifest names another schema, and
  never deletes a note.

### The manifest

```json
{
  "schema": "tiny-axe-vault/1",
  "templates": 1,
  "writer": "tiny-axe 0.1.0",
  "generated_at": "2026-10-09T00:00:00Z"
}
```

`templates` is the version of the URL template rules below.
`generated_at` changes on every write, so comparisons leave it out.

## Notes

```
---
kind: "page"
key: "shop.example/cart/view.html"
title: "shop.example/cart/view.html"
trust: "observed"
...
---

# shop.example/cart/view.html

...body...
```

### Frontmatter

One `name: value` per line, in the order given for each kind below. Every
value is a single JSON value: a string, a number, `true`, `false`, `null`, or
an array of strings. That makes it valid YAML (Obsidian reads it as
properties) and trivial to parse: everything after the first `: ` is
`JSON.parse`d. Arrays are sorted, without duplicates.

Every note starts with:

| Name | Value |
|---|---|
| `kind` | `site`, `page`, `control`, `path`, `tool` or `task` |
| `key` | The note's identity (below); never changes for the same thing |
| `title` | What the viewer shows |
| `trust` | `observed`, `verified` or `validated` (writer version 1 writes only `observed`) |

Dates (`first_seen`, `last_seen`) are UTC `YYYY-MM-DD`, from the journal's
`at`. Timestamps are ISO 8601 UTC, as in the journal.

### Body

- `# <title>` (escaped as below), a blank line, then the parts listed for the kind, one blank
  line between each. Sections with nothing to list are left out.
- Links are `[[basename]]` when the title is the basename, otherwise
  `[[basename|alias]]`. In an alias, `[` `]` `|` become `(` `)` `/` and line
  breaks become spaces.
- Text that came from a page or the user (labels, the request) is escaped:
  line breaks become spaces, and each of ``\ ` * _ [ ] < > # |`` gets a
  backslash in front.
- Links point from the specific to the general: task → path → control →
  page → site, path → tool, path → the pages it led to. Notes don't list
  what links to them; a reader shows that as "Linked from".

## Identity, titles and names

### Keys and titles

| Kind | Key | Title |
|---|---|---|
| `site` | The host: lowercased, a trailing `.` and a leading `www.` removed, `:port` kept if present | The key |
| `page` | Site key + the URL's path after templating (below); `/` when empty | The key |
| `control` | `<page key>\|<role>\|<label, lowercased>` (empty when there is no label) | `<label> (<role>)` |
| `path` | `<subject key>\|<tool>\|<answers>\|<class>\|<gate>\|<outcome>` | See below |
| `tool` | The gate's name, `<server>__<tool>` | `<tool> (<server>)`; just the name when it has no `__` (server `null`) |
| `task` | The gate's task id | The key |

- A control's **role** is the target's `role`, or its `tag` if it has none,
  or `element`.
  Its **label** is the target's `text` with whitespace collapsed and
  trimmed, cut to 80 characters; `(no label)` if empty. Its title keeps the
  label's case from the earliest call (tasks in id order, calls in order).
- Controls come only from what the page reported (a decision record's
  `evidence.target`), never from the agent's description of an element.

### Basenames

`slug(s)`: decompose (Unicode NFKD) and drop everything outside ASCII;
replace each run of characters other than `A–Z a–z 0–9 . _ -` with `-`;
trim `-` and `.` from both ends; cut to 60 characters and trim again;
`note` if nothing is left.

- `site`, `tool`, `task`: the basename is the key when `slug(key)` is the
  key itself (most hosts, every gate tool name and task id).
- Everything else (other kinds, and a host with a port such as
  `localhost:4000`): `slug(title) + " " + hash8`, where `hash8` is the first 8
  hex characters of SHA-256 of `kind + "\n" + key`. The space can't come
  out of `slug`, so these never collide with the plain names.

### URL templates (version 1)

From a URL, the writer keeps only the host and path: no credentials,
query, fragment or port defaults. Each path segment becomes:

- `:id` if it is all digits; or a UUID; or at least 8 characters of letters
  and digits containing both (`B0C1234567`, `p-106-6828384-9284208`)
- `:slug` if it has at least 3 hyphens and at least 20 characters
  (`Elixir-in-Action-Third-Edition`)
- otherwise itself

A trailing `/` is dropped, except for the root path. Examples are in
`test/fixtures/vault/templates.json`.

## The kinds

### Site

```
kind, key, title, trust, seen, looked, first_seen, last_seen
```

`seen`: actions on the site's pages; `looked`: looks at them (below).

A page (and its site) that an action only led to still gets a note, so the
link resolves: with no actions or looks, dated by when it was reached until
something else dates it.

Body: one line, e.g. `7 actions and 1 look, 2026-10-01 to 2026-10-02.`
(`on 2026-10-01` when both dates are the same; singular for 1.)

### Page

```
kind, key, title, trust, site, seen, looked, first_seen, last_seen
```

Body: `Site: [[<site>]]`, then the same counts line as a site.

### Control

```
kind, key, title, trust, site, page, role, label, seen, first_seen, last_seen
```

Body: `Page: [[<page>|<page title>]]`, then `1 action on 2026-10-01.`

### Path

A decision path: what was proposed, how it was judged, what the gate did,
and what came of it. One note per distinct key; each call on the same key
adds to its counts.

```
kind, key, title, trust, site, subject, tool, answers, class, gate,
outcome, reason_codes, seen, errors, drivers, models, versions,
first_seen, last_seen, tasks, decisions
```

| Name | Value |
|---|---|
| `subject` | Key of what was acted on: the control; for a navigation, the target page; for a call with neither, the tool |
| `site` | The subject's site key, or `null` for a tool |
| `answers` | `rules` when no decision was asked, otherwise `<question>=<bucket>` for each question in name order, space-separated; `unanswered` when the record has no answers (the decider was unavailable), shown as "Asked, but no answer came back." |
| `class` | The gate's class for the call (`read`, `local`, `outward`, `commit`, `handoff`, `refused`), or `unrecorded` |
| `gate` | What the gate did: `ran`, `approved`, `denied` or `refused` |
| `outcome` | `unchecked` until outcome verification (learning plan Phase 3) |
| `reason_codes` | From the decision record |
| `errors` | Calls whose result was an error |
| `drivers` | Models that drove the tasks (`unrecorded` if unknown) |
| `models` | Models that answered the decisions (e.g. `jev-1.13.0`) |
| `versions` | `<policy> · <questions> · <evidence schema>` of the decisions |
| `tasks`, `decisions` | Provenance: task ids and decision record ids |

Answer buckets: under 0.2 `no`, under 0.5 `unlikely`, under 0.8 `likely`,
otherwise `yes`; missing or invalid `unknown`. When a call has several
decision records, the last one counts.

Title: `<verb> "<label>" → <gate>` for a control, `<verb> <page key> →
<gate>` for a navigation, `<tool> (<server>) → <gate>` for a tool. The verb
is the browser tool's name without `browser_`.

Body:

```
- Acted on: [[<subject>|<subject title>]]      (left out when the subject is the tool)
- Tool: [[<tool>|<tool title>]]

Taken 2 times, 2026-10-01 to 2026-10-02.

## Jev

| Question | Answer |
|---|---|
| saves_on_change | no |
...                                             (or: Not asked: tiny-axe's rules classed this call.)

## Gate

Class: local · Gate: ran · Reasons: no_external_effect      (Reasons joined by ", ", left out when none)

## Led to

- [[<page>|<page title>]]                       (pages reached that differ from the page acted on, by key)
```

### Tool

```
kind, key, title, trust, server, name, seen, first_seen, last_seen
```

Body: `Used 4 times, 2026-10-01 to 2026-10-02.` A tool with no paths (looks
only) has no links: it shows as a lone dot.

### Task

```
kind, key, title, trust, driver, started, calls, ran, approved, denied,
refused, sites, pruned
```

`pruned` is `true` once the task's journal has been deleted; its notes stay.
`started` is the first call's `at`. `sites`: the sites of every page the
task acted on, looked at or was led to. A task with no calls yet has no
note. `driver` is `unrecorded` when there's no `task.json`, and the request
`(not recorded)`.

Body:

```
- Driver: claude-haiku-5-5
- Started: 2026-10-01T10:00:01Z

## Request

<the request, escaped>                          ((not recorded) if unknown)

## Steps

1. [[<path>|<path title>]]                      (each action, in order; repeats repeat)
```

## Reading the journals

Version 1 reads a task folder (`tasks/<id>/`):

| File | Written by | Used for |
|---|---|---|
| `calls.jsonl` | The gate | Every call: `tool`, `args`, `decision` (the gate's), `error`, `result` (first 300 characters), `decisions`, `at`, and `class` (planned) |
| `decisions.jsonl` | The gate, for BrowserPolicy | `evidence.target`, `answers`, `disposition`, `reason_codes`, `model`, versions |
| `task.json` | The agent | `driver`, `objective` (already redacted); a sub-agent's also `parent` (the task that dispatched it) and `part` (what it was handed) |

The gate doesn't write `class` yet (the fixture has it), and older
journals have no `decisions` or `task.json` either. Until they do: a
path's class is the call's `class`, else its last decision record's
`disposition`, else `unrecorded`; without `task.json` the driver is
`unrecorded` and the request `(not recorded)`. The request is never taken from anywhere else (such as
the evidence's copy of the objective).

- **Actions and looks.** Calls to `browser_snapshot`, `browser_take_screenshot`,
  `browser_find`, `browser_extract`, `browser_read`, `browser_scroll`,
  `browser_wait_for`, `browser_console_messages`, `browser_network_requests`,
  `browser_tabs`, `browser_inspect`, `browser_hover` and `browser_show` are
  **looks**: counted on the page and the tool, no path. A look counts on the
  page its result reports, or else where the tab was. Every other call is
  an **action** and has a path. A tool name's server is what comes before
  `__`; `browser` calls are the browser's.
- **The page.** A browser result starting `Page: <url>` says where the tab
  is after the call. The page a call acts on is where the previous browser
  call left the tab, or else the decision record's `evidence.target.page`.
  A navigation (a browser action with a string `args.url`) acts on its
  target. A call "led to" its result's page when that differs from the page
  it acted on. A result that isn't a web page (`about:blank`) leaves the tab
  nowhere known; one without `Page:` (an error) leaves it where it was. Each
  task starts with the tab nowhere known.
- **Never copied**: `args` (typed text, field values, search words), result
  text beyond the `Page:` URL, query strings and fragments, the evidence's
  `context`, and anything from `purchases/` (which holds the shipping
  address). Purchase events are left for a later version.
- One tab is assumed; tabs are not told apart in version 1.
