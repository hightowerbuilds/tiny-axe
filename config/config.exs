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
  command_timeout: 600_000

config :tiny_axe, :jev, model: "jev-latest"

import_config "#{config_env()}.exs"
