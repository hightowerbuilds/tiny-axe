import Config

# stdout belongs to the TUI, so logs go to a file in the state folder, next to
# the plan journals, whatever folder tiny-axe is started from.
log_dir = Path.join(System.get_env("XDG_STATE_HOME") || Path.expand("~/.local/state"), "tiny-axe")
File.mkdir_p!(log_dir)

config :logger, :default_handler,
  config: [file: String.to_charlist(Path.join(log_dir, "tiny_axe.log"))]
