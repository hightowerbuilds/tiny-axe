defmodule Mix.Tasks.TinyAxe.Eval do
  @shortdoc "Run the evaluation tasks against the real model and decider"
  @moduledoc """
  Runs the tasks in `eval/tasks.exs` through the real pipeline, each in a
  throwaway home folder, and checks every outcome independently of the model's
  own judgment (see `TinyAxe.Eval`).

      mix tiny_axe.eval                    # the development tasks
      mix tiny_axe.eval --split holdout    # the held-out tasks (dev, holdout or all)
      mix tiny_axe.eval --only files       # a category or a task id
      mix tiny_axe.eval --repeat 3         # each task three times
      mix tiny_axe.eval --model gemma3:12b --decider jev
      mix tiny_axe.eval --think            # let the model think before answering
      mix tiny_axe.eval --escalate         # let tasks the local model falls short on
                                           # go to Claude/Codex (uses the subscriptions)

  A summary is written to `eval/results/`. The full results, answers included,
  go to the state folder (`eval/` in it), not the repo. Held-out tasks are for
  checking a change after tuning on the development ones, not for tuning.
  """

  use Mix.Task

  alias TinyAxe.Eval

  @impl true
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          split: :string,
          only: :string,
          repeat: :integer,
          model: :string,
          decider: :string,
          tasks: :string,
          think: :boolean,
          escalate: :boolean
        ]
      )

    if model = opts[:model], do: Application.put_env(:tiny_axe, :model, model)
    if Keyword.has_key?(opts, :think), do: Application.put_env(:tiny_axe, :think, opts[:think])

    case opts[:decider] do
      nil -> :ok
      "jev" -> Application.put_env(:tiny_axe, :decider, TinyAxe.Decider.Jev)
      "local" -> Application.put_env(:tiny_axe, :decider, TinyAxe.Decider.Local)
      other -> Mix.raise("unknown --decider #{inspect(other)} (expected jev or local)")
    end

    Mix.Task.run("app.start")

    case TinyAxe.OllamaServer.ensure_running() do
      {:ok, _} -> :ok
      {:error, reason} -> Mix.raise(reason)
    end

    split = opts[:split] || "dev"

    tasks =
      Eval.tasks(opts[:tasks] || "eval/tasks.exs")
      |> Enum.filter(&(split == "all" or to_string(&1.split) == split))
      |> Enum.filter(&(opts[:only] in [nil, to_string(&1.category), to_string(&1.id)]))

    if tasks == [], do: Mix.raise("no tasks match")

    repeat = opts[:repeat] || 1
    model = Application.get_env(:tiny_axe, :model)

    decider =
      Application.get_env(:tiny_axe, :decider) |> inspect() |> String.split(".") |> List.last()

    Mix.shell().info("#{length(tasks)} tasks × #{repeat}, model #{model}, decider #{decider}\n")

    results =
      for task <- tasks, _ <- 1..repeat do
        r = Eval.run_task(task, escalate: opts[:escalate] || false)
        Mix.shell().info(line(r))

        if r.attempts > 1,
          do: Mix.shell().info("      code checks: #{Enum.join(r.code_checks, " → ")}")

        if r.escalated != [],
          do:
            Mix.shell().info(
              "      escalated to #{Enum.join(r.escalated, " → ")}; answered by #{r.answered_by || "the local model"}"
            )

        if r.error, do: Mix.shell().info("      error: #{r.error}")
        for c <- r.checks, not c.ok, do: Mix.shell().info("      ✗ #{c.check}: #{c.why}")
        r
      end

    summary = Eval.summary(results)
    Mix.shell().info("\n" <> report(summary))

    meta = %{
      model: model,
      model_digest: digest(model),
      decider: decider,
      num_ctx: TinyAxe.Context.window(),
      think: Application.get_env(:tiny_axe, :think, false),
      escalate: opts[:escalate] || false,
      ladder:
        if(opts[:escalate],
          do: Enum.map(TinyAxe.Escalation.ladder(), &TinyAxe.Model.label/1),
          else: []
        ),
      revision: revision(),
      split: split,
      repeat: repeat
    }

    save(summary, results, meta)
  end

  # The exact model build, so runs of "the same" tag can be compared.
  defp digest(model) do
    url = Application.get_env(:tiny_axe, :ollama_url, "http://localhost:11434")

    with {:ok, %{status: 200, body: %{"models" => models}}} <- Req.get(url <> "/api/tags") do
      Enum.find_value(models, &(&1["name"] in [model, model <> ":latest"] && &1["digest"]))
    else
      _ -> nil
    end
  end

  # The commit, marked if there were uncommitted changes.
  defp revision do
    case System.cmd("git", ~w(rev-parse --short HEAD), stderr_to_stdout: true) do
      {rev, 0} ->
        {status, _} = System.cmd("git", ~w(status --porcelain))
        String.trim(rev) <> if(status == "", do: "", else: "+changes")

      _ ->
        nil
    end
  end

  defp line(r) do
    mark = if r.passed, do: "✓", else: "✗"

    "#{mark} #{String.pad_trailing(to_string(r.id), 28)} #{String.pad_trailing(to_string(r.category), 9)} " <>
      "#{secs(r.total_ms)}  model×#{r.calls.model} decider×#{r.calls.decider}  attempts #{r.attempts}"
  end

  defp report(s) do
    cats =
      s.by_category
      |> Enum.sort()
      |> Enum.map_join("\n", fn {cat, %{passed: p, of: n}} -> "  #{cat}: #{p}/#{n}" end)

    """
    passed #{s.passed}/#{s.tasks}
    #{cats}
    route accuracy #{s.route_accuracy || "–"}
    verifier: #{s.false_acceptances} false acceptances, #{s.false_rejections} false rejections, #{s.unjudged} unjudged
    retries: #{s.retry_fixed} fixed a failing first attempt, #{s.retry_broke} broke a passing one
    escalation: #{s.escalated} escalated, #{s.escalated_passed} of them passed
    mean attempts #{s.mean_attempts}, median #{secs(s.median_ms)}, p90 #{secs(s.p90_ms)}
    calls: model #{s.model_calls} (#{s.remote_calls} left the machine), decider #{s.decider_calls}
    """
  end

  defp secs(nil), do: "–"
  defp secs(ms), do: "#{Float.round(ms / 1000, 1)}s"

  defp save(summary, results, meta) do
    stamp = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(:basic)
    name = "#{stamp}-#{String.replace(to_string(meta.model), ~r/[^\w.-]/, "_")}"

    brief =
      Enum.map(results, fn r ->
        Map.take(r, [
          :id,
          :category,
          :split,
          :passed,
          :route,
          :attempts,
          :verdict,
          :first_passed,
          :escalated,
          :answered_by,
          :total_ms,
          :calls
        ])
        |> Map.put(:failed_checks, for(c <- r.checks, not c.ok, do: "#{c.check}: #{c.why}"))
      end)

    File.mkdir_p!("eval/results")
    path = "eval/results/#{name}.json"
    File.write!(path, JSON.encode!(%{meta: meta, summary: summary, tasks: brief}))

    traces = Path.join([TinyAxe.Ops.Journal.state_dir(), "eval", "#{name}.json"])
    File.mkdir_p!(Path.dirname(traces))
    File.write!(traces, JSON.encode!(%{meta: meta, results: results}))

    Mix.shell().info("summary: #{path}\nfull results: #{TinyAxe.Ops.show(traces)}")
  end
end
