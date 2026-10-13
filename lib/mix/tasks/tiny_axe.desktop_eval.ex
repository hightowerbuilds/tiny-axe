defmodule Mix.Tasks.TinyAxe.DesktopEval do
  @shortdoc "Score the desktop route on fixed tasks (real model and decider, fake desktop)"
  @moduledoc """
  Runs `eval/desktop_tasks.exs` through `TinyAxe.Desktop.decide/4` with the
  configured local model and decider, against a fixed fake desktop
  (`TinyAxe.Desktop.Eval`): nothing is applied, nothing on this computer
  changes.

      mix tiny_axe.desktop_eval                   # all tasks, local model only
      mix tiny_axe.desktop_eval --split holdout   # one split
      mix tiny_axe.desktop_eval --only louder,tabs_bottom
      mix tiny_axe.desktop_eval --haiku           # let escalation reach Claude Haiku 5.5
      mix tiny_axe.desktop_eval --quiet           # summary only

  The summary goes to `eval/results/<time>-desktop.json`. `wrong` (a wrong
  plan that would have run) is the number that matters most.
  """

  use Mix.Task

  @impl true
  def run(argv) do
    {opts, _, _} =
      OptionParser.parse(argv,
        strict: [split: :string, only: :string, haiku: :boolean, quiet: :boolean]
      )

    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started([:req, :telemetry])
    # Escalation keeps quota stats; without it, the ladder sees no quota.
    if opts[:haiku], do: TinyAxe.Escalation.start_link([])

    {tasks, _} = Code.eval_file("eval/desktop_tasks.exs")

    tasks =
      tasks
      |> filter(:split, opts[:split] && String.to_atom(opts[:split]))
      |> then(fn ts ->
        case opts[:only] do
          nil -> ts
          ids -> Enum.filter(ts, &(&1.id in String.split(ids, ",")))
        end
      end)

    summary = TinyAxe.Desktop.Eval.run(tasks, haiku: opts[:haiku], verbose: !opts[:quiet])

    for {split, s} <- summary.splits do
      Mix.shell().info(
        "#{split}: #{s.tasks} tasks · right #{s.right} · right but asked #{s.right_asked} · " <>
          "escalated #{s.escalated} · wrong #{s.wrong} · errors #{s.error}"
      )
    end

    Mix.shell().info("median #{summary.median_ms} ms per task")
    stamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")
    path = "eval/results/#{stamp}-desktop.json"
    File.mkdir_p!("eval/results")
    File.write!(path, JSON.encode!(summary))
    Mix.shell().info("wrote #{path}")
  end

  defp filter(tasks, _key, nil), do: tasks
  defp filter(tasks, key, value), do: Enum.filter(tasks, &(Map.get(&1, key) == value))
end
