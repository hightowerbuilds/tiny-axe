defmodule Mix.Tasks.TinyAxe.CliCheck do
  @shortdoc "Check that Claude and Codex work through their subscription CLIs"
  @moduledoc """
  Sends one short request to each model tiny-axe uses through the `claude`
  and `codex` CLIs (the `:escalate` and `:agent` roles), the way tiny-axe
  sends them: on the subscription, never an API key, with no tools. Reports
  the model that answered, how long it took, and Claude's usage windows.

      mix tiny_axe.cli_check
      mix tiny_axe.cli_check claude:haiku codex:gpt-6-luna

  Each check is one real request, so it counts against the subscription's usage.
  """

  use Mix.Task

  alias TinyAxe.Model

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    models =
      case args do
        [] -> configured()
        _ -> Enum.map(args, &parse/1)
      end

    results = Enum.map(models, &check/1)
    if Enum.any?(results, &(&1 != :ok)), do: exit({:shutdown, 1})
  end

  defp configured do
    [Model.role(:escalate), Model.role(:agent)]
    |> List.flatten()
    |> Enum.filter(&Model.remote?/1)
    |> Enum.uniq()
  end

  defp parse(arg) do
    case String.split(arg, ":", parts: 2) do
      ["claude", model] -> {:claude, model}
      ["codex", model] -> {:codex, model}
      _ -> Mix.raise("expected claude:<model> or codex:<model>, got #{inspect(arg)}")
    end
  end

  defp check(choice) do
    me = self()
    t0 = System.monotonic_time(:millisecond)

    result =
      Model.chat([%{role: "user", content: "Reply with exactly: ready"}],
        use: choice,
        on_usage: &send(me, {:usage, &1})
      )

    ms = System.monotonic_time(:millisecond) - t0

    usage =
      receive do
        {:usage, u} -> u
      after
        0 -> %{}
      end

    case result do
      {:ok, %{"message" => %{"content" => text}}} ->
        answered = usage[:model] || elem(choice, 1)

        Mix.shell().info(
          "✓ #{Model.label(choice)}: #{inspect(String.trim(text))} from #{answered} in #{ms} ms#{quota(usage[:quota])}"
        )

        :ok

      {:error, reason} ->
        Mix.shell().error("✗ #{Model.label(choice)}: #{TinyAxe.Escalation.explain(reason)}")
        :error
    end
  end

  defp quota(%{five_hour: five, seven_day: seven}) when is_number(five) and is_number(seven),
    do: " · usage: #{round(five * 100)}% of 5 hours, #{round(seven * 100)}% of 7 days"

  defp quota(_), do: ""
end
