defmodule Mix.Tasks.TinyAxe.BrowserEval do
  @shortdoc "Evaluate browser policy on synthetic observations, without executing actions"
  @moduledoc """
  Replays labelled browser policy cases without calling a model by default.
  Live mode uses the configured decider and excludes injected outage cases.
  This is a classification benchmark, not an end-to-end browser success rate.

      mix tiny_axe.browser_eval
      mix tiny_axe.browser_eval --live --decider jev --max-decisions 40
      mix tiny_axe.browser_eval --live --decider local --repeat 3
      mix tiny_axe.browser_eval --output /tmp/browser-policy.json

  --max-decisions caps logical decider calls (1..1000, default 40). The Jev
  backend may retry a request under its existing retry policy. --repeat is
  1..20. Reports include synthetic decision inputs and answers. They never
  contain real session content. Models are not started or downloaded here.
  """

  use Mix.Task
  alias TinyAxe.Browser.PolicyEval

  @impl true
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          live: :boolean,
          decider: :string,
          repeat: :integer,
          max_decisions: :integer,
          output: :string
        ]
      )

    if rest != [] or invalid != [], do: Mix.raise("invalid browser_eval arguments")
    repeat = opts[:repeat] || 1
    budget = opts[:max_decisions] || 40

    unless repeat in 1..20 and budget in 1..1000,
      do: Mix.raise("repeat must be 1..20 and max-decisions must be 1..1000")

    backend =
      case opts[:decider] do
        nil -> nil
        "jev" -> TinyAxe.Decider.Jev
        "local" -> TinyAxe.Decider.Local
        _ -> Mix.raise("decider must be jev or local")
      end

    # Runtime config loads the key without printing it. No TUI, user MCP
    # servers, browser, vault or application journal is started by this task.
    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:req)
    previous = Application.get_env(:tiny_axe, :decider)
    if backend, do: Application.put_env(:tiny_axe, :decider, backend)

    try do
      mode = if opts[:live], do: :live, else: :replay

      report =
        PolicyEval.run(PolicyEval.cases(), mode: mode, repeat: repeat, max_decisions: budget)

      configured_model =
        if TinyAxe.Decider.impl() == TinyAxe.Decider.Jev,
          do: Application.get_env(:tiny_axe, :jev, [])[:model],
          else:
            Application.get_env(:tiny_axe, :decider_model) ||
              Application.get_env(:tiny_axe, :model)

      report =
        Map.merge(report, %{
          at: DateTime.utc_now() |> DateTime.to_iso8601(),
          decider: if(mode == :replay, do: "scripted", else: inspect(TinyAxe.Decider.impl())),
          configured_model: if(mode == :live, do: configured_model),
          source_sha256: digest("lib/tiny_axe/tools/browser_policy.ex"),
          cases_sha256: digest("eval/browser_policy_cases.exs")
        })

      path =
        opts[:output] || "eval/results/browser-policy-#{System.system_time(:microsecond)}.json"

      File.mkdir_p!(Path.dirname(path))
      File.write!(path, JSON.encode!(json_safe(report)))

      Mix.shell().info(
        "#{report.note}\n#{report.passed}/#{report.scored} passed; " <>
          "#{report.insufficient_protection} insufficient-protection classifications; " <>
          "#{report.skipped} skipped; #{report.decisions} decisions\n#{path}"
      )

      for result <- report.results,
          not result.passed,
          do:
            Mix.shell().info(
              "#{result.id}: expected #{result.expected}, got #{result.actual}" <>
                if(result.skipped, do: " (budget exhausted)", else: "")
            )
    after
      if previous,
        do: Application.put_env(:tiny_axe, :decider, previous),
        else: Application.delete_env(:tiny_axe, :decider)
    end
  end

  defp digest(path), do: :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)
  defp json_safe(value) when is_tuple(value), do: value |> Tuple.to_list() |> json_safe()
  defp json_safe(value) when is_map(value), do: Map.new(value, fn {k, v} -> {k, json_safe(v)} end)
  defp json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)
  defp json_safe(value), do: value
end
