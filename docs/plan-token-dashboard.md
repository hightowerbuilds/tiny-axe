# Plan: `/token`, a small dashboard of Haiku and Jev usage

Status (2026-10-12): T1 (the numbers) and T2 (the popup) built; T3 (a real check) next. Branch `token-dashboard` (worktree
`../tiny-axe-lobster`).

## What the user asked for

A `/token` command in the TUI that opens a small dashboard of token use with
Claude Haiku 5.5 and Jev.

The user's choices (2026-10-12): session, today and 7 days, kept on disk
across restarts; no dollar figures; the local Gemma calls too, as a third
section.

## What tiny-axe records today

| Source | What's there | Kept? |
|---|---|---|
| Jev (`Decider.Jev`) | each reply's `usage` (`input_tokens`, `output_tokens`), model, request id | on the decision's meta only; never added up |
| Haiku answers (`Model.ClaudeCLI`, `claude -p`) | the stream's final `result` event: `usage` (input, output, cache read, cache write) and `total_cost_usd`; `rate_limit_event` with the 5-hour and 7-day windows' utilization and reset time | usage goes to the caller's `on_usage` (context meter); windows to `TinyAxe.Escalation` (the status bar's "Claude 41% of 5h", the 90% stop) |
| Haiku agent and sub-agents (`Agent.ClaudeDriver`, `Agent.Dispatch`) | the same `result` event, in `acc.result` | only the call is counted (`[:tiny_axe, :model, :call]`, `remote: true`) |
| Gemma (`TinyAxe.Ollama`) | each reply's `prompt_eval_count` and `eval_count` (and durations) | the answer route's `on_usage` (context meter); the local decider and agent loop drop them |

So the numbers exist at every call; nothing collects them.

## The shape

- **One event per call.** Each place above emits `[:tiny_axe, :usage]` with
  measurements `%{input, output, cache_read, cache_write}` (tokens), and
  metadata `%{backend: :claude | :jev | :ollama, kind: :answer | :agent |
  :subagent | :decision | :compaction | :suggest, model, ok, ms}`. Never any
  prompt or answer text, and no dollar figures (`total_cost_usd` is left out).
- **`TinyAxe.Usage`**, a supervised process that listens for it:
  - appends one JSON line per call to `<state_dir>/usage.jsonl` (written
    before it's counted, so a crash loses at most the call in flight; lines
    older than 90 days are dropped at start);
  - keeps totals in memory for this session, today and the last 7 days,
    rebuilt from the file at start;
  - keeps Claude's latest usage windows (it already arrives as
    `[:tiny_axe, :model, :quota]`).
- **`/token`** opens a popup, like `/credit-card`'s; `esc` closes it. It
  updates live while open (a request finishing changes its numbers).
  Nothing in it goes to a model.

```
╭ token use ───────────────────────────────────────────────╮
│ Claude Haiku 5.5            session    today    7 days   │
│   calls                          4       11        63    │
│   input (cached)        38.2k (31k)    110k      612k    │
│   output                      4.1k    12.9k     71.0k    │
│   by: answers 1 · agent 2 · sub-agents 1                 │
│   5-hour window  ████████░░░░░░░░  41%  resets 18:40     │
│   7-day window   ███░░░░░░░░░░░░░  17%  resets Fri       │
│   tiny-axe stops using Claude at 90% of either.          │
│                                                          │
│ Jev                         session    today    7 days   │
│   decisions                     38      120       904    │
│   input                      21.4k    66.0k      498k    │
│   output                        912    2.8k      21.1k   │
│   errors                         0        1         3    │
│                                                          │
│ Gemma (gemma4:e4b-it-qat, local) session  today   7 days │
│   calls                         52      140      1.1k    │
│   input / output          96k / 8k   270k/24k   2.1M/180k │
│                                                          │
│ today by hour  Haiku ▁▁▃▇▂▁▁▅ Jev ▂▃▅▇▆▃▂▄ Gemma ▃▅▇▇▅▃▂▄ │
│ tab: session / today / 7 days · esc close                │
╰──────────────────────────────────────────────────────────╯
```

## Phases

1. **T1, the numbers.** Done 2026-10-12: `TinyAxe.Usage.emit/6` from
   `Decider` (Jev), `Ollama.chat`/`stream_chat` (every local call, errors
   too), `ClaudeCLI` (answers) and `ClaudeDriver` (`:agent`, or `:subagent`
   when Dispatch's request says so). The file is the record: `summary/0`
   reads only what's new since it last looked, so several tiny-axe at once
   all count; a file found shorter than what was read is read afresh.
   Tested with the fake Claude CLI, a stubbed Jev and a stubbed Ollama, and
   in the agent and sub-agent tests. Originally: The `[:tiny_axe, :usage]` event from Jev, Haiku
   answers, the agent and sub-agents, and every Ollama call (answers,
   decisions with the local decider, the local agent loop, compaction);
   `TinyAxe.Usage` with `usage.jsonl`, totals, pruning. Tests with the fake
   CLIs (`test/support/fake_cli/claude`) and a stubbed Jev.
2. **T2, `/token`.** Done 2026-10-12: `TUI.TokenDash`. All three columns
   at once (session, today, 7 days), so no `tab`; input counts Claude's cache
   writes, with cache reads on their own row; errors only when there were
   some; a backend with no calls says "none in the last 7 days", and with
   none at all one line says so. Refreshes every second while open (a stale
   refresh is ignored); `esc`/`q`/`enter` close it, other keys are ignored,
   and questions (a tool call, a purchase) still go on top and get the keys.
   Unwrapped and sized to fit, so the columns line up. Tested in
   `tui_token_test.exs`: each part, column alignment, the empty states, a
   live refresh, a question on top. Originally: The popup, live updates, `esc`; a render test of each
   part, and an empty state ("no Haiku or Jev calls yet").
3. **T3, check it for real.** One Haiku answer, one agent run and a few Jev
   decisions in the installed tiny-axe, compared with what the CLI and Jev
   report.

## Settled

- Session, today and 7 days, on disk (`usage.jsonl`, 90 days).
- No dollar figures.
- Gemma included, as a third section.
- Jev's replies carry tokens but no credits or price, as far as tiny-axe
  sees; if TypeSafe reports a balance somewhere, it could go in later.
