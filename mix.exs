defmodule TinyAxe.MixProject do
  use Mix.Project

  def project do
    [
      app: :tiny_axe,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases()
    ]
  end

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
      {:floki, "~> 0.38"}
      # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"}
    ]
  end
end
