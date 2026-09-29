# tiny-axe

A terminal UI that helps small local models handle code and writing tasks by
wrapping them in a Jev-style decision layer: **route → generate → check → verify**.

## Setup

Requirements: Linux, [mise](https://mise.jdx.dev) (pins Elixir 1.19 / Erlang 28 via `mise.toml`), [Ollama](https://ollama.com), and [bubblewrap](https://github.com/containers/bubblewrap) 0.9+ (`bwrap`) for sandboxed code checks and commands. `fd` and `ripgrep` are used when present; `wl-copy`, `xclip` or `xsel` for `ctrl+y`.

```
git clone https://github.com/hightowerbuilds/tiny-axe && cd tiny-axe
mise install
mix deps.get
ollama pull gemma4:e4b-it-qat
cp .env.example .env    # optional: add a TypeSafe key to use Jev as the decider
mix tiny_axe
```

Without a TypeSafe key, decisions come from the local model (`TinyAxe.Decider.Local`); `mix tiny_axe.jev_check` tests a key.

## Running

```
mix tiny_axe                                   # gemma4:e4b-it-qat for everything
mix tiny_axe --model qwen3.5:4b                # different generator
mix tiny_axe --decider jev                     # TypeSafe Jev for decisions (default when TYPESAFE_API_KEY or JEV_API is in .env)
mix tiny_axe --dir ~/code/app                  # project to read and edit (default: current directory)
```

To start it from any project, with that project as the one it reads and edits, put the launcher on your PATH (run this from the tiny-axe folder):

```
ln -s "$PWD/bin/tiny-axe" ~/.local/bin/tiny-axe
cd ~/code/app && tiny-axe
```

Keys: `enter` send · `alt+enter` newline · `esc` cancel · `pgup`/`pgdn` scroll (with an empty prompt also `↑`/`↓`, the mouse wheel, `home`/`end`) · `ctrl+y` copy the newest code block (again for older ones) · `ctrl+z` undo the last file plan · `ctrl+k` compact · `ctrl+t` sidebar · `ctrl+l` clear · `ctrl+c` quit. Proposed file edits appear as a diff: `y` save · `n` skip · `esc` skip the rest · `↑`/`↓` scroll.

Ask it to move, copy, rename, organise or delete files anywhere in your home folder, or to write a document (e.g. "write notes.md in ~/Documents/notes summarising @~/Downloads/talk.txt"). It shows the whole plan, with previews of any files it will write, and does nothing until you press `y`. `ctrl+z` undoes the last plan (after confirming), even after a restart. Deleting means moving to the system Trash (`~/.local/share/Trash`, so your file manager can restore it too); nothing is deleted permanently or overwritten, and hidden folders are off limits. See [docs/plan-file-operations.md](docs/plan-file-operations.md).

Ask it to run commands ("install Vite with the React template in my tiny-app repo", "run the tests") and it plans them, shows them for approval, then runs each one in a bubblewrap sandbox: only the working folder can change (the home folder is overlaid, so other writes vanish), the network works, and nothing can wait on a prompt. Output streams into the transcript; afterwards the decider judges from the output (not just the exit status) whether it worked. Commands can't be undone with `ctrl+z`. Outside this, answers never claim to have run anything: the verifier checks for that.

The status bar shows how full the model's context window is (`ctx 58%`). Once the conversation reaches half the window (`:compact_at`), the older turns are compacted into a summary (the newest two stay word for word), which appears in a sidebar on the right with a context meter; `ctrl+k` compacts on demand and `ctrl+t` shows or hides the sidebar. The transcript keeps everything, with a marker where the compaction happened.

Mention files or folders with `@path` (relative to the project, `~/…` or absolute) to give them to the model. Otherwise the decider picks the project files a request is about.

## How it works

- `TinyAxe.Decider` — behaviour for typed decisions (`:noul`, `:choice`, `:score`), matching Jev's API.
  - `Decider.Local` — reads option probabilities from Ollama token logprobs (one-token completions, run in parallel).
  - `Decider.Jev` — TypeSafe Jev backend, used by default when `TYPESAFE_API_KEY` (or `JEV_API`) is set in `.env`; check the key with `mix tiny_axe.jev_check`.
- `TinyAxe.CodeCheck` — compiles and doctests Elixir/Python answers (public functions with no doctests count as a failure; code that needs a package the sandbox lacks is skipped) inside `TinyAxe.Sandbox` (bubblewrap: read-only root, no network, `/home` hidden, 30s timeout). Skipped, never run unsandboxed, if `bwrap` is missing.
- `TinyAxe.Web` — keyless web search (DuckDuckGo Lite, then Brave, then Bing) and page reading, with headless Chrome for pages that need JavaScript. The Decider decides when a request needs the web (`:web_threshold`) and whether results are on topic; answers cite sources as [1], [2] and end with a source list.
- `TinyAxe.Files` — lists, reads and writes project files. `@path` mentions are attached; otherwise the Decider decides whether a request is about project files and picks up to 3 from the listing (a pick-one question over the file paths, up to 255 options with Jev). When the Decider says the user wants changes, the model writes whole files in path-labelled code blocks (```` ```elixir lib/foo.ex ````), and the TUI shows each as a diff to approve. Writes stay inside the project, are refused if the file changed since it was read, and are never offered for files too long to show the model in full.
- `TinyAxe.Organizer` — plans file tasks: the model looks around the home folder and fills a fixed JSON shape (folders to make, copies, moves, files to write); `TinyAxe.Ops` expands and simulates the plan and sends problems back; the Decider reviews each step; documents are written one at a time and checked.
- `TinyAxe.Ops.Runner` / `TinyAxe.Ops.Journal` — carry out approved plans one step at a time, writing each step to a journal on disk (`~/.local/state/tiny-axe/plans/`) before and after it runs. A plan interrupted by any crash is found there at the next start and can be rolled back, continued or kept. Undo restores backups and moves anything it takes away into the plan's `trash/` folder. The last 20 plans (up to 30 days) are kept.
- `TinyAxe.Context` / `TinyAxe.Compactor` — the context meter (real token counts from Ollama, estimates in between calibrated from them) and compaction: the model condenses older turns, folding in any earlier summary, and the Decider checks it keeps what's needed to continue; a weak summary is regenerated once, and one that wouldn't save space is dropped.
- `TinyAxe.Commander` / `TinyAxe.Shell` — plans shell commands (working folder, commands) in a fixed JSON shape, checks them in code (no `sudo`, no home-folder or hidden working folder, no scaffolding into a non-empty folder), has the decider review each one, and runs approved commands in the sandbox with a timeout (`:command_timeout`); `esc` kills a running command.
- `TinyAxe.Session` — holds the conversation outside the TUI, so if the TUI crashes its supervisor restarts it with the conversation restored.
- `TinyAxe.Pipeline` — routes the request, streams a response, checks any code (failures go back to the model with the real compiler/test output), then asks the Decider whether it addresses the request, showing it the same web pages and files the model saw; retries below `:accept_threshold`, and if every attempt falls short, answers with the highest-rated one.
- `TinyAxe.TUI` — ExRatatui app. Logs go to `log/tiny_axe.log` because stdout belongs to the TUI.

Requires Ollama running locally. Settings are in `config/config.exs`.

## License

MIT; see [LICENSE](LICENSE).
