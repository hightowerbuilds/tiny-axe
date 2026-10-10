import Config

config :tiny_axe,
  ollama_url: "http://localhost:11434",
  # Generation model.
  model: "gemma4:e4b-it-qat",
  # Model used by TinyAxe.Decider.Local; nil means reuse :model.
  decider_model: nil,
  # Switched to TinyAxe.Decider.Jev in runtime.exs when a TypeSafe key is set.
  decider: TinyAxe.Decider.Local,
  # Some models (e.g. Qwen3.5) think by default; off keeps small models snappy.
  think: false,
  keep_alive: "30m",
  # Context window for every Ollama call (Ollama's own default is 4096).
  num_ctx: 8192,
  # Compile and doctest Elixir/Python answers in a bubblewrap sandbox.
  code_check: true,
  # Decision thresholds (all Decider scores; an unknown score never passes one).
  # Routing: a request goes to the command or file planner, or to a folder it
  # names, when the Decider says so with at least this probability.
  route_threshold: 0.5,
  # Verifier must say "yes, addresses the request" with at least this probability.
  accept_threshold: 0.7,
  # An answer claiming to have run something counts as a false claim from here.
  false_claim_threshold: 0.5,
  # Reviews of plans, commands, documents and summaries below this are doubtful:
  # shown in yellow and sent back once.
  review_threshold: 0.5,
  max_attempts: 3,
  # Keyless web search (TinyAxe.Web). Searches when the Decider says a request
  # needs the web with at least :web_threshold probability, then reads the top
  # :web_pages results in full (each cut to :web_page_chars characters).
  web_search: true,
  web_threshold: 0.6,
  # Search results the Decider rates below this as on-topic try the next engine.
  relevance_threshold: 0.5,
  web_pages: 3,
  web_page_chars: 2_500,
  # Project files (TinyAxe.Files). `@path` in a prompt always attaches that file;
  # otherwise the Decider decides whether a request is about project files
  # (:files_threshold) and picks up to 3 (each at least :file_pick_min likely).
  # Edits are only offered when it says the user wants changes (:change_threshold).
  # Attached files share :file_chars characters. The project is the current
  # folder (TinyAxe.Location), which starts where tiny-axe is launched:
  # `--dir PATH`, the launcher's folder, or home for plain `mix tiny_axe`.
  file_access: true,
  files_threshold: 0.5,
  file_pick_min: 0.2,
  change_threshold: 0.5,
  file_chars: 12_000,
  # File plans (TinyAxe.Organizer: move, copy, trash, write) on or off.
  file_ops: true,
  # A folder the Decider picks for a request that names one needs at least this.
  navigate_min: 0.4,
  # Compact older turns into a summary once the conversation fills this much of
  # the context window, leaving room for web results, files and the answer.
  compact_at: 0.5,
  # Shell commands (TinyAxe.Commander) run only after approval, in a sandbox,
  # and are killed after this long.
  commands: true,
  command_timeout: 600_000,
  # Claude and Codex through their subscription CLIs (never an API key), killed
  # after this long. See TinyAxe.Model.ClaudeCLI and TinyAxe.Model.CodexCLI.
  cli_timeout: 300_000,
  # When the local model falls short on evidence (code still failing its check,
  # no answer the verifier accepts, a plan it couldn't make work), try the
  # :escalate models in order, each with this many attempts. Claude isn't used
  # once its subscription has used :quota_stop of either usage window.
  escalate: true,
  escalate_attempts: 2,
  quota_stop: 0.9,
  claude_cli: "claude",
  claude_effort: "low",
  codex_cli: "codex",
  codex_effort: "low"

# Agent tool calls, all through TinyAxe.Tools.Gate: per task at most this many
# calls and minutes; an outward call waits this long for the user's answer.
config :tiny_axe, :tools,
  max_calls: 60,
  max_minutes: 30,
  approval_timeout: 600_000

# tiny-axe's own browser (TinyAxe.Browser): Chrome via Playwright, in its own
# profile, reached by agents through the tool gate. Headless while it only
# reads; :profile and :playwright_root are found automatically if unset.
config :tiny_axe, :browser,
  enabled: true,
  headless: true

# Choosing among similar elements on a page (TinyAxe.Browser.Choices), advice
# only: it never runs or approves anything. :off; :shadow (the gate checks
# clicks on controls whose label others on the page share, and only records
# what it would advise; browser_choose isn't offered); or :on (browser_choose
# is offered, and with :browser_choose_hints the gate holds such a click once
# when its target clearly doesn't fit, saying which one does). Phase 4's
# measurements and why the default is what it is: docs/plan-browser-decisions-and-learning.md.
config :tiny_axe, browser_choose: :shadow, browser_choose_hints: true

# Validated memory (TinyAxe.Browser.Examples): reviewed, versioned lessons
# from earlier tasks, a few retrieved for a task's workflow and for what its
# browser calls came to, advice only (never consulted by policy, approvals
# or purchases). :off; :shadow (retrieved and journaled, never shown); or
# :on (shown to the driver in the system prompt and in call results, the
# same for every driver). Separate from :browser_choose. Phase 5's
# measurements and why the default is what it is:
# docs/plan-browser-decisions-and-learning.md. Lessons from real sessions
# are kept (as unvalidated candidates, with redacted evidence apart from
# the journals for :browser_examples_retention_days) only with
# :browser_examples_persist; a person promotes them with
# `mix tiny_axe.browser_examples`.
config :tiny_axe,
  browser_examples: :shadow,
  browser_examples_persist: false,
  browser_examples_retention_days: 30

# Purchases (TinyAxe.Purchases): off until the user turns them on. The agent
# can only buy at a checkout tiny-axe reads itself, within these limits, after
# the user types the exact total.
config :tiny_axe, :purchases,
  enabled: false,
  per_order_max: 100.0,
  daily_max: 200.0,
  currency: "USD",
  merchants: :any

# Models for each role besides the default (:model). Claude and Codex leave the
# machine: escalation is tried in order when the local model falls short, and
# the agent (requests that need tools: MCP servers, the browser) is driven by
# its own model: {:claude, _} or {:codex, _} run that CLI's agent loop with the
# tool gate as their only tools; {:ollama, _} runs tiny-axe's own loop.
# Claude Haiku 5.5 is the only Claude model: the agent and the one escalation
# rung (no Sonnet). It's pinned by its full name (Jev still makes the
# decisions), so an alias moving to a new model can't change results unseen.
config :tiny_axe, :models,
  escalate: [{:claude, "claude-haiku-5-5"}],
  agent: {:claude, "claude-haiku-5-5"}

# The agent: how long a run may take, how hard Claude/Codex think, and how many
# turns tiny-axe's own loop gives the local model.
config :tiny_axe,
  agent_timeout: 1_800_000,
  agent_effort: "medium",
  local_agent_steps: 12

config :tiny_axe, :jev, model: "jev-latest"

# The prompt cursor pulses, with a ring blasting outward from it (TinyAxe.TUI.Pulse).
config :tiny_axe, cursor_pulse: true

import_config "#{config_env()}.exs"
