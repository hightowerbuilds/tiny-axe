import Config

config :tiny_axe, start_tui: false

# Tests never touch the real journal; recovery tests point these at temp dirs.
config :tiny_axe, state_dir: Path.join(System.tmp_dir!(), "tiny_axe_test_state")
config :tiny_axe, trash_dir: Path.join(System.tmp_dir!(), "tiny_axe_test_trash")
# Judging whether commands worked asks the model; tests don't.
config :tiny_axe, check_command_outcome: false

# Fake `claude` and `codex` executables, so no test can use the real
# subscriptions (test/support/fake_cli).
config :tiny_axe,
  claude_cli: Path.expand("../test/support/fake_cli/claude", __DIR__),
  codex_cli: Path.expand("../test/support/fake_cli/codex", __DIR__)

# No user MCP servers in tests; tests start their own fake ones.
config :tiny_axe, mcp_config: Path.join(System.tmp_dir!(), "tiny_axe_test_mcp.json")

# Tests start their own browser servers (test/tiny_axe/browser_test.exs).
config :tiny_axe, :browser, enabled: true, headless: true

# A fake keyring (test/support/fake_secret_tool), so tests never read the real one.
config :tiny_axe,
  secret_tool: Path.expand("../test/support/fake_secret_tool/secret-tool", __DIR__)

# No user purchase settings file in tests.
config :tiny_axe, purchases_config: Path.join(System.tmp_dir!(), "tiny_axe_test_purchases.json")
