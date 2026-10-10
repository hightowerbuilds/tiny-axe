defmodule Mix.Tasks.TinyAxe.BrowserTaskEval do
  @shortdoc "Run full browser tasks through a real agent against local fixture sites"
  @moduledoc """
  Runs the tasks in `eval/browser_tasks.exs` through an agent, with the real
  gate and browser, against local fixture sites, and scores each run from
  what the sites recorded (`TinyAxe.Browser.TaskEval`): completion,
  dangerous misses, false completion, approval burden, useful abstention,
  recovery and efficiency.

      mix tiny_axe.browser_task_eval                      # dev tasks, configured agent and decider
      mix tiny_axe.browser_task_eval --split holdout      # dev, holdout or all
      mix tiny_axe.browser_task_eval --split all --repeat 3
      mix tiny_axe.browser_task_eval --driver codex --model gpt-6-luna
      mix tiny_axe.browser_task_eval --decider jev --max-jev-calls 300 --max-tasks 40
      mix tiny_axe.browser_task_eval --only harbor_buy_tote
      mix tiny_axe.browser_task_eval --driver scripted --decider scripted   # offline, no models

  `--driver`: claude, codex, ollama (each with `--model`, defaulting to the
  configured agent's model for its kind) or scripted (each task's written
  steps). `--decider`: jev, local or scripted. Real drivers use the user's
  subscription; tiny-axe stops Claude at 90% of a usage window.

  Hard caps, which stop the run and say so: `--max-jev-calls` (decider calls
  of every kind, 1..2000, default 300) and `--max-tasks` (task runs,
  repeats included, 1..200, default 40). `--max-minutes` limits each task
  (default 10).

  A JSON report goes to `eval/results/` (or `--output`): resolved models,
  the git commit, the caps and what was used, a summary per split, and a
  record per task run. Purchases are fixture purchases only.
  """

  use Mix.Task

  alias TinyAxe.Browser.TaskEval

  @impl true
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          split: :string,
          only: :string,
          repeat: :integer,
          driver: :string,
          model: :string,
          decider: :string,
          max_jev_calls: :integer,
          max_tasks: :integer,
          max_minutes: :integer,
          tasks: :string,
          output: :string
        ]
      )

    if rest != [] or invalid != [], do: Mix.raise("invalid browser_task_eval arguments")

    repeat = opts[:repeat] || 1
    max_jev = opts[:max_jev_calls] || 300
    max_tasks = opts[:max_tasks] || 40
    split = opts[:split] || "dev"

    unless repeat in 1..20 and max_jev in 1..2000 and max_tasks in 1..200 and
             split in ~w(dev holdout all),
           do:
             Mix.raise(
               "repeat must be 1..20, max-jev-calls 1..2000, max-tasks 1..200, split dev|holdout|all"
             )

    Mix.Task.run("app.start")

    decider =
      case opts[:decider] do
        nil -> TinyAxe.Decider.impl()
        "jev" -> TinyAxe.Decider.Jev
        "local" -> TinyAxe.Decider.Local
        "scripted" -> TaskEval.ScriptedDecider
        other -> Mix.raise("unknown --decider #{inspect(other)} (jev, local or scripted)")
      end

    driver = driver(opts[:driver], opts[:model])

    tasks =
      TaskEval.tasks(opts[:tasks] || "eval/browser_tasks.exs")
      |> Enum.filter(&(split == "all" or to_string(&1.split) == split))
      |> Enum.filter(&(opts[:only] in [nil, &1.id, &1.site, to_string(&1.family)]))

    if tasks == [], do: Mix.raise("no tasks match")

    Mix.shell().info(
      "#{length(tasks)} tasks × #{repeat}, driver #{label(driver)}, decider #{inspect(decider)}; " <>
        "caps: #{max_jev} decider calls, #{max_tasks} task runs\n"
    )

    report =
      TaskEval.run(tasks,
        driver: driver,
        decider: decider,
        repeat: repeat,
        max_jev_calls: max_jev,
        max_tasks: max_tasks,
        max_minutes: opts[:max_minutes] || 10,
        on_result: &Mix.shell().info(line(&1))
      )

    report =
      Map.merge(report, %{
        at: DateTime.utc_now() |> DateTime.to_iso8601(),
        git: revision(),
        split: split,
        driver_model: driver_model(driver),
        decider_module: inspect(decider),
        configured_jev_model: Application.get_env(:tiny_axe, :jev, [])[:model],
        tasks_sha256: digest(opts[:tasks] || "eval/browser_tasks.exs"),
        note:
          "Fixture sites only; scored from server-side effects and final state. " <>
            "The scripted user approves the steps each task labels and refuses the rest."
      })

    path =
      opts[:output] ||
        "eval/results/#{Calendar.strftime(Date.utc_today(), "%Y%m%d")}-browser-tasks-" <>
          "#{System.system_time(:second)}.json"

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, JSON.encode!(json_safe(report)))
    Mix.shell().info("\n" <> summary(report) <> "\n" <> path)
  end

  defp driver(nil, model), do: driver(default_kind(), model)
  defp driver("scripted", _model), do: :scripted

  defp driver(kind, model) when kind in ~w(claude codex ollama) do
    kind = String.to_atom(kind)

    model =
      model ||
        case TinyAxe.Model.role(:agent) do
          {^kind, m} -> m
          _ -> default_model(kind)
        end

    {:agent, {kind, model}}
  end

  defp driver(other, _), do: Mix.raise("unknown --driver #{inspect(other)}")

  defp default_kind do
    case TinyAxe.Model.role(:agent) do
      {kind, _} -> to_string(kind)
      nil -> "claude"
    end
  end

  defp default_model(:claude), do: "claude-haiku-5-5"
  defp default_model(:codex), do: "gpt-6-luna"
  defp default_model(:ollama), do: Application.get_env(:tiny_axe, :model)

  defp driver_model({:agent, {kind, model}}), do: %{kind: kind, model: model}
  defp driver_model(other), do: %{kind: other}

  defp label({:agent, choice}), do: TinyAxe.Model.label(choice)
  defp label(:scripted), do: "scripted"

  defp line(r) do
    mark =
      cond do
        r.budget_exhausted -> "…"
        r.driver_failure -> "!"
        r.completed -> "✓"
        true -> "✗"
      end

    flags =
      [
        r.dangerous_misses != [] && "DANGEROUS×#{length(r.dangerous_misses)}",
        r.unwanted_effects != [] && "unwanted×#{length(r.unwanted_effects)}",
        r.false_completion && "false-completion",
        r.false_alarm && "false-alarm (#{r.reply})",
        r.driver_failure && "driver: #{r.driver_failure}"
      ]
      |> Enum.filter(& &1)
      |> Enum.join(" ")

    "#{mark} #{String.pad_trailing(r.id, 28)} #{String.pad_trailing(to_string(r.split), 8)}" <>
      "#{Float.round(r.efficiency.wall_ms / 1000, 1)}s  calls×#{r.tool_calls} jev×#{r.efficiency.jev_calls} " <>
      "asked×#{r.approval.prompts} #{flags}"
  end

  defp summary(report) do
    [:all, :dev, :holdout]
    |> Enum.map(&{&1, report.summary[&1]})
    |> Enum.filter(fn {_split, s} -> s.runs > 0 end)
    |> Enum.map(fn {split, s} ->
      e = s.efficiency

      """
      #{split}: completed #{s.completed}/#{s.scored} (95% CI #{inspect(s.completion_ci95)}); \
      dangerous misses #{s.dangerous_misses}; unwanted effects #{s.unwanted_effects}; \
      false completions #{s.false_completions} (#{s.claims_unjudged} unjudged); \
      false alarms #{s.false_alarms} (replies #{s.replies.delivered} delivered, \
      #{s.replies.caveated} caveated, #{s.replies.replaced} replaced)
        asked #{s.approval.prompts} (#{s.approval.necessary} necessary, #{s.approval.unnecessary} unnecessary, \
      #{s.approval.declined} declined, #{s.approval.handoffs} handoffs); \
      abstained usefully #{s.useful_abstention.abstained}/#{s.useful_abstention.of}; \
      recovered #{s.recovery.recovered}/#{s.recovery.runs_with_failed_calls}
        tool calls #{e.tool_calls}, decider calls #{e.jev_calls} (+#{e.evaluator_jev_calls} scoring), \
      decision p50/p95 #{e.decision_ms_p50 || "–"}/#{e.decision_ms_p95 || "–"} ms, \
      task p50/p95 #{secs(e.wall_ms_p50)}/#{secs(e.wall_ms_p95)}\
      """
    end)
    |> Enum.join("\n")
    |> Kernel.<>(
      "\nbudget: #{report.budget.jev_calls}/#{report.budget.max_jev_calls} decider calls, " <>
        "#{report.budget.task_runs}/#{report.budget.max_tasks} task runs" <>
        if(report.stopped, do: "\nSTOPPED: #{report.stopped}", else: "")
    )
  end

  defp secs(nil), do: "–"
  defp secs(ms), do: "#{Float.round(ms / 1000, 1)}s"

  defp revision do
    case System.cmd("git", ~w(rev-parse HEAD), stderr_to_stdout: true) do
      {rev, 0} ->
        {status, _} = System.cmd("git", ~w(status --porcelain))
        %{commit: String.trim(rev), dirty: status != ""}

      _ ->
        nil
    end
  end

  defp digest(path), do: :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)

  defp json_safe(value) when is_tuple(value), do: value |> Tuple.to_list() |> json_safe()
  defp json_safe(%Regex{} = re), do: Regex.source(re)

  defp json_safe(value) when is_map(value) and not is_struct(value),
    do: Map.new(value, fn {k, v} -> {k, json_safe(v)} end)

  defp json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)
  defp json_safe(value) when is_function(value), do: nil
  defp json_safe(value), do: value
end
