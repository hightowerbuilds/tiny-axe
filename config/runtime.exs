import Config

# Read at boot rather than compile time so exporting a new key takes effect immediately.
api_key =
  System.get_env("TYPESAFE_API_KEY") || System.get_env("JEV_API_KEY") ||
    System.get_env("JEV_API")

config :tiny_axe, :jev,
  model: "jev-latest",
  api_key: api_key

# Use Jev whenever a key is available; otherwise fall back to the local decider.
# `mix tiny_axe --decider local|jev` still overrides this.
if api_key && config_env() != :test do
  config :tiny_axe, decider: TinyAxe.Decider.Jev
end
