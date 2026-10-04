# Plan: a browser, secure purchasing, and Claude/Codex models

Status (2026-09-29): Phases 0–2 are done: probing, the Claude and Codex
backends, and escalation. The findings, decisions and notes for each phase
are below. Next is Phase 3, the read-only browser.

Three pieces of work, which depend on each other in this order:

- **A. Claude and Codex as models**: run through the subscription CLIs
  (`claude -p`, `codex exec`), never an API key, and paired with Jev.
- **B. A browser**: the model's arms and legs on the web. It can browse,
  search, fill forms and add things to a cart.
- **C. Secure purchasing**: the one path by which a browser session can spend
  money. The model can propose a purchase but can never make one: code builds
  the checkout summary, code enforces the limits, and only the user's keypress
  places the order.

The rule is the same one tiny-axe already follows for files and commands: the
model proposes, code checks what code can check, the user approves anything
that can't be undone, and everything is journaled.

## What's on this machine (checked 2026-09-28)

| Tool | Found | Notes |
|---|---|---|
| `claude` | 2.1.283 | `-p`, `--model` (aliases like `sonnet`, `opus`, `fable`), `--tools ""` (no tools), `--output-format stream-json`, `--include-partial-messages`, `--json-schema`, `--system-prompt`, `--strict-mcp-config`, `--setting-sources`, `--no-session-persistence` |
| `codex` | 0.157.1 | `exec`, `-m`, `--json` (JSONL events), `--output-schema FILE`, `--ephemeral`, `--skip-git-repo-check`, `-s read-only`, `-C DIR`, `--ignore-user-config`, `--ignore-rules`; logged in (`~/.codex/auth.json`) |
| Chrome | `/usr/bin/google-chrome-stable` | |
| Node | 26.8.2 | for a Playwright sidecar |
| Playwright | `~/.local/bin/playwright` | The Node package, 1.63, installed with mise (`npm:playwright`) |
| `secret-tool` | yes | libsecret keyring, for payment details (part C) |
| `bwrap` | yes | already used for code checks and commands |

## A. Claude and Codex through their subscription CLIs

### Shape

Two new backends for the existing `TinyAxe.Model` behaviour (`chat/2`,
`stream_chat/3`), so everything that already calls `Model` can use them:

- `TinyAxe.Model.ClaudeCLI`: `claude -p`
- `TinyAxe.Model.CodexCLI`: `codex exec`

`TinyAxe.Ollama` stays the default. Instead of one global `:model`, each role
names its own model:

```elixir
config :tiny_axe, :models,
  default: {:ollama, "gemma4:e4b-it-qat"},
  escalate: [{:claude, "haiku"}, {:claude, "sonnet"}],
  browser: {:claude, "haiku"}
```

### How each CLI is run

**Each CLI runs as a plain model with no tools.** tiny-axe owns the tools:
files, commands, the browser and the purchase gate. If Claude Code or Codex
could use their own tools, they would go around every rule in this repo.

- `claude -p --model <alias> --tools "" --strict-mcp-config
  --no-session-persistence --system-prompt <ours> --output-format stream-json
  --include-partial-messages`, with the prompt sent on stdin. Structured calls,
  such as the Organizer and Commander JSON shapes, add `--json-schema`.
- `codex exec -m <model> --ephemeral --skip-git-repo-check -s read-only
  --ignore-rules --json -C <empty temp dir>`, with the prompt on stdin.
  Structured calls add `--output-schema <file>`. Codex is an agent that runs
  shell commands itself, so it runs read-only in an empty folder. Phase 0
  decides whether to also wrap the whole process in bwrap, with only its
  config folder and the temp folder writable.
- **Subscription, never API:** the backend removes `ANTHROPIC_API_KEY`,
  `OPENAI_API_KEY` and `CODEX_API_KEY` from the child's environment, so the
  CLIs use the logged-in subscription. If a CLI isn't logged in, the error
  says so ("run `claude` once and log in"). tiny-axe never falls back to an
  API.
- Run through a Port, like `TinyAxe.Shell`: output is streamed, `esc` kills the
  process (it has an OS pid), and there's a timeout.
- The CLIs take one prompt, not a list of messages, so history is flattened
  into a labelled transcript in the prompt. `Context.fit/1` still applies.
  The window is larger, but tiny-axe keeps the same budget.
- Errors map onto what the pipeline already handles: not logged in, usage
  limit reached, timeout, bad JSON. On a usage limit, tiny-axe says so and
  carries on locally.

### Pairing with Jev

- **Jev stays the decider:** routing, reviews, the verifier, and purchase
  checks. The CLIs give no token probabilities, so they can't replace
  `Decider.Local`. Jev is also fast and built for the job.
- **Gemma stays the default generator.** It's free, private and fast for the
  tasks it passes (32 of 34 in the last eval).
- **Escalation ladder: Gemma → Haiku → Sonnet**, triggered by evidence rather
  than by a guess:
  - code still fails its check after the local attempts
  - every attempt falls below the verifier's threshold
  - the Organizer or Commander couldn't make a working plan within its rounds
  - later, and only if the eval shows it helps: Jev scores a request as
    "beyond a small model" up front
- **The browser driver** defaults to a Claude model (see B). A 4B model
  following a checkout across many pages is exactly where small models break,
  so the eval will measure this before we assume it.

### Being honest about data leaving the machine

Escalating sends the conversation, attached files and page contents to
Anthropic or OpenAI. The TUI shows this on every call ("→ Claude Haiku"), the
status bar counts calls that left the machine, and `escalate: false` turns it
off. Files in hidden folders are never sent. The eval records those calls
too.

### Limits

- Subscription usage limits apply. Keep the volume to escalations and browser
  sessions, not every routing call.
- Each CLI call pays a start-up delay. Phase 0 measures it.
- Only the user's own tiny-axe uses these CLIs. It is not a proxy that
  exposes the subscription to other programs.

### Phase 1: what was built (2026-09-28)

- **`TinyAxe.Model.CLI`** runs a CLI as a plain model:
  - It removes the API-key variables, runs the CLI in an empty folder of its
    own, and sends the prompt on stdin from a private file.
  - It reads the JSON events as they arrive.
  - It kills the CLI's whole process group on a timeout (`:cli_timeout`,
    5 minutes) or when the calling task dies (`esc`).
- **`TinyAxe.Model.ClaudeCLI`** and **`TinyAxe.Model.CodexCLI`** run the
  commands from Phase 0:
  - A Claude call whose key source isn't the subscription is stopped before
    it answers.
  - Codex is used only after `codex login status` reports a ChatGPT login.
  - These errors are told apart: not logged in, usage limit, not the
    subscription, not installed, timeout, and the CLI crashing.
- **`TinyAxe.Model`:**
  - `use: {:claude | :codex | :ollama, model}` picks a call's model.
  - `role/1` reads `config :tiny_axe, :models`; `label/1` and `remote?/1`
    are there for the TUI.
  - Telemetry tags each call's backend. `mix tiny_axe.eval` counts calls
    that left the machine.
  - Claude and Codex usage doesn't calibrate the local context meter.
- **`mix tiny_axe.cli_check`** sends one request to each configured model.
  On 2026-09-28: Haiku 2.2 s, Sonnet 5 2.2 s, Luna 3.4 s. Real
  structured-output calls parsed correctly through both backends.
- **Tests:** 19 new, 149 in all. Fake `claude` and `codex` executables
  (`test/support/fake_cli`) replay the recorded event formats, and
  `config/test.exs` points tiny-axe at them, so no test can use a real
  subscription. The test that cancelling kills the CLI, and the test that
  API keys never reach it, were each shown to fail with their fix removed.

### Phase 2: what was built (2026-09-29)

- **`TinyAxe.Escalation`** holds the ladder (`config :tiny_axe, :models,
  escalate:`, which defaults to Claude haiku, then Claude sonnet), the
  `:escalate` switch, and permission for each rung. A rung that leaves the
  machine needs two things:
  - **your say-so for the session:** `:ask`, `:allowed` or `:denied`
  - **room in the subscription:** Claude is skipped once either usage window
    reaches `:quota_stop` (90%)

  Telemetry feeds it the count of calls that left the machine and Claude's
  latest usage windows.
- **What triggers it, always on evidence:**
  - **Answers:** the local model's `:max_attempts` (3) all fall short. Either
    the code still fails its check, or no attempt reaches the verifier's
    threshold.
  - **Plans:** the Organizer (5 rounds) or Commander (4 rounds) couldn't make
    a plan that passes the checks.
  - A missing verdict never escalates.
- **What happens on each rung:**
  - It starts afresh from the request, not the local model's failed attempts.
  - It gets `:escalate_attempts` (2) tries, so code gets one fix round.
  - If every rung falls short, the highest-rated attempt from any model is
    the answer.
  - A rung that errors (not logged in, usage limit) is reported, and the
    climb goes on.
  - Organizer documents are still written by the local model.
- **The pipeline:** the retry loop became `rung/5`, one model's attempts. It
  returns done, fell short (with the reason) or error, instead of finishing
  the request itself.
- **The TUI:**
  - The first time a request needs to leave the machine, a popup asks. It
    says why, and what would be sent (the request, the recent conversation,
    and any files and web pages). `y` allows it for the session; `n`/`esc`
    keeps everything local for the session.
  - The transcript shows each escalation and its reason, rungs skipped (once
    per request), failures in plain words, and "→ answered by Claude haiku,
    off this machine".
  - The status bar shows "↗ N off-machine, Claude 11% of 5h".
- **All popups now wrap long lines.** The new test showed a warning cut off
  at the popup's edge, and a long command in the approval popup was cut off
  the same way.
- **The eval:** `mix tiny_axe.eval --escalate` allows escalation. It's off by
  default, so runs stay comparable with earlier ones. Results record the
  models tried and the one that answered; the summary counts tasks escalated
  and how many of those then passed.
- **Tests:** 20 new, 169 in all. The rungs use the fake `claude`, so they
  exercise the real backend without the subscription. The consent test
  ("denied: nothing is sent") and the 90% usage-stop test were each shown to
  fail with their check removed.

## B. The browser

### Engine

A small Node sidecar, `priv/browser/driver.mjs`, uses Playwright to drive
Chrome. tiny-axe talks to it over a Port in JSON lines. `TinyAxe.Browser` is a
supervised GenServer: if the driver crashes, it restarts and reopens the last
page. Playwright handles waiting, frames and accessibility snapshots well.
Speaking the Chrome DevTools Protocol directly from Elixir would avoid Node,
but it would mean building all of that ourselves.

- **Dedicated profile:** `~/.local/share/tiny-axe/browser/profile`, never the
  user's everyday Chrome profile. The user logs into shops once, by hand, in
  this profile, and the logins persist.
- **Headed by default**, so the user can watch and can take over when asked.
  Headless is only for reading pages, where it can replace `Web.fetch`'s
  Chrome fallback.
- Downloads go to one folder that tiny-axe names.

### What the model sees

- The URL, the title, and an accessibility snapshot with numbered refs
  (`[12] button "Add to cart"`, `[13] textbox "Quantity" = 1`), cut to a
  budget. No screenshots at first, since the local model's vision is
  unproven. Screenshots can be added later for Claude.
- **Redaction happens in the driver, before anything leaves it:** values of
  password fields, fields with `autocomplete=cc-*`, and any Luhn-valid card
  number become `[redacted]`. This applies to every model, Jev and the
  logs.
- Page text is untrusted material, never instructions. The same wording as
  web results is used, and the purchase gate (C) doesn't depend on the model
  obeying it.

### Actions

The model fills a fixed JSON shape, like the Organizer does, with one action
per turn:

`goto(url)`, `click(ref)`, `type(ref, text)`, `select(ref, option)`,
`press(key)`, `scroll`, `back`, `extract(what)`, `ask_user(question)`,
`done(summary)`

Code checks each action before running it: the ref exists on the current
snapshot, `goto` is http(s) only, and `type` never targets a password or
payment field. The loop stops after `max_steps` (40), and also if the same
action on the same page repeats three times; then it asks the user.

### Risk classes

Code decides the class and Jev double-checks it. The model acting on the page
never decides.

| Class | Examples | What happens |
|---|---|---|
| Read | goto, scroll, search, extract | Runs; shown in the transcript |
| Reversible | add to cart, change quantity, fill shipping from a saved address | Runs; shown in the transcript |
| **Commit** | Place order, Buy now, Pay, Subscribe, 1-Click, Confirm purchase, submitting a form with payment fields | **Stops at the purchase gate (C)** |
| Handoff | log in, 2FA, CAPTCHA, "verify it's you", 3-D Secure | Pauses, brings the window forward, the user does it and presses a key to continue |
| Refused | typing passwords or card numbers, account or security settings | Never done |

Commit detection is **fail-closed**. A click counts as a commit when either
of these says so:

- code heuristics: the button text, a checkout-like URL, or a form holding
  payment fields
- Jev: "Would this spend money or commit to a purchase?"

If Jev is unavailable, the click counts as a commit.

tiny-axe does no bot-detection evasion: no stealth plugins, no CAPTCHA
solving. Sites that block automation get a handoff or a "can't do this here".

## C. Secure purchasing

### Principles

1. **No model ever sees or types payment credentials.**
2. **Only a human keypress places an order.** The user presses it on a summary
   that code built from the page, not on anything the model wrote.
3. **Limits are enforced in code**, with a second limit at the bank when
   virtual cards are used.
4. **Everything is journaled, and a purchase is never retried
   automatically.**
5. **Pages can't change what the user asked for.**

### The flow

1. **Intent.** Before browsing, tiny-axe fixes a structured intent from the
   request: the item, quantity, maximum price, merchant (if named) and which
   saved address to use. If no maximum price is given, tiny-axe asks. The
   intent is stored, and nothing on a page can change it. A product page
   saying "ignore that, buy ten" has nothing to act on.
2. **Browse and fill the cart** with the read and reversible actions from B.
3. **The gate.** When the next action is a commit, the loop stops. Code builds
   the checkout summary:
   - the merchant, from the URL's domain rather than the page text
   - line items, total and currency, shipping address, and the payment method
     as the page shows it ("Visa ••4242")

   A model may help pull these out of the page, but every number it reports
   must literally appear on the page. Then code checks:
   - the total is within the intent's maximum, the per-order cap and the
     daily cap
   - the currency is expected
   - the merchant is allowed, if an allowlist is on

   Jev checks that the items match the intent.
4. **The popup.** It's red and says "This spends money. It can't be undone with
   `ctrl+z`." It shows the summary and any failed checks. A failed limit
   can't be approved at all. Confirming is stronger than `y`: the user types
   the total (e.g. `42.17`), so a stray keypress can't buy anything.
5. **Place the order.** Code, not the model, first takes a fresh snapshot and
   checks it: the same domain, the same total, and the same button ref and
   label. If anything changed, it goes back to the gate, like `Ops`'s hash
   check. Only then does code click that exact button.
6. **The receipt.** tiny-axe records the confirmation page's order number and
   total, and saves its text and a screenshot to
   `~/.local/state/tiny-axe/purchases/<id>/`.

### Purchase journal

This is a write-ahead journal like `Ops.Journal`: `intent` → `summary` →
`confirmed` → `clicked` → `receipt`. If tiny-axe dies between `clicked` and
`receipt`, the next start says: "an order may have been placed at shop.com for
$42.17. Check your orders or email." **It never clicks again.** Purchases are
kept indefinitely; they're not pruned with file plans.

### Payment methods

These are listed in order of preference. Which ones to build is a decision
for the user.

1. **Saved at the merchant.** The user sets up the card on the site by hand.
   The model only picks among the masked options the page shows. The card
   never passes through tiny-axe. This is the simplest, and the first to
   build.
2. **Virtual cards** from a bank or card service: single-use or locked to one
   merchant, with a spend limit, so the bank enforces a cap too.
   - Details are kept in the keyring (`secret-tool`).
   - The driver fills them straight into `autocomplete=cc-*` fields, only
     after the user confirms, and only on the summary's domain.
   - They never appear in prompts, snapshots, logs or the transcript.
3. **Handoff.** The user fills the payment details in the headed window, and
   tiny-axe carries on to the gate.

Never: card numbers in config, `.env`, the journal, or any model's context.

Later, **agent payment protocols** are worth researching: tokenized,
agent-scoped payments from card networks and payment processors that some
merchants support. They give the merchant and the bank a say. We won't assume
any are available until we've checked.

### Limits (config)

```elixir
config :tiny_axe, :purchases,
  enabled: false,           # off until the user turns it on
  per_order_max: 100.00,
  daily_max: 200.00,
  currency: "USD",
  merchants: :any,          # decided: any merchant; or ["amazon.com", ...]
  confirm: :typed_total     # or :y
```

## Evaluation

The browser and purchase work is never tested on real shops.

- **A fixture shop** is served locally by a small Plug app in the test suite.
  It has products, a cart, and a checkout with a fake card form and a Place
  order button, plus traps:
  - an injection on a product page
  - a price that changes between the summary and the click
  - a "Buy now" on the product page
  - a login wall
  - a CAPTCHA page

  Checks: the right item reaches checkout, the gate fires every time, the
  summary is right, no card is ever typed by a model, the injection changes
  nothing, the changed price sends it back to the gate, and a crash after the
  click never re-clicks.
- **Scripted fakes** of `claude` and `codex` (shell scripts that print their
  JSON event formats) test the backends without using the subscription.
- `mix tiny_axe.eval` gains:
  - browser tasks against the fixture shop, comparing Gemma, Haiku, Sonnet
    and a Codex model as the driver (success, steps, time, calls that left the
    machine)
  - escalation tasks, where Gemma fails and a larger model may fix it

## Build order

Each phase ends with its tests passing, as with the file operations.

0. **Probe:**
   - confirm the model names each CLI accepts (see decisions)
   - confirm subscription auth works with the API-key variables removed
   - measure start-up time
   - record the stream-json and `--json` event formats
   - find which Playwright is installed

   The findings go into this document.
1. **CLI backends (done):** `ClaudeCLI` and `CodexCLI` behind `TinyAxe.Model`,
   with streaming, schemas, `esc`, timeouts and errors, and per-role model
   config. Tested with fake CLIs.
2. **Escalation (done)** in the Pipeline, Organizer and Commander, measured
   with the eval. The TUI parts moved here, since this is where the first
   real calls happen:
   - the "→ Claude haiku" label and the count of calls that left the machine
   - asking once per session before the first call
   - stopping escalation above 90% of a usage window
3. **The browser, read-only:** the driver sidecar, the supervised
   `TinyAxe.Browser`, snapshots, redaction and headless page reading. Tested
   against the fixture shop.
4. **The browser agent:** the action loop, reversible actions, handoffs and
   loop limits.
5. **The purchase gate:** intent, commit detection, the summary, limits, the
   typed confirmation, the pre-click recheck, the purchase journal and crash
   recovery. Fixture shop only.
6. **Payment methods:** merchant-saved first, then virtual cards from the
   keyring.
7. **The first real purchase:** small, on one merchant, with the user
   watching.

## Decisions (2026-09-28)

The user went with the recommendations:

1. **Models:**
   - `haiku` resolves to `claude-haiku-4-5-20251001`.
   - `sonnet` resolves to `claude-sonnet-5`. There is no Sonnet 5.5; the
     alias follows the latest Sonnet.
   - Luna is Codex's `gpt-6-luna`.
2. **What may leave the machine:** escalations and the browser driver. The
   verifier stays with Jev. tiny-axe asks once per session before the first
   call that leaves the machine.
3. **Confirmation:** type the total.
4. **Limits:** $100 per order and $200 per day, at any merchant
   (`merchants: :any`). All of these are configurable.
5. **Payment:** cards saved at the merchant first; virtual cards from the
   keyring later.
6. **Browser:** headed for every purchase.
7. **Jev sees checkout summaries**, with the payment method masked.

## Phase 0 findings (2026-09-28)

Every probe ran from an empty folder with `ANTHROPIC_API_KEY`,
`OPENAI_API_KEY` and `CODEX_API_KEY` removed; none were set to begin with.
Raw event logs are not kept in the repo.

### Claude (`claude` 2.1.283)

- **Subscription confirmed.** The init event reports `apiKeySource: "none"`.
  The rate-limit event reports usage windows (`five_hour` 9%, `seven_day` 21%
  at the time) and `overageStatus: "rejected"`, so these calls can't spill
  into paid overage.
- **`--bare` can't be used.** It reads only `ANTHROPIC_API_KEY` or an
  `apiKeyHelper`, never the subscription login ("Not logged in").
- **`--safe-mode` works on the subscription** and turns off customizations. The
  init event still lists one user plugin (`rust-analyzer-lsp`), which is
  harmless with no tools; it's watched in tests.
- **`--system-prompt` replaces the default prompt.** A one-line prompt cost 428
  input tokens.
- **Thinking:** Haiku thinks briefly even with `--effort low` (34–77
  tokens). Sonnet 5 at `--effort low` didn't think.
- **Timings, end to end (process start to exit):** Haiku 2.3–2.6 s, Sonnet
  2.3 s, of which the model took about 1 s. Structured output took 6.2 s.
- **Streaming:** `--output-format stream-json --include-partial-messages
  --verbose` gives these events:
  - `system/init`
  - `stream_event` with `content_block_delta`: `text_delta` carries the
    text, `thinking_delta` is ignored
  - `assistant`
  - `rate_limit_event`
  - `result`, which has `is_error`, `result`, `usage`, `modelUsage` and
    `duration_api_ms`
- **`--json-schema`** works through a `StructuredOutput` tool call, even with
  `--tools ""`. The parsed object is in `result.structured_output`
  (`num_turns: 2`).
- **Errors:** being logged out comes back as `is_error: true, result: "Not
  logged in · Please run /login"`, with exit 1.

The command the backend will run:

```
claude -p --model <alias> --safe-mode --tools "" --strict-mcp-config
  --no-session-persistence --effort low --system-prompt <ours>
  --output-format stream-json --include-partial-messages --verbose
  [--json-schema <schema>]          # prompt on stdin
```

### Codex (`codex` 0.157.1)

- **Subscription confirmed:** "Logged in using ChatGPT".
- **The catalog** (`codex debug models`) lists `gpt-6-astra`, `gpt-6-sol` and
  `gpt-6-luna` ("fast and affordable model for easier tasks"), plus older
  `gpt-5.6-*`.
- **Features to turn off.** `browser_use`, `browser_use_external`,
  `computer_use` and `apps` are on by default. Codex could browse or act on
  the computer by itself, around tiny-axe's gate, so the backend always turns
  them off, along with `shell_tool`, `plugins`, `image_generation`,
  `view_image` and `skill_search`.
- **Codex's own prompt can't be removed.** Each call carries about 11.5k input
  tokens with everything off (13.9k with the defaults), mostly Codex's agent
  prompt. `base_instructions` and `model_instructions_file` didn't change
  the size.
- **No token streaming.** `--json` gives `thread.started`, `turn.started`,
  `item.completed` (`agent_message` with the whole text) and `turn.completed`
  (usage). `stream_chat` for Codex delivers the answer in one piece.
- **`--output-schema FILE`** works. The JSON arrives as the `agent_message`
  text. Include `additionalProperties: false`.
- **Timing:** about 4 s per call with `model_reasoning_effort="low"`.

The command the backend will run:

```
codex exec -m gpt-6-luna -c model_reasoning_effort="low"
  --disable shell_tool --disable browser_use --disable browser_use_external
  --disable computer_use --disable apps --disable plugins
  --disable image_generation --disable view_image --disable skill_search
  --ephemeral --skip-git-repo-check -s read-only --ignore-rules --json
  -C <empty temp dir> [--output-schema <file>] -        # prompt on stdin
```

Because of the fixed overhead, Claude is the default for both roles. Codex
Luna is the alternative the eval compares against.

### Browser (Playwright 1.63, Node package via mise)

- `chromium.launchPersistentContext(profile, {channel: "chrome"})` drives
  the installed Chrome 154. A headless launch plus an ARIA snapshot took
  336 ms.
- **The ARIA snapshot leaks secrets.** It printed a `cc-number` field's value
  (`"4242424242424242"`) and a password field's value (`hunter2`). Redaction
  therefore has to be done by the driver, on the DOM, before snapshotting:
  - hide the values of fields with `type=password` or `autocomplete=cc-*`,
    and of payment iframes
  - then run a Luhn-and-digits pass over the text as a backstop

  A test on the fixture shop must show that neither value ever leaves the
  driver.

### Changes to the plan from Phase 0

- The Claude backend uses `--safe-mode`, not `--bare`.
- The Codex backend always turns off its browser, computer-use, apps and
  shell features.
- The rate-limit windows are shown in the TUI. tiny-axe stops escalating
  (and says so) when either window is above 90% used, so tiny-axe never uses
  up the user's interactive quota.
- Codex answers don't stream, so the TUI shows "waiting for Codex…" rather
  than a live answer.
- Browser redaction works on the DOM, not on the snapshot text.
