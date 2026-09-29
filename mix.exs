defmodule TinyAxe.MixProject do
  use Mix.Project

  def project do
    [
      app: :tiny_axe,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      releases: releases()
    ]
  end

  # Scripted stand-ins for the model and decider live in test/support.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # `mix tiny_axe.install` builds this and puts a `tiny-axe` launcher on the PATH.
  defp releases do
    [tiny_axe: [include_executables_for: [:unix], applications: [tiny_axe: :permanent]]]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      # :crypto hashes files for undo; a release only includes what's listed.
      extra_applications: [:logger, :crypto],
      mod: {TinyAxe.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ex_ratatui, "~> 0.16"},
      {:req, "~> 0.5"},
      {:floki, "~> 0.38"},
      # Timings and call counts for `mix tiny_axe.eval` (already a dependency of Req).
      {:telemetry, "~> 1.0"}
      # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"}
    ]
  end
end
