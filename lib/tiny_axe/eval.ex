defmodule TinyAxe.Eval do
  @moduledoc """
  Runs fixed tasks through the real pipeline and checks each outcome
  independently of the model's own judgment: the folder tree a file plan
  leaves, tests the task defines for generated code, facts an answer must
  contain, the command planned, and which way a request was routed.

  Each task runs in its own throwaway home folder, with its own journal and
  Trash, so nothing touches the real ones. File plans are approved there (the
  only way to check the tree they leave); commands are planned but never run.

  See `mix tiny_axe.eval` for running it, and `eval/tasks.exs` for the tasks.
  """

  alias TinyAxe.{CodeCheck, Decider, Location, Ops, Pipeline, Sandbox}

  @type task :: map()

  @doc "Loads the task list (`eval/tasks.exs`)."
  @spec tasks(String.t()) :: [task()]
  def tasks(path \\ "eval/tasks.exs") do
    {tasks, _} = Code.eval_file(path)
    tasks
  end

  @doc """
  Runs one task and returns its result: checks, route, timings, calls.
  `opts[:escalate]`: whether a task the local model falls short on may go to
  the escalation ladder (Claude, Codex); off by default, so runs compare.
  """
  @spec run_task(task(), keyword()) :: map()
  def run_task(task, opts \\ []) do
    root = Path.join(System.tmp_dir!(), "tiny_axe_eval_#{System.unique_integer([:positive])}")
    home = Path.join(root, "home")

    try do
      set_up(task, root, home)
      counters = count_calls()
      t0 = System.monotonic_time(:millisecond)
      remote = if Keyword.get(opts, :escalate, false), do: :allowed, else: :denied
      events = run_pipeline(task, t0, remote)
      total_ms = System.monotonic_time(:millisecond) - t0
      calls = collect_calls(counters)
      applied = approve_plan(events)
      checks = check(task, events, home)
      texts = attempt_texts(events)

      %{
        id: task.id,
        category: task.category,
        split: task.split,
        passed: Enum.all?(checks, & &1.ok),
        checks: checks,
        route: route_taken(events),
        attempts: length(texts),
        # Whether the first attempt would already have passed, when there were retries.
        first_passed: if(length(texts) > 1, do: answer_checks_pass?(task, hd(texts))),
        verdict: verdict(events),
        # Models the request went up to, and the one that answered, if not local.
        escalated: for({_, {:escalate, %{to: to}}} <- events, do: to),
        answered_by:
          Enum.find_value(events, fn
            {_, {:answered_by, %{model: m}}} -> m
            _ -> nil
          end),
        plan_applied: applied,
        total_ms: total_ms,
        first_output_ms: first_output_ms(events),
        calls: calls,
        tokens: tokens(events),
        # Kept out of the repo's summary; only the full results in the state folder.
        attempt_texts: texts,
        # Each attempt's code check: what the harness's own evidence said.
        code_checks:
          for {_, {:check, c}} <- events do
            case c do
              {:ran, %{status: status, summary: summary}} -> "#{status}: #{summary}"
              {:skipped, reason} -> "skipped: #{reason}"
            end
          end,
        error:
          Enum.find_value(events, fn
            {_, {:error, reason}} -> inspect(reason)
            _ -> nil
          end),
        answer:
          events
          |> Enum.find_value(fn
            {_, {:done, t}} -> t
            _ -> nil
          end)
          |> truncate(600)
      }
    after
      restore()
      File.rm_rf(root)
    end
  end

  ## Setting up a throwaway world

  @env_keys ~w(fs_root project_dir state_dir trash_dir)a

  defp set_up(task, root, home) do
    config = Map.get(task, :config, [])
    keys = @env_keys ++ Keyword.keys(config)
    Process.put(:eval_saved_env, Map.new(keys, &{&1, Application.get_env(:tiny_axe, &1)}))
    for {k, v} <- config, do: Application.put_env(:tiny_axe, k, v)

    for {rel, content} <- Map.get(task, :home, %{}) do
      path = Path.join(home, rel)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
    end

    File.mkdir_p!(home)
    start = Path.join(home, Map.get(task, :start, "."))
    File.mkdir_p!(start)

    Application.put_env(:tiny_axe, :fs_root, home)
    Application.put_env(:tiny_axe, :project_dir, Path.expand(start))
    Application.put_env(:tiny_axe, :state_dir, Path.join(root, "state"))
    Application.put_env(:tiny_axe, :trash_dir, Path.join(root, "Trash"))
    Location.reset()
  end

  defp restore do
    for {k, v} <- Process.get(:eval_saved_env, %{}) do
      if v == nil,
        do: Application.delete_env(:tiny_axe, k),
        else: Application.put_env(:tiny_axe, k, v)
    end

    Location.reset()
  end

  ## Running and timing

  defp run_pipeline(task, t0, remote) do
    me = self()

    Pipeline.run(
      Map.get(task, :history, []),
      task.prompt,
      &send(me, {:eval_event, System.monotonic_time(:millisecond) - t0, &1}),
      remote: remote
    )

    drain([])
  end

  defp drain(acc) do
    receive do
      {:eval_event, t, e} -> drain([{t, e} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp count_calls do
    table = :ets.new(:eval_calls, [:public, :set])
    id = "tiny-axe-eval-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      id,
      [[:tiny_axe, :model, :call], [:tiny_axe, :decider, :call]],
      &__MODULE__.count_call/4,
      table
    )

    {id, table}
  end

  @doc false
  def count_call([:tiny_axe, what, :call], %{ms: ms}, meta, table) do
    :ets.update_counter(table, {what, :count}, 1, {{what, :count}, 0})
    :ets.update_counter(table, {what, :ms}, ms, {{what, :ms}, 0})

    # Calls to Claude or Codex, which leave the machine and use a subscription.
    if meta[:remote], do: :ets.update_counter(table, {what, :remote}, 1, {{what, :remote}, 0})
  end

  defp collect_calls({id, table}) do
    :telemetry.detach(id)

    get = fn key ->
      case :ets.lookup(table, key) do
        [{_, v}] -> v
        [] -> 0
      end
    end

    result = %{
      model: get.({:model, :count}),
      model_ms: get.({:model, :ms}),
      remote: get.({:model, :remote}),
      decider: get.({:decider, :count}),
      decider_ms: get.({:decider, :ms})
    }

    :ets.delete(table)
    result
  end

  # A file plan is approved, as the user would, but only in the throwaway home.
  defp approve_plan(events) do
    case Enum.find_value(events, fn
           {_, {:plan, p}} -> p
           _ -> nil
         end) do
      nil ->
        false

      plan ->
        case TinyAxe.Ops.Runner.run(plan.request, plan.ops, self()) do
          {:ok, id} -> wait_for(id)
          {:error, _} -> false
        end
    end
  end

  defp wait_for(id) do
    receive do
      {:ops, ^id, {:finished, _}} -> true
      {:ops, ^id, {kind, _}} when kind in [:stopped, :interrupted] -> false
      {:ops, ^id, {:stopped, _, _}} -> false
      {:ops, ^id, _progress} -> wait_for(id)
    after
      30_000 -> false
    end
  end

  ## Independent checks

  # Checks on the answer's text, which can also be run on any earlier attempt.
  @answer_checks [:contains, :elixir_tests]

  defp check(task, events, home) do
    answer =
      Enum.find_value(events, "", fn
        {_, {:done, t}} -> t
        _ -> nil
      end)

    command_plan =
      Enum.find_value(events, fn
        {_, {:command_plan, p}} -> p
        _ -> nil
      end)

    Enum.map(task.expect, fn
      {:route, want} ->
        got = route_taken(events)
        result("routed to #{want}", got == want, "went to #{got}")

      {kind, _} = expect when kind in @answer_checks ->
        answer_check(expect, answer)

      {:tree, expected} ->
        wrong =
          for {rel, want} <- expected,
              (got = tree_entry(home, rel)) != want,
              do: "#{rel}: expected #{inspect(want)}, got #{inspect(got)}"

        result("files end up as expected", wrong == [], Enum.join(wrong, "; "))

      {:file_mentions, {rel, facts}} ->
        text = String.downcase(File.read(Path.join(home, rel)) |> elem_ok())
        missing = Enum.reject(facts, &String.contains?(text, String.downcase(&1)))

        result(
          "#{rel} mentions #{Enum.join(facts, ", ")}",
          missing == [],
          "missing #{Enum.join(missing, ", ")}"
        )

      {:command, pattern} ->
        commands = if command_plan, do: Enum.map(command_plan.commands, & &1.command), else: []
        ok = Enum.any?(commands, &Regex.match?(pattern, &1))

        result(
          "plans a command matching #{inspect(pattern.source)}",
          ok,
          "planned #{inspect(commands)}"
        )

      {:command_dir, rel} ->
        want = Path.expand(Path.join(home, rel))
        got = command_plan && command_plan.dir

        result(
          "runs it in ~/#{rel}",
          got == want,
          "would run in #{inspect(got && Ops.show(got))}"
        )
    end)
  end

  # Each fact is a phrase, or a list of phrasings any one of which will do.
  defp answer_check({:contains, facts}, text) do
    mentions? = fn phrase -> String.contains?(String.downcase(text), String.downcase(phrase)) end
    missing = Enum.reject(facts, &Enum.any?(List.wrap(&1), mentions?))
    show = &Enum.map_join(&1, ", ", fn f -> f |> List.wrap() |> Enum.join(" or ") end)
    result("answer mentions #{show.(facts)}", missing == [], "missing #{show.(missing)}")
  end

  defp answer_check({:elixir_tests, body}, text) do
    {ok, why} = run_elixir_tests(text, body)
    result("generated code passes the task's own tests", ok, why)
  end

  defp answer_checks_pass?(task, text) do
    for({kind, _} = e <- task.expect, kind in @answer_checks, do: answer_check(e, text).ok)
    |> Enum.all?()
  end

  defp result(name, ok, why), do: %{check: name, ok: ok, why: if(ok, do: nil, else: why)}

  defp elem_ok({:ok, v}), do: v
  defp elem_ok(_), do: ""

  defp tree_entry(home, rel) do
    path = Path.join(home, rel)

    cond do
      File.regular?(path) -> File.read!(path)
      File.dir?(path) -> :dir
      true -> :absent
    end
  end

  # The task's tests run against the answer's code in the sandbox: evidence
  # that doesn't depend on the model's own doctests.
  defp run_elixir_tests(answer, body) do
    case CodeCheck.extract(answer) do
      [] ->
        {false, "no Elixir code in the answer"}

      blocks ->
        dir =
          Path.join(System.tmp_dir!(), "tiny_axe_eval_code_#{System.unique_integer([:positive])}")

        File.mkdir_p!(dir)

        try do
          File.write!(Path.join(dir, "answer.ex"), Enum.map_join(blocks, "\n\n", &elem(&1, 1)))

          File.write!(Path.join(dir, "task_test.exs"), """
          ExUnit.start(autorun: false)
          Code.require_file("answer.ex")

          defmodule TaskTest do
            use ExUnit.Case
            test "task" do
          #{body}
            end
          end

          result = ExUnit.run()
          System.halt(if result.failures == 0, do: 0, else: 1)
          """)

          case Sandbox.cmd(~w(elixir task_test.exs), dir) do
            {_, 0} ->
              {true, nil}

            {out, _} ->
              {false,
               out |> String.split("\n") |> Enum.take(12) |> Enum.join(" ") |> truncate(300)}
          end
        after
          File.rm_rf(dir)
        end
    end
  end

  ## What happened

  defp route_taken(events) do
    case Enum.find_value(events, fn
           {_, {:task, t}} -> t
           _ -> nil
         end) do
      nil -> :none
      t -> t
    end
  end

  # What the harness's own judgment said about the result it gave: :accepted,
  # :rejected (it fell short and was returned anyway, as the best attempt or a
  # plan reviewed low), or :none (nothing was judged, or the judge was unavailable).
  defp verdict(events) do
    plan_review =
      Enum.find_value(events, fn
        {_, {:plan, p}} -> {:review, p.review}
        {_, {:command_plan, p}} -> {:review, p.review}
        _ -> nil
      end)

    last_verify =
      for({_, {:verify, v}} <- events, do: Decider.p(v, :addresses)) |> List.last()

    cond do
      plan_review -> judged(elem(plan_review, 1), Decider.review_threshold())
      Enum.any?(events, &match?({_, {:chose, _}}, &1)) -> :rejected
      true -> judged(last_verify, Application.get_env(:tiny_axe, :accept_threshold, 0.7))
    end
  end

  defp judged(p, threshold) when is_number(p),
    do: if(p >= threshold, do: :accepted, else: :rejected)

  defp judged(_, _), do: :none

  # The text of each attempt, from the streamed output between attempt markers.
  defp attempt_texts(events) do
    events
    |> Enum.reduce([], fn
      {_, {:attempt, _}}, acc -> ["" | acc]
      {_, {:delta, d}}, [cur | rest] -> [cur <> d | rest]
      _, acc -> acc
    end)
    |> Enum.reverse()
  end

  defp first_output_ms(events),
    do:
      Enum.find_value(events, fn
        {t, {:delta, _}} -> t
        {t, {:done, _}} -> t
        _ -> nil
      end)

  defp tokens(events) do
    usages = for {_, {:usage, u}} <- events, do: u

    %{
      prompt: Enum.sum(Enum.map(usages, & &1.prompt_tokens)),
      output: Enum.sum(Enum.map(usages, & &1.output_tokens)),
      generate_ms: Enum.sum(Enum.map(usages, &Map.get(&1, :generate_ms, 0))),
      prompt_ms: Enum.sum(Enum.map(usages, &Map.get(&1, :prompt_ms, 0)))
    }
  end

  defp truncate(nil, _), do: nil

  defp truncate(s, n) when is_binary(s),
    do: if(String.length(s) > n, do: String.slice(s, 0, n) <> "…", else: s)

  @doc "Summarises results: success by category, routing, verifier agreement, latency, calls."
  @spec summary([map()]) :: map()
  def summary(results) do
    by_category =
      results
      |> Enum.group_by(& &1.category)
      |> Map.new(fn {cat, rs} ->
        {cat, %{passed: Enum.count(rs, & &1.passed), of: length(rs)}}
      end)

    route_checks =
      for r <- results, c <- r.checks, String.starts_with?(c.check, "routed to"), do: c.ok

    latencies = results |> Enum.map(& &1.total_ms) |> Enum.sort()

    %{
      tasks: length(results),
      passed: Enum.count(results, & &1.passed),
      by_category: by_category,
      route_accuracy: ratio(Enum.count(route_checks, & &1), length(route_checks)),
      # The verifier's own verdict against the independent checks.
      false_acceptances: Enum.count(results, &(&1.verdict == :accepted and not &1.passed)),
      false_rejections: Enum.count(results, &(&1.verdict == :rejected and &1.passed)),
      unjudged: Enum.count(results, &(&1.verdict == :none)),
      # Retries that turned a failing first attempt into a pass, and the reverse.
      retry_fixed: Enum.count(results, &(&1.first_passed == false and &1.passed)),
      retry_broke: Enum.count(results, &(&1.first_passed == true and not &1.passed)),
      # Tasks sent up the ladder, and how many of those then passed.
      escalated: Enum.count(results, &(Map.get(&1, :escalated, []) != [])),
      escalated_passed: Enum.count(results, &(Map.get(&1, :escalated, []) != [] and &1.passed)),
      mean_attempts: ratio(Enum.sum(Enum.map(results, & &1.attempts)), length(results)),
      median_ms: percentile(latencies, 0.5),
      p90_ms: percentile(latencies, 0.9),
      model_calls: Enum.sum(Enum.map(results, & &1.calls.model)),
      remote_calls: Enum.sum(Enum.map(results, &Map.get(&1.calls, :remote, 0))),
      decider_calls: Enum.sum(Enum.map(results, & &1.calls.decider))
    }
  end

  defp ratio(_, 0), do: nil
  defp ratio(a, b), do: Float.round(a / b, 2)

  defp percentile([], _), do: nil

  defp percentile(sorted, p),
    do: Enum.at(sorted, min(round(p * (length(sorted) - 1)), length(sorted) - 1))
end
