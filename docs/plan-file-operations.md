# Plan: file operations and recovery

Goal: tiny-axe can find its way around the computer, move and copy files, make
folders, and write documents (Markdown first) — with any model, including small
ones that make mistakes — and nothing it does can lose the user's data, even if
tiny-axe crashes halfway through.

## What the user can ask

- "Move the PDFs in my Downloads into Documents/papers"
- "Make a folder for each project in ~/Desktop/Projects and put the matching notes in it"
- "Write a notes.md in ~/Documents/notes summarising @~/Downloads/talk.txt"
- "Search the web for Elixir 1.19 changes and write them up in ~/notes/elixir-1.19.md"
- "What's in my Documents folder?" (answered from a listing; nothing changes)

## How a request flows

1. **Route** (Jev, same call as today). New question: *does the user want files
   moved, copied, organised, or a document written to a file?* If yes, the
   request goes to the organizer instead of the chat pipeline. Web search still
   runs first when Jev says the request needs it, so its results can feed the
   documents.
2. **Look** (model, up to 3 rounds). The model gets a map of the home folder
   (two levels, hidden folders left out), search hits for names in the request
   (`fd`), and anything `@mentioned`. It replies in a fixed JSON shape: either
   folders it wants to see inside, or a plan.
3. **Plan** (model). Steps are one of `move`, `copy`, `mkdir`, `write`. Moves
   and copies accept wildcards (`~/Downloads/*.pdf`), so the model doesn't have
   to spell out every file.
4. **Check** (code). The plan is expanded and simulated against the disk:
   sources exist, nothing gets overwritten, every change is inside the home
   folder or project and outside hidden folders. Problems go back to the model
   in plain words to fix, the way compile errors do today.
5. **Review** (Jev). *Does this plan do what the user asked, and nothing more?*
   A low score sends it back once; the score is shown to the user either way.
6. **Write** (model). Each `write` step is generated on its own as a writing
   task, from the request, the step's description, any source files, and web
   results (cited in a Sources section). Jev checks each document fits its
   description and a weak one is regenerated once.
7. **Approve** (user). A popup shows every step, previews of new files, and
   diffs of changed ones. Nothing touches the disk before `y`.
8. **Run**, journalled step by step (see Recovery). `ctrl+z` undoes it.

## Rules

| Rule | Why |
|---|---|
| No permanent delete: deleting means moving to the system Trash | The worst a bad plan can do is put files in the wrong place, or in the Trash |
| `move`/`copy` never overwrite | A name clash is an error for the model to fix |
| `write` may replace a file only after showing a diff, and only if the file is unchanged since it was read | Rewrites are deliberate and reviewed |
| Changes only inside `~` (or the project), never in hidden folders | Keeps `~/.ssh`, `~/.config` and friends out of reach |
| Reading is wider: anything the user `@mentions` | The user chose it |
| At most 200 steps per plan | A runaway plan is a mistake |

## Recovery (the BEAM part)

The BEAM restarts crashed processes; it can't un-move a half-moved folder. So
recovery is supervision **plus** a journal on disk that says exactly what was
done, written *before* each step happens.

**1. Nothing is destroyed, by design.** No deletes; no overwriting moves; files
are written to a temp file then renamed into place (atomic); the old version
of any rewritten file is backed up first; undo moves files it removes into
tiny-axe's own trash instead of deleting them.

**2. Write-ahead journal.** Each plan gets a file in
`~/.local/state/tiny-axe/plans/<id>.jsonl`, one line per event, synced to disk:

```
{"t":"plan","id":"…","request":"…","steps":[…]}
{"t":"begin","step":0}
{"t":"done","step":0,"undo":{…}}
…
{"t":"finished"}            or  {"t":"rolled_back"}
```

A plan without `finished` or `rolled_back` was interrupted. A step with `begin`
but no `done` is checked against the disk (is the file at the source, the
destination, or both?) to find out how far it got. Plain JSON lines also mean a
person can read the journal and recover by hand if it ever came to that.

**3. Supervision tree.**

```
TinyAxe.Supervisor (one_for_one)
├── TinyAxe.TaskSupervisor        pipeline runs, as today
├── TinyAxe.Ops.Supervisor (rest_for_one)
│   ├── TinyAxe.Ops.Journal       owns the journal files; scans for interrupted plans at start
│   ├── TinyAxe.Ops.TaskSupervisor
│   └── TinyAxe.Ops.Runner        runs one plan at a time in a supervised task
└── TinyAxe.TUI
```

- A plan runs in its own task, monitored by the Runner. If the task crashes,
  the Runner marks the plan interrupted.
- If the Runner itself crashes, the supervisor restarts it, and on start it
  asks the Journal for interrupted plans — the same path as after a full crash.
- If the whole BEAM dies (power, `kill -9`), the Journal finds the unfinished
  plan the next time tiny-axe starts.
- `rest_for_one`: if the Journal restarts, the Runner restarts after it, so it
  never writes to a journal that isn't there.

**4. Start-up recovery.** If a plan was interrupted, the TUI opens with:
*"A plan was interrupted after 3 of 5 steps. `r` roll back · `c` continue ·
`k` keep as is."* Continue re-checks the remaining steps first.

**5. Undo that survives restarts.** `ctrl+z` undoes the last plan, and undo
reads the journal on disk, so it works after quitting. The last 20 plans (or 30
days) are kept; undo is refused step by step for anything changed since.

**6. The TUI itself.** Today a TUI crash stops tiny-axe. Instead it should be
restarted by its supervisor with the conversation restored from a small session
store (ETS owned by its own process), and only an explicit quit stops the app.

## Status (2026-09-29)

Phases 1–6 are built and tested, and so is "move to trash" (64 tests in all,
including crash injection).

**Trash** is a `trash` step that moves files to the freedesktop.org system
Trash (`$XDG_DATA_HOME/Trash`), so the file manager's Trash can restore them as
well as `ctrl+z`. Each step reserves its Trash entry by creating the
`.trashinfo` first, and records which entry in the plan's journal folder, so
after a crash tiny-axe knows exactly whether the file reached the Trash. Plans
run steps in the order mkdir, copy, trash, move, write, so "back up, then
trash" and "replace a file" (trash the old one, move the new one into its
place) both work, while moves still never overwrite.

What changed from the plan while building it, and why:

- **The model fills one list per kind of step** (`mkdir`, `copy`, `move`,
  `write`), run in that order, instead of one list of mixed steps. With
  optional fields, the small model split each move into a step with only
  `from` and another with only `to`.
- **The review asks about each step, plus "is anything missing?"**, and the
  plan's score is its weakest link. A single "does this plan do what was
  asked, and nothing else?" question scored a correct plan 33% while its steps
  scored 75–96%. The reviewer also sees the source folders' contents, so it
  can tell whether "all the PDFs" really are all of them. Doubtful steps go
  back to the model by name, which turned an 8% plan into an 87% one.
- **A `write`'s sources are read before the plan runs**, so they're checked
  against the disk as it is now, and a source named by where a move will put
  it is read from where it is. The writer also sees the whole plan, so a
  README can list files by their new location.
- **`~` means the configured home folder** (`:fs_root`), so tests pointed at a
  fake home can never reach the real one.

## Build order

Each phase ends with tests passing before the next starts.

1. **Ops core** — expand, simulate, apply, undo (a draft is in `lib/tiny_axe/ops.ex`).
   Tests against a fake home folder.
2. **Journal, Runner, supervision, start-up recovery.** Crash-injection tests:
   kill the plan task mid-plan, kill the Runner, stop the app between steps,
   then check that recovery rolls back or continues correctly. No real files
   move until this phase passes.
3. **Organizer** — the look/plan/check/review loop and document writing.
4. **TUI** — plan popup, progress, `ctrl+z`, the interrupted-plan prompt.
5. **End-to-end on a fake home**, then on the real one with small tasks.
6. **TUI crash recovery** with session restore.

## Decisions for the user

- Limit changes to the home folder and the project, never hidden folders? (planned: yes)
- No delete at all, not even to a trash? (decided: no permanent delete; "move to trash" was built next)
- Keep undo history for the last 20 plans or 30 days?
