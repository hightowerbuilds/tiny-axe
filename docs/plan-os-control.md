# Plan: changing this computer

Status (2026-10-12): the appearance slice is built (below, "Appearance as built"); the rest is plan. Branch `os-control` (worktree ../tiny-axe-os).

Goal: tiny-axe can change the computer it runs on (theme, display, audio,
wifi, bluetooth, keybindings, installed apps, services, settings) when asked.
Gemma tries first, along a fixed path that code checks at every step. Claude
Haiku 5.5 takes over only when that path falls short.

## What's there today

- Commands run only in bubblewrap. Approved ones can change only their own
  folder; the home folder is overlaid (other writes vanish), and `~/.config`
  and the session sockets (Hyprland, D-Bus) are hidden. So nothing a command
  does can change the desktop.
- `sudo`, `su`, `doas` and system package managers are refused
  (`Commander.Validation`).
- Escalation already exists. The Commander climbs to Haiku after 4 failed
  planning rounds (`Escalation.climb/5`), and Haiku agents get `shell_run`
  through the gate.

## Why this OS makes a fixed path possible

Omarchy 4.0.4 publishes its own command catalog:
`omarchy commands --json` lists 367 commands in 63 groups, each with
`route`, `binary`, `summary`, `args`, `examples` and `requires_sudo`
(83 need root). Many groups also have a `list` or `current` command
(`omarchy theme list`, `omarchy font list`), so the valid arguments can come
from the computer instead of the model. A small model doesn't have to write
shell. It picks from a menu, and code fills in and checks the rest.

## The user's choices (2026-10-12)

- **sudo: passwordless for a short list.** A sudoers rule lets a small set of
  named root actions run without a password. Everything else that needs root
  is refused, and the user gets the exact command to run themselves.
- **Approvals:** low-risk Omarchy commands run without asking: theme,
  background, font, brightness, volume, toggles (nightlight, idle, etc.) and
  restarting a component. Each can be undone. Everything else shows a y/n
  first: config edits, services, installs, removals, wifi or bluetooth
  changes, and any root action.
- **Scope: any command, unsandboxed.** Approved OS commands run as the user
  with the real home folder, no bwrap. Secrets are not hidden from them.

## How a request flows

1. **Route.** A new router question, `os`: *does the user want something
   about this computer changed: its look, display, sound, network, devices,
   keybindings, installed apps, services or settings?* It's separate from
   `command`, which stays for running tools in a project.
2. **Pick (Jev, no model writing).** Two choice questions over the real
   catalog. First the group, out of 63 options; then the command within that
   group (at most 38 options, under Jev's 255). Each option is the
   command's summary. If either pick falls under `:os_pick_min`, the request
   escalates.
3. **Fill (Gemma, fixed JSON).** Gemma fills only the arguments, from the
   command's `args` and `examples`. Wherever the group has a list command,
   code checks each value against its output (a theme name must appear in
   `omarchy theme list`) and sends mismatches back with the real choices.
   After 2 failed rounds, the request escalates.
4. **Check (code).**
   - The command is classed as `:low_risk` (the allowlist above),
     `:changes`, or `:root` (`requires_sudo`).
   - `:root` must map to a verb on the sudo list, or it's refused with the
     command for the user.
   - Interactive commands are refused, since nothing can answer them. The
     `menu`, `setup` and `*-switcher` commands and anything that opens a
     picker go to the user as "run this yourself".
5. **Run.**
   - `:low_risk` runs at once.
   - Anything else waits for the y/n popup (the unified permission popup
     from the `panels` branch, once that's merged).
   - Every OS run is journaled.
6. **Confirm.**
   - The output, plus a read-back command where one exists
     (`omarchy theme current`), shows whether it worked.
   - The decider judges the outcome from that output, not from the exit code.

**Not in the catalog** (e.g. "bind super+B to open Brave", "turn off the
second monitor"): Gemma proposes a whole-file edit of the right file under
`~/.config/hypr/` (or another config), shown as a diff through the existing
`Files` edit flow. It needs approval, gets a recovery point, and Hyprland
gets checked (below).

**Free-form commands** ("restart pipewire", "enable the bluetooth
service"): Gemma plans them with the Commander's JSON shape in a new `:os`
mode. They're approved every time, then run unsandboxed.

## When Haiku takes over

Escalation follows the existing rules (`Escalation.climb/5`, `without_asking`,
quota stop at 90%), triggered by any of these:

- a weak catalog pick: group or command under `:os_pick_min`
- arguments still invalid after 2 rounds
- a command that ran but failed its outcome check
- a Hyprland edit reverted for config errors
- a request that needs several steps (the router's `os` answer plus a
  "needs more than one change" question)

Haiku gets one new gate tool, `os_run {command | route+args}`. It goes
through the same classification, approvals, sudo list and recovery points
as Gemma's path, so escalation changes who plans, not what's allowed. Its
system prompt gets the catalog's group summaries and
`Capabilities.os/0`, so what it's told matches what the code does.

Each successful pick (request → route + args), with the decider's
confidence, goes into the journal. That's the raw material for
Jev-approved recipes later, which would replay a repeated request with no
model at all.

## Recovery (before any of this runs for real)

- **Config recovery points.** A git repository in tiny-axe's state folder
  uses `~/.config` as its work tree and tracks only text config. It leaves
  out browser profiles, caches, files over 1 MB, and the secret places in
  `Shell.secret_places/0`. tiny-axe commits before and after every OS
  change, catalog commands included (`omarchy theme set` rewrites files).
  `ctrl+z` puts the changed files back from the "before" commit and runs the
  matching reload (`hyprctl reload`, `omarchy restart <component>`). It
  works after a restart because it's on disk, recorded in the same
  `Ops.Journal`.
- **Hyprland guard.** After any change under `~/.config/hypr`, tiny-axe
  runs `hyprctl reload` and then `hyprctl configerrors`. Any error reverts
  to the "before" commit and reloads again. The desktop is never left on a
  broken config.
- **Root changes.** `/` is btrfs with snapper and limine-snapper-sync. Every
  root verb takes a snapper snapshot first (`snapper create`), inside the
  same sudo helper, so there's no second password. Undo from tiny-axe isn't
  automatic. It shows the snapshot number and how to roll back
  (`omarchy snapshot restore`, or boot the snapshot from Limine).
- **Interrupted runs.** The journal entry is written before the run. At the
  next start, an unfinished OS run offers to restore the "before" commit,
  the same way an interrupted file plan does today.

## The sudo list (a root helper, not raw sudo)

A sudoers wildcard like `pacman -S *` also lets in extra flags. So the
sudoers rule allows only one root-owned script,
`/usr/local/bin/tiny-axe-root`. It takes a fixed verb and checks its
arguments itself:

| verb | runs | argument check |
|---|---|---|
| `install <pkg>` | snapshot, then `pacman -S --needed --noconfirm -- <pkg>` | package name regex; must exist in a sync repo (`pacman -Si`) |
| `remove <pkg>` | snapshot, then `pacman -Rns --noconfirm -- <pkg>` | installed, explicitly installed, not in a protected list (base, linux*, omarchy*, hyprland, sddm, limine, btrfs-progs, sudo) |
| `update` | snapshot, then `pacman -Syu --noconfirm` | none |
| `service <start\|stop\|restart\|enable\|disable> <unit>` | `systemctl …` | unit must exist; not in the protected list (sddm, systemd-*, NetworkManager stop/disable) |
| `snapshot` | `snapper create` | none |

- AUR packages (yay) stay off the list: yay installs built files with
  `pacman -U` as root, and that can't be bounded the same way. tiny-axe hands
  over the `yay` command instead.
- The user installs the helper and the sudoers file themselves, once
  (`! sudo install …`, shown by `mix tiny_axe.os_setup`). tiny-axe never
  edits `/etc`.
- **To confirm:** the user's final list of verbs.

## Safety rules that still hold

- Approval every time for anything that isn't `:low_risk`. Never "for the
  session".
- Requests from the site's Chat tab (remote) can't run OS changes. The
  security pass for remote approvals hasn't happened.
- Never touch tiny-axe's own processes (`Shell.Processes.guard/2`).
- Unsandboxed output can contain secrets, and Haiku's tool results leave
  the machine. The gate's redaction applies to `os_run` results like any
  other.
- `curl … | sh`, `rm -rf` on `~`, `/` or `~/.config`, and writes to tiny-axe's
  own state are refused by pattern, even unsandboxed.

## Phases

- **O0 Experiments.**
  - Run 10 catalog commands from tiny-axe's BEAM (theme set, toggle
    nightlight, brightness, `restart waybar`, `hyprctl reload`) to confirm the
    environment they need: `HYPRLAND_INSTANCE_SIGNATURE`, `WAYLAND_DISPLAY`,
    D-Bus.
  - Mark which commands are interactive, and time the git snapshot of
    `~/.config`.
- **O1 Catalog path.**
  - Build `TinyAxe.OS.Catalog` (load, cache by Omarchy version, classify),
    the router's `os` question, the Jev group/command pick, Gemma's argument
    fill checked against list commands, `:low_risk` runs, and y/n for the
    rest.
  - No root, no config edits yet.
- **O2 Recovery points.**
  - Build `TinyAxe.OS.Snapshot` (git in the state folder), `ctrl+z` for OS
    changes, the Hyprland guard, and journal recovery at start.
  - Turn on config edits and free-form `:os` commands.
- **O3 Haiku.**
  - Build the `os_run` gate tool, `Capabilities.os/0`, and the escalation
    triggers.
  - Live-check that a weak pick climbs to Haiku and that Haiku's change
    still goes through the popup.
- **O4 Root helper.**
  - Write `tiny-axe-root`, the sudoers file and `mix tiny_axe.os_setup`.
  - Map `requires_sudo` catalog commands to the verbs (`omarchy pkg install
    x` → `install x`).
- **O5 Eval.**
  - Add about 30 OS tasks to `eval/tasks.exs` against a fake catalog and a
    dry-run runner (nothing changes), split dev/holdout.
  - Measure Gemma's pick and fill accuracy and how often it escalates.
  - Real runs are capped like earlier evals.

## Appearance as built (2026-10-12)

The user asked for Omarchy's appearance tools first: terminal font size,
tab arrangements, and anything else in that area the model can reach. This
is O1's first slice, and it doesn't wait on the sudo list (none of it needs
root). It's a typed setting list, not the whole catalog, which makes the
path even narrower for Gemma.

- **`TinyAxe.Appearance.Settings`** has 29 settings, each with a kind, a
  reader and a setter.
  - Omarchy commands: theme, background, font, text_size, display_scale,
    brightness, nightlight, idle_lock, do_not_disturb, bar, bar_position,
    bar_transparent.
  - Ghostty config lines: terminal_font_size, terminal_padding,
    terminal_opacity, terminal_cursor, terminal_cursor_blink,
    terminal_tab_bar, terminal_tab_position.
  - Hyprland options in tiny-axe's block of `looknfeel.lua`:
    window_gaps_inner and window_gaps_outer, window_border,
    window_rounding, window_layout (dwindle, master or scrolling),
    window_dim_inactive, window_inactive_opacity, window_blur, animations,
    and window_tab_bar (groupbar).
  - All 29 were read live on this machine.
- **`Appearance.Value`** checks values.
  - Choices come from the computer and ignore case and spacing.
  - Numbers must be in range. `+2` or `-2` is relative to the current
    value, and "bigger" or "smaller" is one step.
  - Booleans accept on/off words. An image must be a real file.
- **Flow (`Appearance.run/4`):**
  1. A snapshot reads every setting in parallel.
  2. Gemma fills `{changes: [{setting, value}], reply}`. The setting is a
     JSON-schema enum, and the value can be a string, number or boolean.
  3. Code checks the values. Problems go back with the real choices, for
     up to 3 rounds; the temperature rises each retry, and broken JSON
     counts as a failed round.
  4. Jev reviews each change (with its description and current value) and
     whether the changes together do everything asked. A doubtful plan
     goes back once.
  5. If it's still doubtful, or never passed the checks, the request
     escalates to Haiku with the same shape.
  6. A plan that passed the review runs without asking. A plan that's
     still doubtful after Haiku waits for a y/n in the commands popup
     (`{:appearance_plan, …}`, `Appearance.execute/2` checks again before
     running).
- **Running** goes through `Appearance.Runner`, unsandboxed, with argv
  instead of a shell. Secret env vars are removed, except the D-Bus
  address. Each run has a 30 s timeout.
- **`Appearance.ConfigFiles`** writes the config files.
  - Ghostty lines are replaced in place, then terminals reload
    (`omarchy restart terminal`).
  - The Hyprland block is followed by `hyprctl reload` and `hyprctl
    configerrors`, and any new error reverts the file. This was verified
    live with a no-op value and with a bad key.
  - Writes are atomic.
- **`Appearance.Undo`** keeps the last 20 requests on disk.
  - Undo restores the whole file when it still holds what tiny-axe wrote.
  - Otherwise it sets the value from before again, and actions are run
    again.
  - `/look undo`, and `/look` lists the current values.
- **Routing:** the router question is `appearance`. An `origin: :site`
  request (the Chat tab) only describes the changes.
  `Capabilities.appearance/0` tells the answer route.
- **Live dry run** (real Gemma and Jev, nothing applied), about 15 prompts:
  - These passed on Gemma alone: font bigger or smaller, theme plus bar
    position, no gaps plus square corners, tabs at the bottom always,
    see-through terminal, scrolling layout, hide the bar, night light
    plus dimming, blinking bar cursor, next background, and "what font
    am I using?".
  - Jev doubted "put the terminal tabs at the bottom" and "bigger text
    everywhere", both correct plans. Haiku made the same tabs change, so
    in the TUI that one ends at the popup.
  - A vague "make everything easier to read" (theme, text size, padding)
    split the reviewer.
- **Tests:** `test/tiny_axe/appearance_test.exs` (fake desktop,
  `test/support/fake_desktop.ex`; tests never reach the real desktop) and
  `tui_appearance_test.exs`.

**Next:** Jev's review is noisy on correct single-setting plans. Options are
tuning the questions, or skipping the review when the change is one setting
the request names outright.

## Review fix and O1 as built (2026-10-12)

- **Review fix** (ef7b86d):
  - Each setting lists the words a request uses to name it
    (`Settings.named?/4`; a theme or font can also be named by its value).
  - Changes to named settings skip Jev's review. Only the rest are reviewed.
  - In the live dry run, all of the wrongly doubted requests went through
    on Gemma alone in about 1 s.
- **Rename:** `TinyAxe.Appearance` is now `TinyAxe.Desktop`, with the
  router question `desktop` and events `:desktop_*`.
- **O1, the rest of the catalog.** All 284 non-root Omarchy commands were
  sorted. About 240 are reads, hardware probes, interactive menus, dev
  tools, or installs and removals that belong with O4. The useful rest is
  typed items in `Desktop.System`, not a raw route picker. Typed items
  give Gemma a narrower path, and the result was 14/14 right items in a
  live dry run.
  - Settings, with read-back and undo: volume, sound_muted, mic_muted,
    audio_output (pactl; what's playing moves too), bluetooth (asks),
    power_profile, default_browser, default_editor and default_terminal
    (installed choices only; all three ask), and touchpad (only where
    there is one).
  - Actions, which can't be undone: screenshot, screen_recording (asks),
    restart (audio, shell, terminal, …), restart_network (wifi or
    bluetooth; asks), launch_app (`uwsm-app`, detached; a lookup over the
    installed `.desktop` entries, where a miss suggests the closest
    names), open_url (http and https only, `xdg-open`, detached),
    reminder ("10 check the oven"), and power (lock, logout, reboot or
    shutdown; asks).
- **Risk:** a plan containing any `risk: :ask` item waits for the y/n
  popup ("these always ask first"). The rest runs at once.
- **Volume guard:** with no number in the request, the volume moves at
  most 20 (`max_jump`), and "louder" or "quieter" is ±10. Before this,
  Gemma set "louder" to 100.
- Commands outside the typed list (webapp install, dns, plugins, …) are
  for Haiku's `os_run` in O3, always with approval.

## O2 as built (2026-10-12)

- **`Desktop.Snapshot`** keeps a git repo at `<state_dir>/config-snapshots`
  whose work tree is `~/.config`.
  - It tracks an allowlist of desktop config folders: hypr, omarchy, the
    terminals, nvim, helix, zed, btop, tmux, systemd, autostart, fcitx5,
    mimeapps.list and similar.
  - It never tracks browser profiles, `gh` or other credentials, or
    `pulse/` (its auth cookie). Anything named like a secret is excluded
    too: `*cookie*`, `*token*`, `*secret*`, `*.key` and so on.
  - On this machine a snapshot takes 31 ms the first time and 8 ms after,
    for 696 KB.
- **Restoring** puts changed files back from the "before" snapshot.
  - Files the change added are moved into `<state_dir>/config-set-aside/`,
    never deleted.
  - A file edited again since the change is left alone and named.
- **Hyprland guard:** after a run that touched `hypr/`, Hyprland reloads.
  If `configerrors` shows anything new, only the `hypr/` files are put back
  (`guard_hyprland/3`).
- **Interrupted runs:** `started/2` writes a marker before a run and
  `finished/1` clears it. At the next start, the TUI turns a leftover
  marker into an undo record and says `/look undo` puts things back.
- **Undo:** `Undo.push_snapshot/3` records the before and after pair, and
  `/look undo` restores it, then reloads Hyprland and the terminals.
- **Tests:** `test/tiny_axe/desktop_snapshot_test.exs`.

## O3 as built (2026-10-12)

- **`Desktop.OsRun`** is the gate tool `os_run {command, why}`, offered to
  an agent's own task (not sub-agents'), and switched off with
  `config :tiny_axe, :os_run, false`.
  - It runs `sh -c` as the user, outside the sandbox (the user's choice),
    in the current folder. Stdin is empty, secret env vars are removed
    (the D-Bus address is kept), and it's stopped after 5 min or when the
    run is cancelled.
  - It asks every time, never for the session. The popup shows the
    command and the reason, and warns in bold yellow: "runs OUTSIDE the
    sandbox".
  - Only desktop reads run at once: `hyprctl getoption|binds|monitors…`,
    `wpctl`/`pactl` reads, `bluetoothctl show`, `nmcli … show`,
    `systemctl --user status|is-active…`, `powerprofilesctl get`,
    `xdg-settings get`, `gsettings get`, and Omarchy's
    current/list commands. They may be piped through
    grep/head/tail/jq/wc/sort/uniq/cut/tr, with no `;`, `&`, `$`,
    backticks or redirection.
  - Refused outright: sudo/su/doas/pkexec, `curl|sh`, `rm` of `~`,
    `~/.config` or `/`, tiny-axe's own settings and state, and stopping
    tiny-axe.
  - Each run takes a snapshot before, writes the interrupted-run marker,
    takes a snapshot after, runs the Hyprland guard, and records an undo
    when files changed. The result lists the changed files and the
    guard's outcome.
- **Handoff:** when Gemma returns no changes, Jev answers one yes/no
  question: does the user want something changed or done, not just ask
  how it's set? Yes hands the request to the agent (Haiku), whose system
  prompt now includes `OsRun.instructions/0`.
  - The first version had Gemma fill an `unsupported` field. It proved
    unreliable: it replied "Opening Obsidian now" and flagged the request
    unsupported.
  - The instructions cover Omarchy's bind form,
    `o.bind("SUPER + ALT + N", "Obsidian", { launch = "obsidian" })`, and
    checking `hyprctl binds` first.
  - Requests from the site don't hand over.
  - With `os_run` off, Gemma's reply stands.
- **Live checks:**
  - Gemma flagged all four out-of-list requests (keybinding, window
    rule, service, install) and none of the in-list ones.
  - Real Haiku, with every `os_run` answered no: it read the configs in
    the sandbox, checked `hyprctl binds`, noticed Brave isn't installed
    and stopped, and for Obsidian proposed exactly Omarchy's form.
- **Tests:** `test/tiny_axe/desktop_os_run_test.exs`. Full suite: 845
  tests, 0 failures.

## O4 as built (2026-10-12)

The user chose all four root actions: install packages, remove packages,
system update, and system services.

- **`priv/root/tiny-axe-root`** is a bash script that runs as root.
  - Its environment is pinned: `PATH=/usr/bin:/usr/sbin`, `LC_ALL=C`, no
    `eval`.
  - Its verbs:
    - `install <pkgs>`: names checked by regex and found in the official
      repos (`pacman -Si`), then a snapper snapshot, then `pacman -S
      --needed --noconfirm --`.
    - `remove <pkgs>`: only explicitly installed packages, never protected
      ones (base, linux*, omarchy*, hyprland*, sddm, limine*, sudo,
      systemd*, pacman, networkmanager, pipewire, …), then a snapshot,
      then `pacman -Rns --noconfirm --`.
    - `update`: a snapshot, then `pacman -Syu --noconfirm`.
    - `service <start|stop|restart|enable|disable> <unit>`: the unit must
      exist. Protected units (sddm, systemd-*, dbus, polkit, getty, user@,
      snapper, limine) are refused, and so is stopping or disabling the
      network.
    - `snapshot <desc>`.
  - `TINY_AXE_ROOT_DRY_RUN=1` prints what would run; sudo's env_reset
    never passes it through. All of the refusals were dry-run checked on
    this machine.
- **`Desktop.Root`** wraps the helper.
  - `status/0` passes only if the helper at `/usr/local/bin/tiny-axe-root`
    has the same content as the shipped one, is owned by root, isn't
    group- or world-writable, and `sudo -n -l` allows it.
  - `run/2` uses `sudo -n` (never a password prompt) with a 30 min limit,
    and checks the arguments here as well as in the helper.
  - `setup/0` writes the helper and a sudoers rule (`<user> ALL=(root)
    NOPASSWD: /usr/local/bin/tiny-axe-root`) to the state folder and
    returns the two `sudo install` commands. `mix tiny_axe.os_setup`
    prints them, and `--remove` prints how to take them out. tiny-axe
    never touches `/etc` itself.
- **Desktop items** (all `risk: :ask`): install_package (`:packages`,
  official-repo names, and several installs merge into one),
  remove_package (a lookup over `pacman -Qqe`), system_update, and
  system_service (`:service`, "restart bluetooth"). Before the helper is
  installed, applying one says how to set it up.
- **`os_run`** accepts `tiny-axe-root <verb> <args>`, with or without sudo
  or the full path, checks it, asks, and runs it through `Root.run`.
  Raw sudo is refused with that form as the suggestion. Haiku's
  instructions say to use it, official repos only, no AUR.
- **Gemma path fixes found in live runs:**
  - Long lookups show the names the request mentions first, so "uninstall
    obsidian" sees obsidian in the examples.
  - Requests mentioning bind, shortcut, workspace, autostart and the like
    never count as naming launch_app or open_url.
  - "restart the computer" never counts as naming restart.
- **Live dry run:**
  - Right on Gemma alone: install ripgrep and fd → one install; update the
    system; restart the bluetooth service; uninstall obsidian; open
    obsidian.
  - Handed over, correctly: bind super+alt+n, firefox always on
    workspace 2, enable the ollama service at login, install spotify (not
    in the official repos).
- **Tests:** `test/tiny_axe/desktop_root_test.exs`, with a stand-in sudo
  (`test/support/fake_sudo`) and the helper in dry-run mode.
- **To set up:** run `mix tiny_axe.os_setup`, then the two commands it
  prints.
