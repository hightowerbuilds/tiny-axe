# Code quality review: 2026-09-28

A review of tiny-axe as of commit `b30ebcf`, asking the hard questions and
hunting for dead, suppressed and orphaned code. Every finding below was checked:
by a tool, a probe script, or a run of the installed copy. Nothing is taken on
suspicion.

## Status

Fixed the same evening, each with regression tests that were shown to fail
when the fix is removed:

| # | Finding | Fix |
|---|---|---|
| 1 | Code checks broken in the installed copy | The sandbox now finds Elixir and Erlang from `elixir`/`erl` on the PATH (skipping mise's shims, the release's own runtime, and a VM's `erts-*/bin`), falling back to the VM's own. **`mix tiny_axe.install` now runs a real code check in the installed copy and fails if it doesn't pass.** Verified: in the installed copy, correct code passes and a wrong doctest fails. |
| 2 | Hidden-folder bypass via `cd` | "Hidden" is measured from the home folder, whatever the location (`Ops.hidden?/1`). Commands won't run in a hidden folder. `cd` into one still works for reading, and says it's read-only. All four probes below are now refused. |
| 3 | Project edits bypass the rules | `y`/`n` now only record the decision. Accepted edits run together as one journaled plan through `Ops.Runner`, with the same rules, backups and `ctrl+z` undo as file plans. `Files.write/3` is gone. |

Fixed next, working through the review in order:

| # | Finding | Fix |
|---|---|---|
| 4 | Decider failures swallowed | Scores are read through `Decider.p/2` and `Decider.yes?/3`, and a missing or unknown score is `nil`, never a stand-in number. That mattered more than the review said: in Elixir `nil >= 0.5` is `true`, so at every `p >= 0.5` routing check (web, files, edits, navigation), a missing score would have *switched the feature on*. The local decider now returns "unknown" when under 5% of its probability landed on valid labels (the harness review's F1). Reviews show "reviewer unavailable: check this yourself", nothing is retried on a missing score, and the transcript notes, once per request, which decision couldn't be made. |
| 5 | Unknown events crash the TUI | A catch-all logs and ignores them. |
| 8 | Pruning deleted tiny-axe's trash | Pruning moves an old plan's `trash/` to the system Trash (`Ops.discard/1`); journals and backups still go. |
| 9 | Suppressed note in undo | If the undone version can't be set aside, the file is left alone and the user is told. Setting aside no longer crashes on a folder it can't create. |
| 12 | Height cache survives `ctrl+l` | `ctrl+l` clears it. |
| 14 | Scattered thresholds | Every decision threshold is in `config.exs`, with a comment (`route_threshold`, `false_claim_threshold`, `review_threshold`, `relevance_threshold`, `change_threshold`, `navigate_min`), as is the `:file_ops` switch. |
| — | Dead and orphaned code | Done, see the table below. |
| 6 | No tests for the core | The model is behind a `TinyAxe.Model` behaviour, and scripted fakes of the model and decider (`test/support/scripted.ex`) drive `Pipeline`, `Organizer` and `Commander` in tests: answering, false claims, unknown verdicts, the best attempt, routing, plans, commands, conversation context, file budgets, stale edits. `mix tiny_axe.eval` checks the real model end to end. |

Open: #7 (app-wide state), #10 (the TUI's size), #11 (duplication),
#13 (the Chrome fallback).

A scrolling test failed intermittently during the fixes and couldn't be
reproduced afterwards (8 module runs, 4 full runs). The likely cause, a test in
the same async module changing app-wide `:project_dir`, was removed when that
test moved to a non-async module. That is another instance of #7.

## Method

| Pass | How |
|---|---|
| Compiler | `mix compile --force` with warnings as errors: **0 warnings**, so no unused private functions or variables |
| Dead public code | Erlang `xref` (`exports_not_used`) over the compiled modules, then each hit checked by hand for callers in `lib/` and `test/` |
| Wiring | Every event the pipeline, planners and Runner send, cross-checked against the TUI's handlers; every `:tiny_axe` config key set vs read |
| Suppression | Searched for `rescue`/`catch`, catch-all `_ ->` fallbacks, ignored results (`_ =`), unchecked cleanup, skipped/silenced tests, `TODO`, `IO.inspect` |
| Safety rules | Probe scripts against a fake home folder, trying to reach hidden folders by every route |
| Installed copy | Ran `CodeCheck` inside the installed release, with the launcher's PATH |

## Summary

| # | Severity | Finding |
|---|---|---|
| 1 | **Critical** ✓ fixed | Code checks are broken in the installed copy: every Elixir answer "fails" |
| 2 | **High** ✓ fixed | The hidden-folder rule can be bypassed by `cd`-ing into a hidden folder |
| 3 | **High** ✓ fixed | Project edits ignore the hidden-folder rule, and aren't journaled or undoable |
| 4 | Medium ✓ fixed | Decider failures are swallowed in 10 places, so a Jev outage is invisible |
| 5 | Medium ✓ fixed | The TUI has no catch-all for events: an unknown event crashes it |
| 6 | Medium ✓ fixed | The core, `Pipeline` and `Organizer`, has no automated tests |
| 7 | Medium | App-wide mutable state (`Location`, `Session`, app env) makes behaviour and tests order-dependent |
| 8 | Medium ✓ fixed | Journal pruning permanently deletes tiny-axe's own trash and backups |
| 9 | Low ✓ fixed | A suppressed note in undo |
| 10 | Low | `TUI` is a 1,550-line module doing everything |
| 11 | Low | Duplicated logic, including two sandboxes with different rules |
| 12 | Low ✓ fixed | A side effect in `render`: the height cache in the process dictionary |
| 13 | Low | The headless-Chrome fallback is untested and runs outside bubblewrap |
| 14 | Low ✓ fixed | Scattered magic thresholds; confusable config names |
| — | Cleanup | Dead and orphaned code: see the list at the end |

---

## Critical

### 1. Code checks are broken in the installed copy

**Evidence.** Running the check inside the installed release, with the same
PATH the launcher sets:

```
{:ran, %{status: :failed, summary: "checker crashed", ...}}
timeout: failed to run command 'elixir': No such file or directory
erlang root in the release: ~c"/home/luke/.local/share/tiny-axe/release"
```

**Cause.** `Sandbox.beam_roots/0` finds Erlang with `:code.root_dir()`, and
Elixir from its library path. In a release both point inside the release,
which has no `elixir` executable. The sandbox also runs with `--clearenv` and
builds its own PATH from those roots, so the launcher's PATH fix never
reaches it. It works in development only because there both roots are mise's.

**Impact.** Every Elixir answer from `tiny-axe` is marked "does not compile"
with a bogus error. The model gets fed a false failure, burns all 3 attempts
"fixing" working code, and the verifier sees a failed check. This quietly
undoes the most reliable quality signal tiny-axe has, and it shipped in
today's install commit without being caught.

**Fix.** Find the checker's runtime from `System.find_executable("elixir")`
(and `erl`), resolving their install roots, and fall back to the code roots.
Add a test that runs `CodeCheck` from the built release, so the next release
can't regress it.

## High

### 2. The hidden-folder rule can be bypassed with `cd`

**Evidence** (probes on a fake home that has a `.config/app/settings.ini`):

| Probe | Result |
|---|---|
| At home, plan to write `~/.config/app/settings.ini` | refused ✓ |
| After `cd ~/.config`, plan to write `app/settings.ini` | **allowed** |
| After `cd ~/.config`, run commands there | **allowed, with `~/.config` writable** |

**Cause.** `Ops.changeable?/1` checks for hidden folders relative to each
allowed base: the home folder, and `Files.root()`, which is now the current
location. Inside `~/.config`, the path relative to the location contains no
dot-folder, so it passes. `Commander.check/2` allows the location itself
(`abs == Files.root()`) without checking whether it's hidden. And
`Location.cd` accepts hidden folders; only Jev's candidates exclude them.

**Hard question:** was the location ever meant to widen what can be changed?
It wasn't. It was a convenience, and it silently became a permission.

**Fix.** Measure "hidden" from the home folder, always, whatever the
location. Either refuse `cd` into hidden folders, or allow it for reading
only. And make `Commander.check` apply `changeable?` to the location too.

### 3. Project edits bypass the rules that file plans follow

**Evidence.** With the location at home (the default start since today), a
model answer with a block labelled `.config/app/settings.ini` becomes a
proposed edit. `Files.proposed_edits/1` only excludes `.git`.

**The deeper problem is two write paths with different rules:**

| | Project edits (`Files.write`) | File plans (`Ops` via `Runner`) |
|---|---|---|
| Hidden folders | allowed (only `.git` refused) | refused |
| Journaled / crash-safe | no | yes |
| `ctrl+z` undo | no | yes |
| Backup of the old version | no | yes |

Both paths ask for approval, so nothing changes silently. But the same kind
of change is safe, undoable and bounded on one path and not the other, and
which path runs depends on how Jev routed the request.

**Fix.** Send approved project edits through `Ops` as `write` steps. Then one
set of rules, the journal, backups and undo cover both, and `Files.write/3`
goes away.

## Medium

### 4. Decider failures are swallowed

When a Jev call fails (network, 429, 529, bad key), these places quietly
substitute a value and carry on. The user is never told:

| Where | Fallback | Effect when Jev is down |
|---|---|---|
| `Pipeline.relevant?/2` | `true` | off-topic search results accepted |
| `Pipeline.pick_files/3` | `[]` | no files attached |
| `Organizer.review/2` | `0.5` | plans reviewed "50%" by nobody |
| `Organizer.check_document/3` | `0.5` | documents checked "50%" by nobody |
| `Compactor.check/2` | `0.5` | summaries accepted unchecked |
| `Commander.review/…` | `review: 0.5` | commands "reviewed" by nobody |
| `Commander.outcome/2` | `nil` | "did it work?" silently skipped |
| `Organizer` / `Commander` / `Location` searches | `[]` | `fd` failures invisible |

The first routing call does report an error, so a total outage is visible.
Partial failures later in a request aren't, and a popup showing "reviewer:
50%" looks like a real judgment.

**Fix.** Return a distinct `:unavailable`, show it as "reviewer unavailable"
rather than a number, and add one transcript line per request when the
decider failed.

### 5. An unknown event crashes the TUI

`apply_event/2` has no catch-all clause (`ops_event/2` does). Every event sent
today is handled; the cross-check found none missing. But any new event, or a
typo in one, raises `FunctionClauseError`. The TUI restarts with the
conversation, but the request in progress is lost. Add a catch-all that logs
and ignores.

### 6. The core has no automated tests

`Pipeline` (routing, search, files, retries, best attempt, false-claim
checks) and `Organizer` (the whole planning loop) have **no tests**. The
planning halves of `Commander` and `Compactor` don't either. Every behaviour
there was verified by live runs against Gemma and Jev, which can't be rerun
cheaply and drift with the models.

**Why:** the decider is swappable (a behaviour), but `Ollama` is called
directly. **Fix:** put the model behind a behaviour too, with a scripted fake
for tests, the same way `Decider` is. Then the lessons from today (split
moves, fake paths, rewriting files when asked a question, false claims) can
become regression tests instead of memories.

### 7. App-wide mutable state

`Location` and `Session` are named, app-wide agents, and several modules
read `Application` env (`:project_dir`, `:fs_root`, …) at call time:

- `Files.root/0` is `Location.current/0`, so what a running pipeline reads,
  edits and checks can change if the location moves partway through. Jev
  navigation does move it partway through.
- Tests must run `async: false`, reset the location, and restore config by
  hand. One test that forgot this broke five others today.

**Hard question:** should a request carry its own context (location,
project, limits) instead of reading globals? Passing a `%Context{}` into
`Pipeline.run` would make requests reproducible, and most tests async again.

### 8. Journal pruning deletes things permanently

The docs promise nothing is deleted permanently. But `Journal.prune/0`
removes plans beyond the newest 20 (or older than 30 days), including each
plan's `trash/` folder and backups. What undo moved to tiny-axe's trash (files
tiny-axe itself wrote or copied, and replaced versions) is permanently deleted
at that point. The user's own files are never in there, since moves go back
and trash steps use the system Trash. But the wording should match, or the
trash should go to the system Trash too.

## Low

### 9. A suppressed note in undo

`Ops.undo_record/2`, for a rewritten file: `_ = trash_notes(path, trash, nil)`
discards the result of moving the undone version aside, then copies the
backup over it. If the move failed, that version is overwritten with no note.
It's still recoverable from the staged `write-<n>` file in the journal, but
the user isn't told. Surface the note.

### 10. `TUI` is doing everything

At 1,550 lines, the TUI module holds:

- rendering and the sidebar;
- six popups (edit, plan, commands, recovery, undo, and the sidebar
  meter/summary);
- key handling, `cd`/`pwd` built-ins, copy;
- the command, plan, compaction and edit flows;
- scroll measurement and caching.

It's the module most likely to break when anything changes. **Split along the
seams it already has:** transcript rendering and scrolling; popups; flows
(runs, commands, plans, compaction); keys.

### 11. Duplication

| What | Copies |
|---|---|
| `pct/1` | `TUI`, `Organizer`, `Commander` |
| Folder listing / visible entries | `Location.listing`, `Organizer.listing` + `visible_entries`, `Commander.folder_listing` + `visible_entries` |
| Name search with `fd` + word extraction | `Organizer.search`, `Location.search`, plus word splitting in `Files.shortlist` |
| The JSON-plan loop (rounds, bad JSON, give-up message, review, one retry) | `Organizer.plan/5` and `Commander.plan/5` |
| `truncate/2` | `CodeCheck`, `Web` |
| **bubblewrap sandboxes** | `Sandbox` (code checks: `/home` hidden, no network, env cleared) and `Shell` (commands: home overlaid, network on, env inherited) |

The two sandboxes matter most. They're right to differ (code checks vs
installing packages), but two hand-built argument lists mean a fix to one
(like #1) doesn't reach the other. **Fix:** one `Sandbox` with named profiles.

### 12. A side effect in `render`

Transcript heights are cached in the TUI process dictionary from inside
`render/2`, because render can't return state. It works, and it's fast (about
3 ms per frame). But the cache is only reset when the width changes, so
`ctrl+l` leaves every old entry's height in memory. That's a small leak over a
long session. Clear it on `ctrl+l`, or key the cache by the transcript.

### 13. The headless-Chrome fallback

`Web.fetch/2` falls back to headless Chrome for pages that render with
JavaScript. It was never exercised end to end (every page tried had text),
has no test, and loads URLs from search results outside bubblewrap, relying
on Chrome's own sandbox and a throwaway profile. Either test it and run it
sandboxed, or remove it until a page actually needs it.

### 14. Thresholds and names

- Decision thresholds are scattered: 0.7 accept, 0.6 web, 0.5
  files/change/organize/command/review/compaction, 0.4 navigation, 0.2 file
  pick. Some are in `config.exs`, the rest are literals in code. Tuning
  tiny-axe means hunting for them. Put them all in config.
- `:file_access` (project files) and `:file_ops` (file plans) are different
  switches with confusable names, and `:file_ops` isn't documented in
  `config.exs`. `:commands` is.

---

## Dead and orphaned code

| Item | Status | Action |
|---|---|---|
| `lib/tiny_axe.ex` (`TinyAxe.hello/0`) | the untouched `mix new` "hello world"; nothing calls it | ✓ deleted |
| `Ops.Runner.busy?/0` | no callers in `lib/` or `test/` | ✓ deleted |
| `Ops.Runner.undo_last/1` | only a test calls it; the TUI uses `undo_plan/2` | kept: public API for "undo the newest plan" |
| `Location.reset/0` | only tests call it; **its docs claim `ctrl+l` does** | ✓ docs fixed (`ctrl+l` doesn't move) |
| `Decider.Local.ask/2` | public, but only called inside its module | ✓ private |
| `Files.inside_project?/1`, `Ops.hash_path/1`, `Decider.Jev.api_key/0,1` | public but used only within their own module | ✓ private |
| `Ops.trash_dir/0`, `Journal.state_dir/0`, `Context.estimate/2` | documented accessors (and tests use `estimate`) | kept public |
| `Web.parse_*`, `Web.unwrap_*`, `CodeCheck.extract/1`, `Commander.check/2`, `Decider.Local.label_distribution/2` | public test seams, already `@doc false` or documented | fine |
| `config/config.exs` comment: "`:project_dir` defaults to the current directory" | stale: `mix tiny_axe` now starts at home | ✓ updated |
| `Files.write/3` | dead once #3 routed edits through `Ops` | ✓ removed |
| `bin/tiny-axe` (dev launcher) | still useful for development, but shares the installed command's name | ✓ renamed `bin/tiny-axe-dev` |

## Suppressed code, the full list

| Kind | Where | Verdict |
|---|---|---|
| Decider failures → fake values | 10 sites (#4) | fix |
| `_ = trash_notes(...)` | `Ops.undo_record/2` (#9) | fix |
| `catch` | `Ollama.stream_chat` (turns Ollama's error chunks into `{:error, …}`), `Shell.kill` (port already closed) | fine: both are converted, not hidden |
| `rescue ErlangError` | `tiny_axe.install` (mise missing → no extra PATH) | fine |
| Unchecked `File.rm`/`rm_rf` | 11 sites, all cleanup of temp files; 3 (`.trashinfo` in settle/undo) could leave a stale Trash entry | acceptable; note it |
| `@moduletag :capture_log` | recovery and crash tests | fine: the crashes are deliberate |
| Tests skipped without bubblewrap | code-check, shell and command tests `{:skip, …}`; `location_test` used `flunk` | ✓ consistent (skip) |
| `check_command_outcome: false` in tests | the "did it work?" judgment is only live-tested | covered by #6 |

## What's in good shape

- **No compiler warnings, no `TODO`s, no stray `IO.inspect`,** and no
  suppressed warnings (`@dialyzer`, `nowarn`).
- **Event wiring is complete:** every event sent today has a handler.
- **Recovery is proven:** the crash-injection tests fail when recovery is
  deliberately broken.
- **Secrets never reach the repo or the screen:** the key only lives in
  git-ignored `.env` and `~/.config/tiny-axe/env` (600), and the key check
  prints only the key's length.

## Suggested order

1. **#1 code checks in the release:** broken right now, in the shipped copy.
2. **#2 and #3, the hidden-folder bypasses:** route project edits through
   `Ops` and measure "hidden" from home.
3. **#4 and #5, visible decider failures and a catch-all handler:** small,
   and they turn silent failures into visible ones.
4. **#6, a model behaviour and fake:** lets everything after this land with
   tests.
5. The dead code and stale docs: a quick cleanup pass.
6. #7, #10, #11, #13, #14 as the code is next touched.
