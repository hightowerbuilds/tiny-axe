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
  # Verifier must say "yes, addresses the request" with at least this probability.
  accept_threshold: 0.7,
  max_attempts: 3,
  # Keyless web search (TinyAxe.Web). Searches when the Decider says a request
  # needs the web with at least :web_threshold probability, then reads the top
  # :web_pages results in full (each cut to :web_page_chars characters).
  web_search: true,
  web_threshold: 0.6,
  web_pages: 3,
  web_page_chars: 2_500,
  # Project files (TinyAxe.Files). `@path` in a prompt always attaches that file;
  # otherwise the Decider decides whether a request is about project files
  # (:files_threshold) and picks up to 3 (each at least :file_pick_min likely).
  # Attached files share :file_chars characters. :project_dir defaults to the
  # current directory; `mix tiny_axe --dir PATH` sets it.
  file_access: true,
  files_threshold: 0.5,
  file_pick_min: 0.2,
  file_chars: 12_000,
  # Compact older turns into a summary once the conversation fills this much of
  # the context window, leaving room for web results, files and the answer.
  compact_at: 0.5,
  # Shell commands (TinyAxe.Commander) run only after approval, in a sandbox,
  # and are killed after this long.
  commands: true,
  command_timeout: 600_000

config :tiny_axe, :jev, model: "jev-latest"

import_config "#{config_env()}.exs"
