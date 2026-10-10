defmodule TinyAxe.Browser.TaskEval do
  @moduledoc """
  Full browser tasks, run through a real agent against local fixture sites
  (`TinyAxe.Browser.TaskEval.Sites`), and scored from what the sites
  recorded (`TinyAxe.Browser.TaskEval.Assess`), never from what the agent
  says. This is the agent-level layer of the browser evaluation; the
  decision-level layer is `TinyAxe.Browser.PolicyEval`.

  Each task run gets fresh sites, a fresh headless browser in a throwaway
  profile, no holds on unresolved actions, and throwaway state (tool journals, decision traces, the purchase
  journal), so nothing touches the user's own. Purchases are switched on for
  the run only, with no cards, so the only orders possible are fixture
  orders paid with cards "saved at" a fixture shop. Every question the gate
  asks is answered by `TinyAxe.Browser.TaskEval.User`.

  Drivers: `{:agent, choice}` runs `TinyAxe.Agent` with that driver (Claude,
  Codex or the local model); `:scripted` plays each task's written `script`
  through the gate (`TinyAxe.Browser.TaskEval.ScriptedDriver`); `{:fun, f}`
  is for tests (`f.(ctx)` returns `{:ok, reply}` or `{:error, why}`). Their
  replies get the same completion check as an agent's
  (`TinyAxe.Tools.Gate.complete/2`), so what's scored is what the user
  would have been shown.

  Hard caps stop the run and say so: `:max_jev_calls` (all decider calls:
  the gate's, purchase checks, and scoring claims) and `:max_tasks` (task
  runs, repeats included). A task during which the decider cap was reached
  is reported but not scored.

  See `mix tiny_axe.browser_task_eval` for running it, and
  `eval/browser_tasks.exs` for the tasks.
  """

  require Logger

  alias TinyAxe.{Agent, Browser, Escalation, MCP, Model, Purchases}
  alias TinyAxe.Browser.TaskEval.{Assess, Budget, ScriptedDriver, Sites, User}
  alias TinyAxe.Tools.Gate

  @driver_failures [:not_logged_in, :not_installed, :usage_limit, :not_subscription]

  @doc "Loads the task list (`eval/browser_tasks.exs`)."
  def tasks(path \\ "eval/browser_tasks.exs") do
    {tasks, _} = Code.eval_file(path)
    tasks
  end

  @doc """
  Runs the tasks and returns a report: per-task records, a summary per
  split, the budget used, and why the run stopped early, if it did.

  `opts`: `:driver` (above; default `{:agent, configured agent}`),
  `:decider` (the module that answers; default the configured one),
  `:repeat` (1), `:max_jev_calls` (300), `:max_tasks` (40), `:choose`
  (`:off`, `:shadow` or `:on`; default the configured
  `TinyAxe.Browser.Choices.mode/0`) and `:choose_hints` (whether the
  gate's own candidate check is shown, when on), `:examples` (`:off`,
  `:shadow` or `:on`: reviewed examples, `TinyAxe.Browser.Examples`;
  default the configured mode; the run's state is throwaway, so the
  shipped curated set is the one used, and nothing is ever persisted),
  `:browser`
  (start a browser per task; default true), `:preflight` (check the decider
  and the browser before the first task; default true), `:max_minutes` (per
  task, 10), and `:on_result` (called with each record as it's made).
  """
  @spec run([map()], keyword()) :: map()
  def run(tasks, opts \\ []) do
    driver = Keyword.get(opts, :driver, {:agent, default_agent()})
    inner = Keyword.get(opts, :decider, TinyAxe.Decider.impl())
    repeat = Keyword.get(opts, :repeat, 1)
    max_jev = Keyword.get(opts, :max_jev_calls, 300)
    max_tasks = Keyword.get(opts, :max_tasks, 40)
    on_result = Keyword.get(opts, :on_result, fn _ -> :ok end)

    urls = Sites.start()
    saved = save_env()
    Budget.setup(inner, max_jev)
    {telemetry, models} = count_model_calls()
    quota_before = Escalation.stats().quota

    ctx = %{
      urls: urls,
      driver: driver,
      browser: Keyword.get(opts, :browser, true),
      browser_name: Keyword.get(opts, :browser_name, Browser.name()),
      models: models
    }

    try do
      configure(opts)
      stopped = if Keyword.get(opts, :preflight, true), do: preflight(ctx)
      planned = for i <- 1..repeat, task <- tasks, do: {task, i}

      {results, stopped} =
        Enum.reduce(planned, {[], stopped}, fn
          _planned, {acc, stopped} when stopped != nil ->
            {acc, stopped}

          {task, i}, {acc, nil} ->
            cond do
              length(acc) >= max_tasks ->
                {acc, "task budget exhausted: #{max_tasks} task runs"}

              Budget.used() >= max_jev ->
                {acc, "decider budget exhausted: #{max_jev} calls"}

              true ->
                record = run_task(task, i, ctx)
                on_result.(record)

                stop =
                  cond do
                    record.budget_exhausted -> "decider budget exhausted: #{max_jev} calls"
                    record.driver_failure -> "the driver failed: #{record.driver_failure}"
                    true -> nil
                  end

                {[record | acc], stop}
            end
        end)

      results = Enum.reverse(results)

      %{
        schema: "browser-task-eval/1",
        driver: driver_label(driver),
        decider: backend(inner),
        choose: %{mode: TinyAxe.Browser.Choices.mode(), hints: TinyAxe.Browser.Choices.hints?()},
        examples: %{
          mode: TinyAxe.Browser.Examples.mode(),
          set: TinyAxe.Browser.Examples.Store.curated()["version"],
          sha256: examples_digest()
        },
        repeat: repeat,
        planned: length(planned),
        ran: length(results),
        stopped: stopped,
        budget: %{
          jev_calls: Budget.used(),
          max_jev_calls: max_jev,
          jev_exhausted: Budget.exhausted?(),
          task_runs: length(results),
          max_tasks: max_tasks
        },
        jev_models: Budget.log() |> Enum.map(& &1.model) |> Enum.reject(&is_nil/1) |> Enum.uniq(),
        quota: %{before: quota_before, after: Escalation.stats().quota},
        summary: %{
          all: summarize(results),
          dev: summarize(Enum.filter(results, &(&1.split == :dev))),
          holdout: summarize(Enum.filter(results, &(&1.split == :holdout)))
        },
        results: results
      }
    after
      :telemetry.detach(telemetry)
      Budget.teardown()
      restore_env(saved)
    end
  end

  defp default_agent, do: Model.role(:agent) || {:claude, "claude-haiku-5-5"}

  ## One task

  defp run_task(task, iteration, ctx) do
    Sites.reset()
    # A fresh world: no hold from an earlier task's unresolved action.
    Gate.clear_holds()

    root =
      Path.join(System.tmp_dir!(), "tiny_axe_task_eval_#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    Application.put_env(:tiny_axe, :state_dir, Path.join(root, "state"))
    Application.put_env(:tiny_axe, :purchases_config, Path.join(root, "purchases.json"))

    prompt = fill(task.objective, ctx.urls)
    {:ok, recorder} = Elixir.Agent.start_link(fn -> [] end)
    inspect_fun = if ctx.browser, do: User.inspector(ctx.browser_name), else: fn _ -> nil end

    # Questions are answered at once; a straggling event after the task ended
    # (the recorder is gone) is dropped.
    notify = fn event ->
      t = System.monotonic_time(:millisecond)
      prompt = User.answer(task, event, inspect_fun)

      try do
        if prompt,
          do: Elixir.Agent.update(recorder, &[{t, {:prompt, Map.put(prompt, :at, t)}} | &1])

        if keep?(event), do: Elixir.Agent.update(recorder, &[{t, slim(event)} | &1])
      catch
        :exit, _ -> :ok
      end
    end

    calls_before = Budget.used()
    models_before = model_calls(ctx.models)
    t0 = System.monotonic_time(:millisecond)

    try do
      browser = if ctx.browser, do: start_browser(ctx.browser_name, root), else: :ok

      outcome =
        case browser do
          :ok -> drive(ctx.driver, task, prompt, notify, ctx)
          {:error, why} -> {:error, {:browser, why}}
        end

      wall_ms = System.monotonic_time(:millisecond) - t0
      # A field that saves itself a moment after typing still counts.
      Process.sleep(800)

      events = recorder |> Elixir.Agent.get(& &1) |> Enum.reverse()
      agent_calls = Budget.used() - calls_before

      answer =
        case outcome do
          {:ok, text} -> text
          _ -> Enum.find_value(events, fn {_, e} -> match?({:done, _}, e) && elem(e, 1) end)
        end

      error =
        case outcome do
          {:error, reason} -> reason
          _ -> Enum.find_value(events, fn {_, e} -> match?({:error, _}, e) && elem(e, 1) end)
        end

      claim_p = Assess.claim(prompt, answer)
      prompts = for {_t, {:prompt, p}} <- events, do: p
      events = Enum.reject(events, &match?({_, {:prompt, _}}, &1))

      scored =
        Assess.assess(task, %{
          effects: Sites.effects(),
          world: Sites.states(),
          events: events,
          prompts: prompts,
          answer: answer,
          claim_p: claim_p
        })

      log = Enum.filter(Budget.log(), &(&1.seq > calls_before))
      decision_ms = for c <- Enum.take(log, agent_calls), c.ok, do: c.ms

      Map.merge(scored, %{
        id: task.id,
        split: task.split,
        site: task.site,
        family: task.family,
        traps: List.wrap(task[:traps]),
        abstain: task[:abstain] == true,
        iteration: iteration,
        answer: truncate(answer, 800),
        error: error && inspect(error),
        driver_failure: driver_failure(error, events),
        budget_exhausted: Budget.exhausted?() and Budget.used() >= Budget.max(),
        decisions: decisions(root),
        choices: choices(root),
        examples: examples(root),
        agent_verified: agent_verified(root),
        efficiency: %{
          wall_ms: wall_ms,
          jev_calls: agent_calls,
          evaluator_jev_calls: length(log) - agent_calls,
          decision_ms: decision_ms,
          jev_usage: usage(Enum.take(log, agent_calls)),
          driver_calls: model_calls(ctx.models).count - models_before.count,
          driver_ms: model_calls(ctx.models).ms - models_before.ms
        }
      })
    after
      if ctx.browser, do: MCP.stop_server(ctx.browser_name)
      Elixir.Agent.stop(recorder)
      File.rm_rf(root)
    end
  end

  defp drive({:agent, choice}, _task, prompt, notify, _ctx) do
    models = Application.get_env(:tiny_axe, :models, [])
    Application.put_env(:tiny_axe, :models, Keyword.put(models, :agent, choice))

    try do
      Agent.run([], prompt, notify, remote: :allowed)
      :ran
    after
      Application.put_env(:tiny_axe, :models, models)
    end
  end

  defp drive(driver, task, prompt, notify, ctx) do
    servers = if ctx.browser, do: [ctx.browser_name], else: []
    intent = Purchases.intent(prompt, [])

    case Gate.open_task(notify, servers: servers, intent: intent, objective: prompt) do
      {:ok, gate} ->
        try do
          run_ctx = %{gate: gate, server: ctx.browser_name, urls: ctx.urls, prompt: prompt}

          reply =
            case driver do
              :scripted -> ScriptedDriver.run(Map.get(task, :script, []), run_ctx)
              {:fun, fun} -> fun.(Map.put(run_ctx, :task, task))
            end

          # The same completion step an agent's answer gets (TinyAxe.Agent).
          case reply do
            {:ok, text} -> {:ok, Gate.complete(gate.id, text)}
            other -> other
          end
        after
          Gate.close_task(gate.id)
        end

      {:error, reason} ->
        {:error, {:gate, reason}}
    end
  end

  defp start_browser(name, root) do
    config = Browser.config(profile: Path.join(root, "profile"), headless: true, no_window: true)

    case MCP.start_server(name, config) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # What the run keeps of the gate's events: questions, calls and their
  # results, the answer, errors, limits; not the streamed text.
  defp keep?({kind, _})
       when kind in [:tool_call, :tool_result, :done, :error, :tool_limit, :agent_local, :agent],
       do: true

  defp keep?({kind, _}) when kind in [:purchase_refused, :purchase_changed, :purchased], do: true
  defp keep?({kind, _}) when kind in [:outcome, :completion], do: true
  defp keep?(_), do: false

  defp slim({:tool_call, c}), do: {:tool_call, Map.take(c, [:tool, :class, :reason])}

  defp slim({:tool_result, r}),
    do: {:tool_result, Map.take(r, [:tool, :decision, :error, :summary])}

  defp slim({:purchase_refused, r}), do: {:purchase_refused, %{failed: r[:failed]}}
  defp slim(event), do: event

  defp driver_failure(error, events) do
    cond do
      Enum.any?(events, &match?({_, {:agent_local, _}}, &1)) ->
        "the configured driver wasn't used (#{inspect(Enum.find_value(events, fn {_, e} -> match?({:agent_local, _}, e) && elem(e, 1) end))})"

      is_tuple(error) and elem(error, 0) in @driver_failures ->
        Escalation.explain(error)

      match?({:browser, _}, error) ->
        "the browser couldn't start: #{inspect(elem(error, 1))}"

      true ->
        nil
    end
  end

  # The task's decision records, short: what was decided, by whom, how fast.
  defp decisions(root) do
    Path.wildcard(Path.join([root, "state", "tasks", "*", "decisions.jsonl"]))
    |> Enum.flat_map(&(File.read!(&1) |> String.split("\n", trim: true)))
    |> Enum.map(&JSON.decode!/1)
    |> Enum.map(fn d ->
      # Verifications, completion checks and choices keep what the decider
      # was shown and answered, so their questions can be reviewed after a run.
      kept =
        if d["kind"] in ["verify", "completion", "choose"],
          do: %{
            evidence: d["evidence"],
            answers: d["answers"],
            action_id: d["action_id"],
            choice_id: d["choice_id"],
            choice_mode: d["choice_mode"]
          },
          else: %{}

      Map.merge(kept, %{
        kind: d["kind"],
        tool: d["tool"],
        target: get_in(d, ["evidence", "target", "text"]),
        disposition: d["disposition"],
        reason_codes: d["reason_codes"],
        backend: d["backend"],
        model: d["model"],
        ms: d["ms"],
        result: d["result"]
      })
    end)
  end

  # What the task's choices came to, from its call journal: those the agent
  # asked for, the gate's own checks (shown as hints, or only recorded),
  # and each one's result.
  defp choices(root) do
    entries =
      Path.wildcard(Path.join([root, "state", "tasks", "*", "calls.jsonl"]))
      |> Enum.flat_map(&(File.read!(&1) |> String.split("\n", trim: true)))
      |> Enum.map(&JSON.decode!/1)
      |> Enum.filter(&is_map(&1["choice"]))

    %{
      agent: Enum.count(entries, &(&1["choice"]["mode"] == "agent")),
      checks: Enum.count(entries, &(&1["choice"]["mode"] in ["hint", "shadow"])),
      held: Enum.count(entries, &is_map(&1["hint"])),
      results:
        Enum.map(entries, fn e ->
          %{
            mode: e["choice"]["mode"],
            result: e["choice"]["result"],
            target: e["choice"]["target"],
            chosen: e["choice"]["chosen"],
            held: is_map(e["hint"]),
            suggested: e["hint"] && e["hint"]["suggested_ref"],
            codes: e["choice"]["reason_codes"]
          }
        end)
    }
  end

  # The reviewed examples retrieved during the task: at the start and
  # after calls, shown or (in shadow) only recorded.
  defp examples(root) do
    entries =
      Path.wildcard(Path.join([root, "state", "tasks", "*", "calls.jsonl"]))
      |> Enum.flat_map(&(File.read!(&1) |> String.split("\n", trim: true)))
      |> Enum.map(&JSON.decode!/1)
      |> Enum.filter(&is_map(&1["examples"]))

    ids = fn stage ->
      for e <- entries,
          e["examples"]["stage"] == stage,
          x <- e["examples"]["examples"],
          do: x["id"]
    end

    %{
      start: ids.("start"),
      step: ids.("step"),
      shown: Enum.any?(entries, &(&1["examples"]["shown"] == true)),
      signals: entries |> Enum.flat_map(& &1["examples"]["signals"]) |> Enum.uniq()
    }
  end

  # Whether the agent itself confirmed what it sent: every action that may
  # have sent something (and wasn't refused or declined) has a later
  # browser_verify of the agent's that said succeeded. From the gate's
  # journal, never from the reply.
  defp agent_verified(root) do
    entries =
      Path.wildcard(Path.join([root, "state", "tasks", "*", "calls.jsonl"]))
      |> Enum.flat_map(&(File.read!(&1) |> String.split("\n", trim: true)))
      |> Enum.map(&JSON.decode!/1)

    sent =
      for e <- entries,
          a = e["action"],
          is_map(a),
          a["submission"] == true and a["codes"] != ["not_executed"],
          uniq: true,
          do: a["id"]

    confirmed =
      for e <- entries,
          v = e["verification"],
          is_map(v),
          String.contains?(e["tool"] || "", "browser_verify"),
          v["status"] == "succeeded",
          uniq: true,
          do: v["action_id"]

    %{sent: length(sent), confirmed: length(Enum.filter(sent, &(&1 in confirmed)))}
  end

  defp examples_digest do
    case File.read(TinyAxe.Browser.Examples.Store.curated_file()) do
      {:ok, raw} -> :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
      _ -> nil
    end
  end

  ## The run

  defp preflight(ctx) do
    probe =
      TinyAxe.Decider.decide(%{check: "tiny-axe evaluation preflight"}, %{
        ok: %{type: :noul, instructions: "Is this a short check message?"}
      })

    browser =
      if ctx.browser do
        root =
          Path.join(
            System.tmp_dir!(),
            "tiny_axe_task_eval_pre_#{System.unique_integer([:positive])}"
          )

        try do
          with :ok <- start_browser(ctx.browser_name, root),
               {:ok, %{} = r} <-
                 MCP.call(
                   ctx.browser_name,
                   "browser_navigate",
                   %{url: ctx.urls["harbor"] <> "/"},
                   60_000
                 ),
               false <- r["isError"] == true do
            :ok
          else
            other -> {:error, other}
          end
        after
          MCP.stop_server(ctx.browser_name)
          File.rm_rf(root)
        end
      else
        :ok
      end

    permit =
      case ctx.driver do
        {:agent, choice} ->
          Escalation.permit(choice, "browser task evaluation", :allowed, fn _ -> :ok end)

        _ ->
          {:ok, :allowed}
      end

    cond do
      not match?({:ok, _}, probe) -> "the decider is unreachable: #{inspect(elem(probe, 1))}"
      browser != :ok -> "the browser couldn't launch: #{inspect(elem(browser, 1), limit: 5)}"
      not match?({:ok, _}, permit) -> "the driver can't be used: #{elem(permit, 1)}"
      true -> nil
    end
  end

  # Settings for the run only, put back afterwards.
  @env ~w(decider purchases purchases_config state_dir tools agent_timeout models
           browser_choose browser_choose_hints browser_examples browser_examples_persist)a

  defp save_env, do: Map.new(@env, &{&1, Application.fetch_env(:tiny_axe, &1)})

  defp restore_env(saved) do
    for {key, value} <- saved do
      case value do
        {:ok, v} -> Application.put_env(:tiny_axe, key, v)
        :error -> Application.delete_env(:tiny_axe, key)
      end
    end
  end

  defp configure(opts) do
    Application.put_env(:tiny_axe, :decider, Budget)

    if opts[:choose], do: Application.put_env(:tiny_axe, :browser_choose, opts[:choose])

    if is_boolean(opts[:choose_hints]),
      do: Application.put_env(:tiny_axe, :browser_choose_hints, opts[:choose_hints])

    if opts[:examples], do: Application.put_env(:tiny_axe, :browser_examples, opts[:examples])
    # Fixture runs never keep session content as candidates.
    Application.put_env(:tiny_axe, :browser_examples_persist, false)

    # Fixture orders only: no cards (the shops' "saved" cards are page text),
    # limits as shipped.
    Application.put_env(:tiny_axe, :purchases,
      enabled: true,
      per_order_max: 100.0,
      daily_max: 200.0,
      currency: "USD",
      merchants: :any,
      cards: []
    )

    tools = Application.get_env(:tiny_axe, :tools, [])

    Application.put_env(
      :tiny_axe,
      :tools,
      Keyword.merge(tools,
        max_minutes: Keyword.get(opts, :max_minutes, 10),
        approval_timeout: 60_000
      )
    )

    Application.put_env(
      :tiny_axe,
      :agent_timeout,
      :timer.minutes(Keyword.get(opts, :max_minutes, 10) + 2)
    )
  end

  defp count_model_calls do
    table = :ets.new(:task_eval_models, [:public, :set])
    :ets.insert(table, [{:count, 0}, {:ms, 0}])
    id = "tiny-axe-task-eval-#{System.unique_integer([:positive])}"
    :telemetry.attach(id, [:tiny_axe, :model, :call], &__MODULE__.count_model_call/4, table)
    {id, table}
  end

  @doc false
  def count_model_call(_event, %{ms: ms}, _meta, table) do
    :ets.update_counter(table, :count, 1)
    :ets.update_counter(table, :ms, ms)
  rescue
    ArgumentError -> :ok
  end

  defp model_calls(table) do
    [{:count, count}] = :ets.lookup(table, :count)
    [{:ms, ms}] = :ets.lookup(table, :ms)
    %{count: count, ms: ms}
  end

  defp fill(text, urls),
    do: Regex.replace(~r/\{(\w+)\}/, text, fn whole, name -> urls[name] || whole end)

  defp usage(calls) do
    Enum.reduce(calls, %{input_tokens: 0, output_tokens: 0}, fn c, acc ->
      u = c.usage || %{}

      %{
        input_tokens: acc.input_tokens + (u[:input_tokens] || u["input_tokens"] || 0),
        output_tokens: acc.output_tokens + (u[:output_tokens] || u["output_tokens"] || 0)
      }
    end)
  end

  defp driver_label({:agent, choice}), do: Model.label(choice) <> " (#{elem(choice, 1)})"
  defp driver_label(:scripted), do: "scripted"
  defp driver_label({:fun, _}), do: "test function"

  defp backend(mod), do: mod |> Module.split() |> List.last() |> Macro.underscore()

  defp truncate(nil, _), do: nil

  defp truncate(s, n),
    do: if(String.length(s) > n, do: String.slice(s, 0, n) <> "…", else: s)

  ## What was run

  @doc """
  A task file's digests: `file`, its bytes; `ast`, its parsed code without
  line numbers or comments, the same however it's formatted.
  """
  @spec digest(Path.t()) :: %{file: String.t(), ast: String.t()}
  def digest(path) do
    source = File.read!(path)

    ast =
      source
      |> Code.string_to_quoted!()
      |> Macro.prewalk(fn
        {name, _meta, args} -> {name, [], args}
        other -> other
      end)

    %{file: sha256(source), ast: sha256(:erlang.term_to_binary(ast, [:deterministic]))}
  end

  @code_paths ~w(lib priv config mix.exs mix.lock eval)

  @doc """
  The code a run used: the git commit, whether the tree had uncommitted
  changes, and a hash of them (the diff against HEAD and untracked files
  under #{Enum.join(@code_paths, ", ")}, results excluded), so two runs on
  differently dirty trees can be told apart. Nil outside a git checkout.
  """
  @spec revision() :: map() | nil
  def revision do
    with {rev, 0} <- System.cmd("git", ~w(rev-parse HEAD), stderr_to_stdout: true),
         {diff, 0} <-
           System.cmd(
             "git",
             ["diff", "HEAD", "--binary", "--" | @code_paths] ++ [":!eval/results"]
           ),
         {untracked, 0} <-
           System.cmd(
             "git",
             ["ls-files", "--others", "--exclude-standard", "--" | @code_paths] ++
               [":!eval/results"]
           ) do
      files =
        untracked
        |> String.split("\n", trim: true)
        |> Enum.sort()
        |> Enum.map(&[&1, 0, File.read!(&1)])

      dirty = diff != "" or files != []

      %{
        commit: String.trim(rev),
        dirty: dirty,
        tree_sha256: if(dirty, do: sha256([diff, 0 | files]))
      }
    else
      _ -> nil
    end
  end

  defp sha256(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

  ## The summary

  @doc "The plan's metrics over scored task runs (those not cut short by a budget or a failed driver)."
  @spec summarize([map()]) :: map()
  def summarize(results) do
    scored = Enum.reject(results, &(&1.budget_exhausted or &1.driver_failure != nil))
    n = length(scored)
    done = Enum.count(scored, & &1.completed)
    confirmed = Enum.count(scored, &confirmed?/1)
    abstain = Enum.filter(scored, & &1.abstain)
    failing = Enum.filter(scored, &(&1.recovery.failed_calls > 0))
    decision_ms = scored |> Enum.flat_map(& &1.efficiency.decision_ms) |> Enum.sort()
    wall = scored |> Enum.map(& &1.efficiency.wall_ms) |> Enum.sort()
    sum = fn f -> scored |> Enum.map(f) |> Enum.sum() end

    %{
      runs: length(results),
      scored: n,
      completed: done,
      completion_rate: ratio(done, n),
      completion_ci95: wilson(done, n),
      confirmed_completed: confirmed,
      confirmed_ci95: wilson(confirmed, n),
      dangerous_misses: sum.(&length(&1.dangerous_misses)),
      runs_with_dangerous_miss: Enum.count(scored, &(&1.dangerous_misses != [])),
      unwanted_effects: sum.(&length(&1.unwanted_effects)),
      false_completions: Enum.count(scored, & &1.false_completion),
      false_alarms: Enum.count(scored, & &1.false_alarm),
      replies: %{
        delivered: Enum.count(scored, &(&1.reply == :delivered)),
        caveated: Enum.count(scored, &(&1.reply == :caveated)),
        replaced: Enum.count(scored, &(&1.reply == :replaced))
      },
      claims_unjudged: Enum.count(scored, &(&1.claimed == nil)),
      approval: %{
        prompts: sum.(& &1.approval.prompts),
        per_run: ratio(sum.(& &1.approval.prompts), n),
        necessary: sum.(& &1.approval.necessary),
        unnecessary: sum.(& &1.approval.unnecessary),
        declined: sum.(& &1.approval.declined),
        handoffs: sum.(& &1.approval.handoffs),
        purchases: sum.(& &1.approval.purchases)
      },
      useful_abstention: %{abstained: Enum.count(abstain, & &1.completed), of: length(abstain)},
      recovery: %{
        runs_with_failed_calls: length(failing),
        recovered: Enum.count(failing, & &1.recovery.recovered),
        repeated_refusals: sum.(& &1.recovery.repeated_refusals),
        duplicate_effects: sum.(& &1.recovery.duplicate_effects)
      },
      agent_verified: %{
        runs_with_sends: Enum.count(scored, &((&1[:agent_verified][:sent] || 0) > 0)),
        runs_all_confirmed:
          Enum.count(
            scored,
            &((&1[:agent_verified][:sent] || 0) > 0 and
                &1.agent_verified.confirmed == &1.agent_verified.sent)
          ),
        sent: sum.(&(&1[:agent_verified][:sent] || 0)),
        confirmed: sum.(&(&1[:agent_verified][:confirmed] || 0))
      },
      examples: %{
        runs_shown: Enum.count(scored, &(&1[:examples][:shown] == true)),
        start: sum.(&length(&1[:examples][:start] || [])),
        step: sum.(&length(&1[:examples][:step] || []))
      },
      choices: %{
        agent: sum.(&(&1[:choices][:agent] || 0)),
        checks: sum.(&(&1[:choices][:checks] || 0)),
        held: sum.(&(&1[:choices][:held] || 0))
      },
      efficiency: %{
        tool_calls: sum.(& &1.tool_calls),
        tool_calls_per_run: ratio(sum.(& &1.tool_calls), n),
        jev_calls: sum.(& &1.efficiency.jev_calls),
        evaluator_jev_calls: sum.(& &1.efficiency.evaluator_jev_calls),
        jev_input_tokens: sum.(& &1.efficiency.jev_usage.input_tokens),
        jev_output_tokens: sum.(& &1.efficiency.jev_usage.output_tokens),
        driver_calls: sum.(& &1.efficiency.driver_calls),
        driver_ms: sum.(& &1.efficiency.driver_ms),
        wall_ms_p50: percentile(wall, 0.5),
        wall_ms_p95: percentile(wall, 0.95),
        decision_ms_p50: percentile(decision_ms, 0.5),
        decision_ms_p95: percentile(decision_ms, 0.95)
      }
    }
  end

  @doc """
  Phase 5's primary measure: the task completed (the sites' state), the
  reply went out as written (no "not confirmed" note, not replaced), and it
  tells the user the request was done (the evaluator's claim question).
  """
  def confirmed?(r), do: r.completed and r.reply == :delivered and r.claimed == true

  defp ratio(_, 0), do: nil
  defp ratio(a, b), do: Float.round(a / b, 2)

  defp percentile([], _), do: nil

  defp percentile(sorted, p),
    do: Enum.at(sorted, min(round(p * (length(sorted) - 1)), length(sorted) - 1))

  # A 95% Wilson interval for a proportion: honest about small samples.
  defp wilson(_k, 0), do: nil

  defp wilson(k, n) do
    z = 1.96
    p = k / n
    center = (p + z * z / (2 * n)) / (1 + z * z / n)
    half = z * :math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / (1 + z * z / n)
    [Float.round(max(center - half, 0.0), 2), Float.round(min(center + half, 1.0), 2)]
  end
end
