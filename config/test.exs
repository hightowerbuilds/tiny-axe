import Config

config :tiny_axe, start_tui: false

# Tests never touch the real journal; recovery tests point these at temp dirs.
config :tiny_axe, state_dir: Path.join(System.tmp_dir!(), "tiny_axe_test_state")
config :tiny_axe, trash_dir: Path.join(System.tmp_dir!(), "tiny_axe_test_trash")
