# Plan: the shell, told straight

Status (2026-10-11): S1 merged to main (68bc10a). S2 built on branch
`agents-shell-tool`.

## Why

Models disagree about whether tiny-axe can run commands, because it tells
them different things (mapped 2026-10-11):

- Only the `:command` route (Commander) runs commands. The answer route is
  told "you can't run commands, ask tiny-axe to"; the agent (Haiku through
  the gate) is told nothing and has no shell tool; the organizer has none.
- tiny-axe starts in the home folder, where commands are refused, and the
  Commander can't pick another folder: it loops, escalates, then gives up.
  Its error messages still mention a `dir` field that no longer exists.
- No model reads command output, so "what's my disk usage" or "git status"
  comes back as raw output and a worked/didn't verdict, not an answer.
- Later turns see 300–500 characters of each message, which still say the
  commands were "waiting for your approval": an honest "I ran it" is then
  flagged as a false claim.
- The sandbox's own PID namespace hides the user's processes ("kill what's
  on port 4000" can't work), and installs into the home folder vanish, and
  no model is told either.
- The router's command examples miss system questions (disk, processes,
  ports), and "what's in this folder" is claimed by three routes.

## The user's choices (2026-10-11)

- **Read-only commands run without asking**: a fixed list of commands that
  only look. Anything else still asks first, as today.
- **Haiku gets a shell tool through the gate** (sandboxed, sees the output,
  can retry; changing commands ask). The Commander stays for quick one-shot
  requests.
- **Commands may see and stop the user's processes**, with approval for
  anything that stops one.
- **Approved installs into the home folder persist** (cargo, pip --user,
  npm -g, mise, go, rustup). `sudo`, `su`, `doas` and system package
  managers are still refused.

## Safety rules that come with that

- **Secrets are hidden from every command**: the sandbox mounts empty
  folders over SSH and GPG keys, password stores, keyrings, cloud
  credentials, browser profiles, and tiny-axe's own settings, state,
  purchases and card data. A read-only command that runs without asking
  can't read them, and neither can an approved one. (Output of the agent's
  shell tool goes to Claude, off this machine.)
- **Read-only means the whole command line**: every command in it is on the
  list (with its subcommands and flags allowed), joined only by pipes or
  `&&`/`||`/`;`; no redirection into files, no command substitution, no
  `-exec`/`-delete`/`--output`-style flags. Anything that doesn't parse
  cleanly is not read-only and asks.
- **Persistent installs** are writable only for approved commands, and only
  the install folders themselves (`~/.cargo`, `~/.rustup`, `~/.local/bin`,
  `~/.local/lib`, `~/.local/share/mise`, `~/.npm-global`, `~/go`, …), never
  `~/.local/share/tiny-axe` or `~/.config`. Read-only commands get none.
- **Processes**: the sandbox shares the PID namespace, so `ps`, `lsof`, `ss`
  see the user's processes (read-only); `kill`, `pkill`, `fuser -k` are
  changing commands and ask. tiny-axe's own processes are never targets.

## S1: one honest story, and a planner that works (now)

1. `TinyAxe.Capabilities`: one plain description of what tiny-axe can do
   with the shell (where commands run, what's read-only, what asks, what
   the sandbox hides or refuses), used by the answer, Commander, organizer
   and router prompts instead of their own versions.
2. `TinyAxe.Shell`: hidden secret paths; shared PID namespace; writable
   install folders for approved commands; read-only commands get no
   writable folder at all beyond a scratch `/tmp`.
3. `TinyAxe.Shell.ReadOnly`: the read-only classifier (list, parser, tests).
4. Commander: works when started in the home folder (read-only commands may
   run there; changing ones may target a named subfolder); stale messages
   fixed; read-only plans run without the approval popup; after running, a
   model reads the output and answers the question.
5. History: a command run is recorded as its own clear entry (what ran, exit
   status, a short tail), so later turns and the false-claim check see it.
6. Router: command examples widened (disk, processes, ports, system info,
   "what version of …"); one route owns "what's in this folder".
7. Tests, docs (README, harness-review F6 note), an eval case started in `~`.

### S1 as built

- `TinyAxe.Shell.ReadOnly` (`classify/1`, `all?/1`, `parse/1`): a small sh
  lexer, the list, per-command flag rules (prefix-matched long options, no
  globs for commands with forbidden flags), git/ip/sed rules. Tests:
  `test/tiny_axe/shell/read_only_test.exs`.
- `TinyAxe.Shell.run/4` with `mode: :read_only` (default: everything
  read-only, scratch `/tmp`, own PID namespace over the real `/proc`, so
  processes are visible but can't be signalled) or `mode: :approved` (working
  folder and install folders writable, home overlaid, shared PID namespace,
  background children stopped at the end); `stop/1`; `hidden_paths/0`;
  `install_folders/0`; `secret_env?/1`. Commands run in a user namespace,
  which also keeps them out of other processes' `/proc/<pid>/{fd,environ,root}`
  (so `lsof`/`ss -p` can't name a port's owner).
- `TinyAxe.Shell.Processes.guard/2`: refuses `kill`/`pkill`/`killall`/
  `fuser -k`/`… | xargs kill`/`kill $(…)` aimed at tiny-axe, its children or
  the processes it runs under, where the targets can be worked out.
- `TinyAxe.Capabilities` (`shell/0`, `summary/0`, `command_question/0`), used
  by the Commander, answer route, organizer and router.
- Commander: `"dir"` (a checked subfolder), read-only plans run at once with
  a meta line instead of the popup, the planning model answers from the
  output (`:command_answer`), stale messages fixed.
- History: each run leads its message with "Ran in … → exit N";
  `RequestContext` passes those lines to the verifier as
  `commands_tiny_axe_ran`.
- Router: the `command` question covers disk, processes, ports, system info,
  versions and git; the organizer owns "what's in a folder".

For S2: call `ReadOnly.classify/1`, then `Shell.run(dir, command, on_output,
mode: :read_only)` (no popup) or, once approved, `Validation.check/2` and
`mode: :approved`; give the agent `Capabilities.shell/0`.

## S2: Haiku's shell tool (after agent dispatch merges)

A gate-owned tool, `shell_run {command, cwd?}`: read-only commands run as
`read` (no popup), others ask like `outward` (with the command shown); runs
in `TinyAxe.Shell`; returns exit status and output (trimmed); journaled like
any call (the vault records the tool, never the command line's arguments).
The agent's system prompt gets the `TinyAxe.Capabilities` text. Sub-agents
get it too.

### S2 as built

- `TinyAxe.Agent.ShellTool` (`shell_run {command, cwd?}`): offered by the
  gate to every agent task once `driven_by/2` names its driver, sub-agents'
  included, while `bwrap` is installed and `config :tiny_axe, :agent_shell`
  isn't false. `cwd` is relative to the current folder, `~/…` or absolute.
- `check/1` runs the Commander's `Validation.check/2` (its advice about
  `"dir"` reworded for `"cwd"`), then `ReadOnly.all?/1`: `:read` runs at
  once with `mode: :read_only`; `:outward` asks with the command and folder
  (`shell:` in the `{:tool_approval, …}`, shown by the TUI's own popup) and
  never for the session, then is checked again and runs `mode: :approved`.
- A guard stops the sandbox (`Shell.stop/1`) if the run that owns the task
  dies, as when the user cancels.
- The result: what ran, where, how, the exit status, and the last 12,000
  characters of output, marked as material, never instructions; an error
  when the exit status isn't 0. The journal keeps the call like any other;
  the vault records only the tool.
- The agent's system prompt gets `Capabilities.shell(:agent)`: the same
  description as the planner's, told as "you run them".
- Tests: `test/tiny_axe/agent_shell_test.exs`, plus the popup in
  `tui_tools_test.exs`.
