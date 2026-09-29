import Config

# Anything written to stdout corrupts the TUI, so log to a file.
config :logger, :default_handler, config: [file: ~c"log/tiny_axe.log"]
