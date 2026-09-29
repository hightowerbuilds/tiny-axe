import Config

# Settings for an installed copy live in ~/.config/tiny-axe/env (KEY=VALUE
# lines, e.g. TYPESAFE_API_KEY=...). Variables already set in the environment
# win, so a repo's .env (loaded by mise) still works in development.
env_file =
  Path.join(System.get_env("XDG_CONFIG_HOME") || Path.expand("~/.config"), "tiny-axe/env")

if config_env() != :test and File.regular?(env_file) do
  for line <- env_file |> File.read!() |> String.split("\n"),
      line = String.trim(line),
      line != "" and not String.starts_with?(line, "#"),
      [key, value] <- [String.split(line, "=", parts: 2)],
      System.get_env(String.trim(key)) in [nil, ""] do
    System.put_env(
      String.trim(key),
      value |> String.trim() |> String.trim("\"") |> String.trim("'")
    )
  end
end

# Read at boot rather than compile time so exporting a new key takes effect immediately.
api_key =
  System.get_env("TYPESAFE_API_KEY") || System.get_env("JEV_API_KEY") ||
    System.get_env("JEV_API")

config :tiny_axe, :jev,
  model: "jev-latest",
  api_key: api_key

# Use Jev whenever a key is available; otherwise fall back to the local decider.
# `--decider local|jev` still overrides this.
if api_key && config_env() != :test do
  config :tiny_axe, decider: TinyAxe.Decider.Jev
end

# An installed copy (a release) is started by the `tiny-axe` launcher, which
# passes the folder it was run in and any --dir/--model/--decider options.
if System.get_env("RELEASE_NAME") do
  config :tiny_axe,
    start_tui: true,
    project_dir: System.get_env("TINY_AXE_DIR") || File.cwd!()

  if model = System.get_env("TINY_AXE_MODEL"), do: config(:tiny_axe, model: model)

  case System.get_env("TINY_AXE_DECIDER") do
    "jev" -> config :tiny_axe, decider: TinyAxe.Decider.Jev
    "local" -> config :tiny_axe, decider: TinyAxe.Decider.Local
    _ -> :ok
  end
end

# In a release, logger config here takes effect (under mix, dev.exs/prod.exs set it).
if config_env() == :prod do
  log_dir =
    Path.join(System.get_env("XDG_STATE_HOME") || Path.expand("~/.local/state"), "tiny-axe")

  File.mkdir_p!(log_dir)

  config :logger, :default_handler,
    config: [file: String.to_charlist(Path.join(log_dir, "tiny_axe.log"))]
end
