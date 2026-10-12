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
mix tiny_axe --dir ~/code/app                  # where to start (default: your home folder)
```

To install a `tiny-axe` command you can run from any folder:

```
mix tiny_axe.install
cd ~/code/app && tiny-axe          # opens in the folder you run it from
tiny-axe --dir ~/notes --model gemma4:12b-it-qat --decider local
```

tiny-axe needs Ollama. If it isn't running when tiny-axe starts, tiny-axe starts it: through your systemd user service (`systemctl --user start ollama`) if you have one, otherwise by running `ollama serve` in the background (logging to `~/.local/state/tiny-axe/ollama.log`). It's left running when you quit. It also warns you if the configured model isn't downloaded. You can open as many copies of tiny-axe as you like at once.

This builds a release (it carries its own Erlang runtime, so it doesn't need the repo or `mix`) into `~/.local/share/tiny-axe/release`, and a launcher into `~/.local/bin/tiny-axe`. Settings, such as `TYPESAFE_API_KEY=…`, live in `~/.config/tiny-axe/env`; the first install copies this repo's `.env` there. Logs and plan journals go to `~/.local/state/tiny-axe/`. Run the install again after pulling changes. In development, `mix tiny_axe` (which starts in your home folder) or `bin/tiny-axe-dev` (which starts where you run it) run straight from the repo.

Keys: `enter` send · `alt+enter` newline · `esc` cancel · `pgup`/`pgdn` scroll (with an empty prompt also `↑`/`↓`, the mouse wheel, `home`/`end`) · `ctrl+y` copy the newest code block (again for older ones) · `ctrl+z` undo the last file plan · `ctrl+k` compact · `ctrl+t` sidebar · `ctrl+o` next chat · `ctrl+l` clear this chat · `ctrl+c` quit. Proposed file edits appear as a diff: `y` accept · `n` skip · `esc` skip the rest · `↑`/`↓` scroll. Accepted edits are saved together as one plan, so `ctrl+z` undoes them.

Ask it to move, copy, rename, organise or delete files anywhere in your home folder, or to write a document (e.g. "write notes.md in ~/Documents/notes summarising @~/Downloads/talk.txt"). It shows the whole plan, with previews of any files it will write, and does nothing until you press `y`. `ctrl+z` undoes the last plan (after confirming), even after a restart. Deleting means moving to the system Trash (`~/.local/share/Trash`, so your file manager can restore it too); nothing is deleted permanently or overwritten, and hidden folders are off limits. See [docs/plan-file-operations.md](docs/plan-file-operations.md).

Ask it to run commands ("install Vite with the React template in my tiny-app repo", "run the tests") or something only a command can tell ("how much disk space do I have?", "what's using port 4000?", "which node version is installed?", "what changed in git?") and it plans the commands, then runs each one in a bubblewrap sandbox, with the network on and nothing able to wait on a prompt:

- Commands that only look (`ls`, `cat`, `grep`, `find`, `du`, `df`, `ps`, `git status`/`log`/`diff`, `node --version`, … joined only by pipes, `&&`, `||` or `;`, with no redirection into files and no `$(…)`) run straight away without asking, with the whole computer read-only. The list and its rules are in `TinyAxe.Shell.ReadOnly`; anything it doesn't recognise asks.
- Anything else is shown for approval first. Approved commands can change only the folder they run in; other writes in the home folder vanish, except installs into `~/.cargo`, `~/.rustup`, `~/.local/bin`, `~/.local/lib`, `~/.local/share/mise`, `~/go`, `~/.bun`, `~/.deno` and the like, which persist. They can't run in the home folder itself or a hidden folder (started in `~`, the planner names the subfolder, e.g. `code/web`). `sudo` and system package managers are refused.
- Every command has SSH and GPG keys, keyrings, cloud and registry credentials, browser profiles, shell histories and tiny-axe's own settings, state and purchases hidden from it, and secret-looking environment variables removed. Commands see your processes (`ps`), not inside them; `kill`/`pkill` ask first and can't target tiny-axe's own processes.
- Output streams into the transcript; then the model reads it and answers your question (for approved commands, the decider also judges from the output whether it worked). Each run is recorded at the start of the reply ("Ran in ~/x: `df -h` → exit 0"), so later turns know what ran. Commands time out after 10 minutes (`:command_timeout`) and can't be undone with `ctrl+z`. Outside this, answers never claim to have run anything: the verifier checks for that.

The status bar shows how full the model's context window is (`ctx 58%`). Once the conversation reaches half the window (`:compact_at`), the older turns are compacted into a summary (the newest two stay word for word), which appears in a sidebar on the right with a context meter; `ctrl+k` compacts on demand and `ctrl+t` shows or hides the sidebar. The transcript keeps everything, with a marker where the compaction happened.

tiny-axe keeps track of where it is, like a shell: the title shows 📍 and the current folder. Type `cd <folder>` or `pwd` at the prompt to move or check (no model involved). When a request names another folder ("in my tiny-app repo…"), the decider picks it from real folders nearby, and after commands run, the location follows them (e.g. into `web/` after `cd web && npm install`). Every model is told where it is and what's there, relative paths mean "here", and commands run here.

The first time tiny-axe opens, it sets up your account on its website, [lobsterattack.yachts](https://lobsterattack.yachts): the model suggests usernames (the site says which are free), and you type a password, which goes only to the site (shown as dots; no model sees it). tiny-axe doesn't go on without one; "I already have an account" signs in from another computer. `/account` shows it. What tiny-axe learns (the know-how graph) and your chats are sent to your own page of the site as they change, for you, and anyone you let in, to see after signing in; anything not yet sent goes once the site can be reached. Type `/graph` (or `/graph chats`) for the link, which tiny-axe shows and copies, never opening a browser itself. The agent can search what it knows there too. See [docs/plan-lobsterattack.md](docs/plan-lobsterattack.md).

Type `/new` to start another chat; the one you leave keeps working in the background, and its questions still pop up wherever you are ("asked by chat 1"). `/chats` lists them (what each is about, and whether it's working, waiting for you or idle), `/chat N` or `ctrl+o` switches, and `/chat close` closes the one on screen once it's idle. The status bar shows which chat you're in and what the others are doing; `esc` cancels only the chat on screen, `ctrl+c` quits them all.

Every chat is kept on disk, in `~/.local/state/tiny-axe/history/` (one file per chat, with card numbers and keys removed), so it outlives tiny-axe. `/history` lists the recent ones, `/history words` finds chats that mention something, and `/history N` reopens one with its context, to carry on where it left off. Your page of tiny-axe's website shows every chat, from every session, under **Chats** (without what reopening one gives the model). See [docs/plan-history.md](docs/plan-history.md).

Mention files or folders with `@path` (relative to the project, `~/…` or absolute) to give them to the model. Otherwise the decider picks the project files a request is about.

## How it works

- `TinyAxe.Decider` — behaviour for typed decisions (`:noul`, `:choice`, `:score`), matching Jev's API.
  - `Decider.Local` — reads option probabilities from Ollama token logprobs (one-token completions, run in parallel).
  - `Decider.Jev` — TypeSafe Jev backend, used by default when `TYPESAFE_API_KEY` (or `JEV_API`) is set in `.env`; check the key with `mix tiny_axe.jev_check`.
- `TinyAxe.CodeCheck` — compiles and doctests Elixir/Python answers (public functions with no doctests count as a failure; code that needs a package the sandbox lacks is skipped) inside `TinyAxe.Sandbox` (bubblewrap: read-only root, no network, `/home` hidden, 30s timeout). Skipped, never run unsandboxed, if `bwrap` is missing.
- `TinyAxe.Web` — keyless web search (DuckDuckGo Lite, then Brave, then Bing) and page reading, with headless Chrome for pages that need JavaScript. The Decider decides when a request needs the web (`:web_threshold`) and whether results are on topic; answers cite sources as [1], [2] and end with a source list.
- `TinyAxe.Files` — lists and reads project files, and proposes edits. `@path` mentions are attached; otherwise the Decider decides whether a request is about project files and picks up to 3 from the listing (a pick-one question over the file paths, up to 255 options with Jev). When the Decider says the user wants changes, the model writes whole files in path-labelled code blocks (```` ```elixir lib/foo.ex ````), and the TUI shows each as a diff to approve. Accepted edits run as a journaled plan (like file tasks), so they follow the same rules (inside the project, outside hidden folders), are refused if the file changed since it was read, and can be undone with `ctrl+z`; files too long to show the model in full are never offered.
- `TinyAxe.Organizer` — plans file tasks: the model looks around the home folder and fills a fixed JSON shape (folders to make, copies, moves, files to write); `TinyAxe.Ops` expands and simulates the plan and sends problems back; the Decider reviews each step; documents are written one at a time and checked.
- `TinyAxe.Ops.Runner` / `TinyAxe.Ops.Journal` — carry out approved plans one step at a time, writing each step to a journal on disk (`~/.local/state/tiny-axe/plans/`) before and after it runs. A plan interrupted by any crash is found there at the next start and can be rolled back, continued or kept. Undo restores backups and moves anything it takes away into the plan's `trash/` folder. The last 20 plans (up to 30 days) are kept.
- `TinyAxe.Context` / `TinyAxe.Compactor` — the context meter (real token counts from Ollama, estimates in between calibrated from them) and compaction: the model condenses older turns, folding in any earlier summary, and the Decider checks it keeps what's needed to continue; a weak summary is regenerated once, and one that wouldn't save space is dropped.
- `TinyAxe.Commander` / `TinyAxe.Shell` — plans shell commands (commands, a subfolder to run in, a reply) in a fixed JSON shape and checks them in code (no `sudo` or system package managers, no changing commands in the home folder itself or a hidden folder, no scaffolding into a non-empty folder, nothing that would stop tiny-axe). Read-only plans (`TinyAxe.Shell.ReadOnly`) run at once in the read-only sandbox; others get the decider's review of each command and wait for approval. The same model then reads the output and answers. `TinyAxe.Capabilities` describes all this, from the same lists, to every model that needs to know; `esc` stops a running command and whatever it started.
- `TinyAxe.Location` — the current folder. Only code moves it (`cd`, the decider's pick of a named folder from real candidates, where commands went); models only see it. File reading and editing, relative paths and commands all follow it.
- `TinyAxe.Model.ClaudeCLI` / `TinyAxe.Model.CodexCLI` — Claude (Claude Haiku 5.5, `claude-haiku-5-5`) and Codex models (e.g. `gpt-6-luna`) through `claude -p` and `codex exec` on your subscriptions, never an API key: API-key variables are removed, a call that isn't on the subscription is refused, and both run with no tools, so tiny-axe keeps control of files, commands and the browser. `mix tiny_axe.cli_check` tests them. Roles are set in `config :tiny_axe, :models`; see [docs/plan-browser-and-cli-models.md](docs/plan-browser-and-cli-models.md).
- `TinyAxe.Agent` / `TinyAxe.Tools.Gate` / `TinyAxe.Browser` — requests that need tools go to an agent (Claude Code's loop by default, or Codex, or tiny-axe's own loop for the local model) whose only tools come through tiny-axe's gate: every call is classed (reads run; anything that sends something asks you first; purchases and typing passwords are refused), redacted and journaled. Tools come from tiny-axe's own browser (Chrome via Playwright, in its own profile, never showing card numbers or passwords to a model) and any MCP servers you connect with `mix tiny_axe.mcp add …` (templates for GitHub, memory, fetch and more; secrets from your keyring). Type `tools` in the TUI to see what's connected. A Claude or Codex agent can hand up to 4 independent parts of a request to sub-agents that work at the same time (`TinyAxe.Agent.Dispatch`, the gate's `dispatch_agents`): each has its own gate task, limits, journal and browser tab, asks you through the same queue ("asked by agent 2"), can't buy anything or start more agents, and stops when you cancel. Agents and sub-agents can also run shell commands themselves (`TinyAxe.Agent.ShellTool`, the gate's `shell_run`), under the Commander's rules: commands that only look run at once in the read-only sandbox, and any other shows you the command and its folder and runs only if you say yes, every time. See [docs/plan-browser-and-cli-models.md](docs/plan-browser-and-cli-models.md).
- `TinyAxe.Escalation` — when the local model falls short on evidence (code still failing its check, no answer the verifier accepts, a plan it couldn't make work), tiny-axe can try a bigger model: Claude Haiku 5.5, the only Claude model it uses (`config :tiny_axe, :models, escalate:`). The first time a request would leave your machine, it asks (`y` for the session, `n` to stay local); it stops using Claude once either of its usage windows is 90% used, so your own quota is left for you. `escalate: false` turns it off.
- `TinyAxe.Session` — holds the conversation outside the TUI, so if the TUI crashes its supervisor restarts it with the conversation restored.
- `TinyAxe.Pipeline` — routes the request, streams a response, checks any code (failures go back to the model with the real compiler/test output), then asks the Decider whether it addresses the request, showing it the same web pages and files the model saw; retries below `:accept_threshold`, and if every attempt falls short, answers with the highest-rated one.
- `TinyAxe.TUI` — ExRatatui app. Logs go to `~/.local/state/tiny-axe/tiny_axe.log` because stdout belongs to the TUI.

Requires Ollama running locally. Settings are in `config/config.exs`.

## Design review

See the [harness review](docs/harness-review.md) for an assessment of the methodology,
current reliability gaps, realistic Gemma/Qwen expectations, and a prioritized
implementation and evaluation plan.

## Evaluation

`mix tiny_axe.eval` runs fixed tasks (`eval/tasks.exs`) through the real model
and decider, each in a throwaway home folder, and checks the outcomes
independently of tiny-axe's own judgment: the files a plan leaves, tests
written with the task, required facts, the planned command, and the route.
Summaries go to `eval/results/`. See `mix help tiny_axe.eval` for options
(`--split`, `--only`, `--repeat`, `--model`, `--decider`, `--think`).

Browser policy has its own synthetic classification benchmark:

```
mix tiny_axe.browser_eval                         # scripted replay, no model calls
mix tiny_axe.browser_eval --live --decider jev     # synthetic observations sent to Jev
mix tiny_axe.browser_eval --live --decider local --max-decisions 40
```

Each browser decision tiny-axe makes for real is traced in the task's
`~/.local/state/tiny-axe/tasks/<task>/decisions.jsonl`: the redacted evidence
it was shown, the policy and question versions, which Jev model answered,
the answers, and what the gate then did.

The benchmark executes no browser actions. Replay checks policy composition; live mode
checks classification with the configured decider and excludes injected
outage cases. JSON results include evidence, questions, answers, source hashes,
and budget skips. This is not a complete browser-task success rate; for that,
`mix tiny_axe.browser_task_eval` runs 24 full tasks (development and holdout
sites) through the real agent, gate and browser against local fixture sites,
scoring what the sites actually received (`--driver scripted --decider
scripted` runs offline; `--max-jev-calls` and `--max-tasks` cap a real run). See the
[browser decisions and learning plan](docs/plan-browser-decisions-and-learning.md)
for the build status and remaining work.

## License

MIT; see [LICENSE](LICENSE).
