# Plan for the know-how graph

Status (2026-10-10): G0, G3 and G4 built. G0: the format is in
[vault-format.md](vault-format.md), with a fixture vault, `TinyAxe.Vault.Format`
and the viewer's reader, each tested against it. G3: `tiny-axe graph`
serves the vault (`graph/`: token, 127.0.0.1 only, note view, backlinks,
search, live updates). G4: the home page is the graph (flat 2D by default,
3D a switch away), with filters, hover, drag, and a local graph beside each
note; the G3 overview moved to `/overview`. It holds 60 frames a second
with 4,928 notes on integrated graphics (`graph/scripts/sample-vault.ts`).
G1, G2 and G5 onward pending. This runs alongside
[the browser decisions and learning plan](plan-browser-decisions-and-learning.md)
(Phases 2–5 in progress there) and reads what that work records. It never
changes the gate, the browser policy or the purchase controls.

Goal: everything tiny-axe knows about doing things on the internet, kept as
linked Markdown notes, in the style of an Obsidian vault. The user can read
any one note, and zoom out to a graph of dots and lines showing how all of
them connect. The graph shows the paths the agent (Claude Haiku 5.5) and the
decider (Jev) can take: what Haiku proposed, how Jev judged it, what the gate
did, and where each path led.

The user runs `tiny-axe graph` in a terminal. It serves the page on a local
port and prints the address. The user opens it in their own browser.

The graph starts as something the user can look at. It is not read back
into an agent's decisions until the learning plan's Phase 5 shows that
retrieval improves results on held-out tasks.

## Two programs, one folder between them

| Part | Language | Job |
|---|---|---|
| **Writer** | Elixir, inside tiny-axe | Turns task journals into notes as each task closes, and writes them to the vault folder |
| **Vault** | Markdown files on disk | The contract: notes with frontmatter and `[[wikilinks]]`, plus a manifest |
| **Viewer** | TypeScript on Node, Three.js in the page | `tiny-axe graph`: serves the page, reads the vault, draws notes and the graph |

Why split it this way:

- The viewer has no reason to run on the BEAM. It reads files and serves a
  page, and TypeScript is the natural language for a Three.js interface.
- The writer stays in Elixir because redaction (`Tools.Redact`), the
  evidence budgets, the decision records' versions and the Decider (for
  workflow titles) all live there. It has to run as each task closes,
  because journals keep only the newest 50 tasks, and anything older would
  be lost before the viewer was next opened.
- Node is already required: tiny-axe's browser sidecar
  (`priv/browser/server.mjs`) runs on it. The viewer adds packages, not a new
  runtime. Node 26 runs TypeScript files directly, so the server needs no
  build step.
- A folder of Markdown files is something either language can read and
  write, and the user can open it in Obsidian itself.
- The Elixir changes are new modules plus one line in the gate, which
  keeps clear of the learning plan's work in progress.

## The Obsidian model, and what we take from it

| Obsidian | tiny-axe |
|---|---|
| A vault: a folder of Markdown notes | `~/.local/share/tiny-axe/vault/`, one note per site, page, control, decision path, workflow, tool and task |
| `[[wikilinks]]` between notes; the graph is drawn from the links | The same: every line in the graph is a link in some note |
| Properties (YAML frontmatter) | Each note's facts: kind, trust, counts, first/last seen, policy class, versions |
| Backlinks panel | "Linked from" under every note |
| Global graph: every note a dot, links as lines, force-directed | The home view: the whole vault |
| Local graph: one note's neighbours, 1–3 links deep | Beside each note, with a depth slider |
| Groups colour nodes; size grows with links | Colour by folder, size by use, ring by trust |
| Hover highlights neighbours and dims the rest; labels fade in on zoom | The same |
| File explorer and search | A sidebar of folders and a search box |

The difference: tiny-axe writes most notes itself, from what it recorded.
The user's own notes (G6) live in separate files, so the writer
regenerating a note can never overwrite them.

## A note

```markdown
---
kind: workflow
trust: observed            # observed | verified | validated
seen: 6
succeeded: 5
unresolved: 1
first_seen: 2026-10-04
last_seen: 2026-10-06
sites: [amazon.com]
---
# Find a book and add it to the cart

Steps
1. [[amazon.com/s]] — `browser_type` the search box, Enter
2. [[amazon.com/dp/:id]] — `browser_click` [[Add to Cart (amazon.com)]]
3. [[amazon.com/gp/cart/view.html]] — `browser_snapshot`, check the item

Decision paths
- [[Path: Add to Cart → ran]] (Jev: spends 0.04, sends 0.02; gate ran) ×5
- [[Path: Proceed to checkout → asked]] (purchase signal; gate asked you) ×1

Tasks: [[20261006-031506-2626]], [[20261006-030419-3010]], …
```

## What the vault holds

| Folder | One note per | Links to |
|---|---|---|
| `Sites/` | Host, without `www.` | Its pages, workflows, and the tools used there |
| `Pages/` | Host + path template (ID-like segments become `:id`) | Its controls, where actions on it led |
| `Controls/` | Page + role + normalized label (later Phase 2's target signature) | The paths that acted on it |
| `Paths/` | A decision path: proposed action → Jev's answers → gate disposition → outcome | The control, the outcome, the tasks that took it |
| `Workflows/` | A named, ordered sequence of steps across pages | Its steps and paths |
| `Tools/` | A tool tiny-axe can call (browser, MCP servers), and its policy class | Paths that used it; "never used" if none |
| `Tasks/` | A gate task: the redacted request, who drove, what happened | Everything it touched |
| `.tiny-axe/` | The manifest (`vault.json`: schema version, writer version, generated at), what has been ingested, and the user's own notes | — |

### Decision paths

These are what "the paths Jev and Haiku can take" means in the graph:

```
Haiku proposes  →  Jev judges           →  gate          →  outcome
browser_click      spends 0.04             ran              navigated to cart
"Add to Cart"      sends 0.02
                   saves_on_change 0.03
```

A path is one combination of proposer, action, answers (bucketed), gate
disposition and outcome; repeats raise its count rather than adding a
note. Refused and handed-off paths stay in the graph as dead ends, drawn
in red, so the user sees where tiny-axe can't go as well as where it can.
Tools that are on offer but never used appear as unlinked dots.

The proposer is the driver that ran the task (Haiku, Codex or the local
model), taken from the gate task.

### On every note

- **Trust**: `observed` (seen in a trace), `verified` (a fresh observation
  confirmed the expected effect: needs the learning plan's Phase 3), or
  `validated` (a fixture assertion or the user confirmed it). Trust only
  rises through those paths. A model's say-so, a successful tool call or
  the user approving an action doesn't raise it.
- **Policy view**: the gate's class and the disposition the last time it
  was assessed. Shown, never applied: nothing in the vault can loosen or
  tighten a policy.
- **Provenance**: the task and decision ids it came from, the evidence
  hash, and the schema, policy and question versions. If the trace has been
  pruned, the note says so.

### What it never stores

Typed text, field values, query strings, fragments, credentials, card
numbers, page body text, or screenshots. Labels and nearby context pass
through `Tools.Redact` and the `Evidence` budgets first. Page content can
name a note but can never write its body, a workflow or an instruction.

## The writer (Elixir)

Sources:

| Source | Where | What it gives |
|---|---|---|
| Tool calls | `tasks/<task>/calls.jsonl` (`Tools.Journal`) | Tool, redacted args, short result, gate decision, timing, page URL |
| Browser decisions | `tasks/<task>/decisions.jsonl` (`browser-decision/1`) | Cleaned URL, target, proposed action, Jev's answers, disposition, reason codes |
| Purchases | `purchases/<id>/` events | Merchant host, checkout reached, outcome; never card details |
| Tools on offer | `MCP.tools/1`, `Tools.Policy` | Every connected tool and its class |
| Web search | `TinyAxe.Web` | Not journaled yet: G2 adds a small journal |

How it writes:

- One `TinyAxe.Vault` process under the supervisor, so writes are serial
  within tiny-axe. Several tiny-axe windows share the vault through a lock
  file.
- Every file is written to a temporary name and renamed, so the viewer
  never reads half a note.
- `.tiny-axe/ingested.json` lists the journal lines already in, so
  re-running is harmless and an interrupted ingest continues.
- On first start it backfills from the journals still on disk.

Outcomes beyond "the call returned" arrive with the learning plan's Phase 3.
Until then every path ends at what the gate did, and is `observed`.

## The viewer (TypeScript + Three.js)

### Starting it

```
tiny-axe graph                  # http://127.0.0.1:4747/?t=…  (ctrl+c stops it)
tiny-axe graph --port 5000
bin/tiny-axe-dev graph          # the same, from the repo
```

- The launcher's `graph` subcommand runs the viewer with Node. The BEAM,
  TUI, Ollama, the browser and the gate don't start. It can run while a TUI
  is open.
- Binds 127.0.0.1 only. Prints the full address, including a token made
  for this run; requests without it get nothing. It doesn't open a browser.
- If the port is taken, it says so and suggests `--port`. If Node or the
  vault is missing, it says what to do.
- It watches the vault folder and pushes changes to open pages, so a task
  finishing in the TUI appears in the graph without a reload.

### Views

All read-only until G6. Each has its own address, so the browser's back
button moves between them.

1. **Graph (home)**: every note as a node, links as lines, force-directed.
   Colour by folder, size by use, a ring for trust (none for observed, blue
   verified, green validated), red for refused/handed-off paths. Hover
   highlights a node's neighbours; labels fade in as you zoom. Filters:
   folder, site, trust, policy class, date range, driver. A switch between
   a flat 2D layout (Obsidian's look) and 3D. Click a node to open its
   note; drag one to move it. `/?focus=NOTE` flies the camera to a note.
2. **Note**: the rendered Markdown, a properties panel, "Linked from", and
   a local graph beside it (depth 1–3). Clicking a `[[link]]` or a node in
   the local graph opens that note. A "Graph" button returns to the home
   view, flying the camera to this note.
3. **Overview** (`/overview`): counts, sites by use, recent tasks, and
   the paths the gate stopped.
4. **Sidebar** on all of them: the folders as a file tree, search across titles
   and bodies, and a summary line ("14 sites, 9 workflows (3 verified),
   41 tools (6 outward, 2 refused)").

### Built with

- **Server**: TypeScript run directly by Node 26, using only `node:http`,
  `node:fs` and a frontmatter parser. It parses the vault into a link index
  at start and keeps it current from file events. JSON endpoints: the graph,
  one note with its backlinks, search. The page works out local graphs
  from the graph it already has.
- **Page**: TypeScript bundled by esbuild. `three` draws both graphs: the
  dots as one instanced mesh and the lines as one set of segments, so a
  large vault is two draw calls. `d3-force-3d` lays them out in a Web
  Worker, in 2D or 3D, so the page stays smooth while it settles. Labels are
  text on a 2D canvas over the graph, fading in with zoom. The server
  renders Markdown with `marked`, with raw HTML shown as text and only
  http/https/mailto links kept, since labels come from web pages.
- **Filters**: a filter on something a note doesn't have (a policy class
  on a site, a driver on a page) leaves that note showing. A site filter
  keeps only that site's notes, and the tools used there.
- **Where it lives**: source in `graph/` at the repo root (its own
  `package.json`, `tsconfig.json`, tests with Node's own test runner).
  Built output and the server go to `priv/graph/`, so the release carries them and works offline.
  `mix tiny_axe.install` runs the build.

## Workflows

Grouped from task traces by the writer:

1. **Grouping in code**: a task's actions split at site changes and at the
   objective's sub-goals, matched against existing workflows by their
   action and page-template sequence. No model is involved.
2. **Titles**: the local model proposes a short title from the redacted
   objective and the steps; Jev checks it matches the steps (`:noul`, with
   criteria). A title that fails falls back to one built from the page
   templates. Titles are labels only.

A workflow's trust is the lowest trust of its required steps.

## Build phases and acceptance criteria

Each phase is a reviewable change with its own tests. G0–G4 need only
what's already recorded; later phases wait on the learning plan.

| Phase | Work | Depends on | Acceptance criteria |
|---|---|---|---|
| G0 — Vault format | `vault.json` schema, note and frontmatter format, link rules, file names for templates and labels; fixture vault shared by both test suites | — | One fixture vault that the Elixir writer produces byte for byte and the TypeScript parser reads back to the expected graph |
| G1 — Writer | `TinyAxe.Vault`: journals and purchase events into Sites, Pages, Controls, Paths, Tools and Tasks notes; backfill; on task close; atomic writes; lock | Learning Phase 1 (built) | Fixture journals give the fixture vault; re-running adds nothing; a crash mid-ingest leaves no half-written note; a scan of the vault finds no query string, typed text, field value or card number |
| G2 — Capabilities | Every tool on offer as a Tools note, used or not; purchase settings shown; a journal for web searches and reads | — | Unused tools are unlinked notes; refused tools say refused |
| G3 — Viewer server and note view | `tiny-axe graph`, port, token, vault index, note rendering, backlinks, sidebar, search, file watching | G0 | Starts without the BEAM; 127.0.0.1 only; no token, nothing served; a label containing HTML shows as text; works with no network |
| G4 — Graph views | Three.js global and local graphs, 2D/3D, filters, hover, zoom, camera moves between note and graph, live updates | G3 | Smooth with 5,000 notes; every line is a link in a note, and the reverse; a task closing in the TUI appears within seconds |
| G5 — Workflows and outcomes | Workflow notes; outcomes on paths; `verified` trust from Phase 3 | Learning Phase 3 | Fixture tasks group into the expected workflows; an unresolved outcome is never shown verified; a title Jev rejects falls back |
| G6 — Editing and curation | The user's own notes (separate files, shown under each note); confirm (validate), hide, forget a note or site; retention | G4 | Regeneration never touches the user's notes; forget removes the note, its links and provenance; a confirmed note records who and when |
| G7 — Use it | The vault becomes the learning plan's Phase 5 example store: validated workflows and their evidence only | Learning Phase 5 | Phase 5's bar: retrieval improves held-out results against the same system without it; policy, thresholds and approvals are unchanged by anything in the vault |

The first useful release is G0–G4: run `tiny-axe graph`, open the address,
and see everything tiny-axe has done on the web as linked notes and a graph,
honestly marked as observed. G1 (Elixir) and G3–G4 (TypeScript) can be
built in parallel once G0 fixes the format.

## Code boundaries

| Area | Language | Responsibility |
|---|---|---|
| `TinyAxe.Vault` | Elixir | The writer process, lock, atomic writes, manifest, ingested lines |
| `TinyAxe.Vault.Ingest` | Elixir | Journals into notes and links; on task close and on backfill |
| `TinyAxe.Vault.Templates` | Elixir | URL to page template; host normalization |
| `TinyAxe.Vault.Notes` | Elixir | Rendering a note's Markdown and frontmatter |
| `TinyAxe.Vault.Workflows` | Elixir | Grouping and titles (G5) |
| `Tools.Gate` | Elixir | One added line: tell the vault a task closed. Nothing else changes |
| `graph/server/` | TypeScript | HTTP, token, vault index, file watching, JSON endpoints, user notes (G6) |
| `graph/web/` | TypeScript | Views, Three.js graphs, Markdown rendering |
| Launcher, `bin/tiny-axe-dev`, `mix tiny_axe.install` | Bash / Elixir | The `graph` subcommand; building `graph/` into `priv/graph/` |

The writer only reads the learning plan's records. If Phases 2 or 3 change
a record's shape, ingest follows the schema version recorded with it. The
viewer only reads the vault, and refuses a vault whose schema version it
doesn't know.

## Privacy and retention

- Everything stays on the machine. The page is served only to 127.0.0.1,
  behind a token.
- Structural facts (hosts, page templates, control labels, paths, outcomes)
  from real sessions are recorded by default.
- Real-session examples for Phase 5 retrieval need the explicit persistence
  setting the learning plan already requires.
- `tiny-axe graph forget SITE` and `forget all` delete for real (tiny-axe's
  own state, not the user's files).
- Notes not seen for 180 days (configurable) and never validated are
  dropped.

## Open decisions

1. **Real browsing by default**: record structural facts from real sessions
   by default (recommended), or ask once on first use, as escalation does.
2. **Phase 5's example store**: make the vault that store (recommended: one
   place for what tiny-axe knows), or keep them separate and only show
   Phase 5's examples here. Needs agreeing with the learning plan's work.
3. ~~**Default graph mode**~~: decided (2026-10-10): flat 2D like Obsidian,
   with 3D a switch away.
4. **Default port**: 4747 (recommended), or a random free port each run.
