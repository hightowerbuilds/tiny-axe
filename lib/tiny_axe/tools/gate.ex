defmodule TinyAxe.Tools.Gate do
  @moduledoc """
  The one way an agent reaches a tool. It's an MCP server that tiny-axe runs
  itself (on 127.0.0.1, `TinyAxe.Tools.GatePlug`), offering the tools of the
  connected MCP servers (`TinyAxe.MCP`). Each driver task (Claude Code, Codex,
  tiny-axe's own loop) gets its own address and token, and sees nothing else.

  Every call:

    1. **limits** — at most `:max_calls` calls and `:max_minutes` per task, and
       never the same call three times in a row; a call missing a required
       argument goes back to the agent
    2. **class** — `TinyAxe.Tools.Policy` decides read, local, outward, commit
       or refused; the model never does. Every browser action is assessed by
       `TinyAxe.Browser.Decisions` (the same checks as the gate-owned
       `browser_assess` tool, which agents may call first), bound to its
       target, and checked again by the browser just before it acts
    3. **approval** — an outward call waits for the user (`{:tool_approval, ...}`,
       answered with `{:tool_answer, ref, :once | :session | :deny}`), unless
       they allowed that tool for the session; commits are refused until the
       purchase gate exists
    4. **forward** to the server, then **redact** the result
    5. **journal** the call, and report it to the task (`{:tool_call, ...}`);
       each browser decision behind it goes to the task's decision trace
       (`TinyAxe.Tools.Journal.append_decision/2`) with what happened next,
       and the call's entry names its assessment
    6. **outcome** — a browser action that can change something gets a
       record (`TinyAxe.Browser.Outcomes`): the browser reports what it did,
       and anything that may have been sent but can't be confirmed stays
       unresolved, so the same action isn't sent again. The gate-owned
       `browser_verify` tool checks an outcome against a fresh look at the
       page, and `complete/2` checks an agent's answer against the records
       before it reaches the user (`{:outcome, ...}`, `{:completion, ...}`)
    7. **choice** — while choosing is on, the gate-owned `browser_choose`
       tool says which of several similar elements fits the request
       (`TinyAxe.Browser.Choices`). In shadow, or on with hints, a click on
       a control whose label other controls on the page share is first
       checked the same way: recorded, and with hints, held once with a
       `choose_hint` when its target clearly doesn't fit. Advice only:
       nothing it says runs or approves anything
    8. **examples** — after a browser call, the harness's own facts about it
       (reason codes, what an action came to, what verification said, the
       user saying no) retrieve a few reviewed examples
       (`TinyAxe.Browser.Examples`), recorded in the journal and, when
       retrieval is on, added to the call's result with the task's failed
       and unresolved actions so far. Advice only: it's done after the call
       was decided, and nothing in an example reaches a decision

  Each task leases its own browser tabs (`TinyAxe.Browser.bind/3`); closing
  the task frees them for the next one.

  A top-level agent task driven by Claude or Codex is also offered the
  gate-owned `dispatch_agents` tool (`TinyAxe.Agent.Dispatch`): independent
  parts of the request handed to sub-agents, each with a gate task of its
  own (`:depth` 1), which is never offered it.

  Every agent task, once its driver is known, is also offered the gate-owned
  `shell_run` tool (`TinyAxe.Agent.ShellTool`): commands that only look run
  at once, read-only; any other is asked about every time, never for the
  session.

  A task opened with `chrome: true` and driven by Claude also answers
  Claude Code's permission questions for the user's own Chrome (Claude in
  Chrome, `TinyAxe.Chrome`): the gate-owned `chrome_permission` tool (Claude
  Code's `--permission-prompt-tool`) decides each Chrome call (reads run,
  acts run on sites the user allowed for the task or wait for their yes,
  order-placing clicks are held, some are refused), and `observe/2` takes in
  what each Chrome call showed (from a `PostToolUse` hook, `POST /hook/<task>`),
  so the gate knows each tab's address and what each ref is.

  A refusal comes back to the agent as a tool error saying why, so it can
  carry on or tell the user.
  """

  use GenServer

  require Logger

  alias TinyAxe.{Browser, Chrome, MCP, Ops, Purchases, Tools}
  alias TinyAxe.Agent.{Dispatch, ShellTool, SiteTool}
  alias TinyAxe.Browser.{Choices, Decisions, Examples, Outcomes}
  alias TinyAxe.Tools.{Policy, Redact}

  @http TinyAxe.Tools.GateHTTP

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc """
  Opens a task: its own address and token for the driver. `notify` gets the
  task's events (and approval questions). `opts`: `:servers` (`:all` or a
  list of names), `:max_calls`, `:max_minutes`, `:intent`, what the user
  asked to buy, if anything (`TinyAxe.Purchases.intent/2`), `:objective`,
  the user's request, which browser decisions are shown as the task, and
  for a sub-agent's task, `:depth` (1) and `:parent` (the parent task's id).
  """
  @spec open_task((term() -> any()), keyword()) :: {:ok, map()} | {:error, term()}
  def open_task(notify, opts \\ []) do
    with {:ok, port} <- port() do
      id =
        "#{Calendar.strftime(DateTime.utc_now(), "%Y%m%d-%H%M%S")}-#{System.unique_integer([:positive])}"

      token = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
      limits = Application.get_env(:tiny_axe, :tools, [])

      task = %{
        id: id,
        token: token,
        notify: notify,
        # The process that opened it: if it dies (a cancelled run is killed),
        # the task is closed all the same.
        owner: self(),
        servers: Keyword.get(opts, :servers, :all),
        max_calls: Keyword.get(opts, :max_calls, limits[:max_calls] || 60),
        deadline:
          System.monotonic_time(:millisecond) +
            :timer.minutes(Keyword.get(opts, :max_minutes, limits[:max_minutes] || 30)),
        calls: 0,
        recent: [],
        allowed: MapSet.new(),
        intent: Keyword.get(opts, :intent),
        objective: opts |> Keyword.get(:objective) |> then(&(&1 && Redact.text(&1))),
        # 0 for an agent's own task, 1 for a sub-agent's; and who drives it
        # (driven_by/2): together they say whether dispatch_agents is offered.
        depth: Keyword.get(opts, :depth, 0),
        parent: Keyword.get(opts, :parent),
        driver: nil,
        # The latest calls and what the gate did, newest last, for decisions.
        outcomes: [],
        # Its browser assessments, for reuse and held restrictions
        # (Decisions.remember/2), and the browser servers whose tabs it holds.
        assessments: [],
        floors: %{},
        leased: MapSet.new(),
        # What its browser actions came to (Outcomes), newest first.
        actions: [],
        # The gate's own candidate checks before ambiguous clicks, by server,
        # observation and target signature: :held (shown once) or :passed.
        candidate_checks: %{},
        # Reviewed examples retrieved for it (TinyAxe.Browser.Examples), by
        # id: at the start (the system prompt) and after its calls.
        examples: %{start: [], step: []},
        # Marks the examples tiny-axe adds to results, which no page can know.
        examples_nonce: Examples.nonce(),
        # The user's own Chrome (TinyAxe.Chrome), when Claude drives: what the
        # gate has seen of it, and the sites the user allowed for this task.
        chrome: Keyword.get(opts, :chrome, false),
        chrome_seen: Chrome.new(),
        chrome_sites: MapSet.new()
      }

      :ok = GenServer.call(__MODULE__, {:open, task})
      # Never prunes the folder of a task that's still open.
      Tools.Journal.start(id, GenServer.call(__MODULE__, :open_ids))

      {:ok,
       %{
         id: id,
         token: token,
         url: "http://127.0.0.1:#{port}/mcp/#{id}",
         hook_url: "http://127.0.0.1:#{port}/hook/#{id}",
         chrome: task.chrome
       }}
    end
  end

  @doc """
  Closes a task; the browser tabs it held stay open, free for the next task.
  With `:browser_examples_persist` on (off by default), its lesson-worthy
  browser actions are kept as unvalidated candidates
  (`TinyAxe.Browser.Examples.capture/2`).
  """
  @spec close_task(String.t()) :: :ok
  def close_task(id) do
    case GenServer.call(__MODULE__, {:close, id}) do
      %{leased: leased} = task ->
        Enum.each(leased, &Browser.release(&1, id))
        capture(task)

      _ ->
        :ok
    end

    TinyAxe.Vault.task_closed(id)
  end

  defp capture(task) do
    if Examples.persist?(), do: Examples.capture(task)
  rescue
    error -> Logger.warning("tiny-axe couldn't keep this task's examples: #{inspect(error)}")
  end

  @doc """
  Reviewed examples for the start of a task with a browser, by the
  workflow its request names (`TinyAxe.Browser.Examples`): text for the
  shared system prompt when retrieval is on (with the task's nonce, which
  marks the examples added to results), "" otherwise. Retrieved and
  journaled in shadow too. Never raises: bad example data means no
  examples, never a failed task.
  """
  @spec briefing(String.t()) :: String.t()
  def briefing(id) do
    mode = Examples.mode()

    with true <- mode != :off,
         %{} = task <- GenServer.call(__MODULE__, {:get, id}),
         true <- Enum.any?(MCP.tools(task.servers), &browser?/1) do
      picked = Examples.retrieve(%{stage: :start, objective: task.objective})

      if picked != [] do
        :ok = GenServer.call(__MODULE__, {:examples, id, :start, Enum.map(picked, & &1["id"])})

        Tools.Journal.append(id, %{
          tool: "tiny-axe/examples",
          examples: Examples.journal(mode, :start, [], picked)
        })
      end

      if mode == :on, do: Examples.briefing(picked, task.examples_nonce), else: ""
    else
      _ -> ""
    end
  rescue
    error ->
      Logger.warning("tiny-axe left out this task's examples: #{Exception.message(error)}")
      ""
  end

  @doc """
  Records which model drives a task. Returns whether the task is offered
  `dispatch_agents`: only an agent's own task (not a sub-agent's), driven by
  Claude or Codex (the local model is weak at long chains, and one GPU runs
  one request at a time anyway).
  """
  @spec driven_by(String.t(), TinyAxe.Model.choice()) :: boolean()
  def driven_by(id, choice), do: GenServer.call(__MODULE__, {:driver, id, choice})

  defp dispatches?(%{depth: 0, driver: driver}) when driver != nil,
    do: TinyAxe.Model.remote?(driver)

  defp dispatches?(_task), do: false

  defp shells?(%{driver: driver}) when driver != nil, do: ShellTool.available?()
  defp shells?(_task), do: false

  @doc "The MCP config that gives a driver this task's gate and nothing else."
  @spec mcp_config(map()) :: map()
  def mcp_config(%{url: url, token: token}) do
    %{
      "mcpServers" => %{
        "tinyaxe" => %{
          "type" => "http",
          "url" => url,
          "headers" => %{"Authorization" => "Bearer #{token}"}
        }
      }
    }
  end

  @doc false
  # The task for an id and bearer token, compared in constant time.
  def authorize(id, token) do
    case GenServer.call(__MODULE__, {:get, id}) do
      %{token: expected} = task when is_binary(token) ->
        if Plug.Crypto.secure_compare(expected, token), do: {:ok, task}, else: :error

      _ ->
        :error
    end
  end

  @doc """
  The tools a task may use, as MCP tool definitions: its servers' tools, and
  with a browser, the gate's own `browser_assess` and `browser_verify` (and
  `browser_choose` while choosing is on), `dispatch_agents` when the task
  is offered it (`driven_by/2`), and `shell_run` once a driver drives it.
  """
  @spec tools(map()) :: [map()]
  def tools(task) do
    all = MCP.tools(task.servers)

    listed =
      for t <- all,
          not hidden?(t),
          Policy.classify(t.definition, t.policy) != :refused do
        Map.take(t.definition, ["description", "inputSchema", "annotations", "title"])
        |> Map.put("name", t.name)
      end

    listed = if Enum.any?(all, &browser?/1), do: listed ++ Decisions.definitions(), else: listed
    listed = if dispatches?(task), do: listed ++ [Dispatch.definition()], else: listed
    listed = if shells?(task), do: listed ++ [ShellTool.definition()], else: listed

    listed =
      if SiteTool.offered?(task.servers), do: listed ++ [SiteTool.definition()], else: listed

    if chrome?(task), do: listed ++ [Chrome.permission_definition()], else: listed
  end

  # The user's Chrome is Claude's only (claude -p --chrome).
  defp chrome?(task), do: task[:chrome] == true and match?({:claude, _}, task[:driver])

  @doc "Runs one tool call through the gate. Returns an MCP result."
  @spec call(map(), String.t(), map()) :: map()
  def call(task, "chrome_permission", args) do
    if chrome?(task),
      do: chrome_permission(task, args),
      else: do_call(task, "chrome_permission", args)
  end

  def call(task, name, args), do: do_call(task, name, args)

  defp do_call(task, name, args) do
    t0 = System.monotonic_time(:millisecond)
    tool = find(task, name)
    # The gate's own browser keys (tab lease, signatures) come from the gate.
    args = if tool && (browser?(tool) or gate?(tool)), do: Decisions.clean(args), else: args

    {class, judged, {decision, result}} =
      case tool && GenServer.call(__MODULE__, {:begin, task.id, name, args}) do
        nil ->
          {nil, %{}, {:refused, refusal("there's no tool called #{name}")}}

        {:limit, why} ->
          task.notify.({:tool_limit, %{task: task.id, reason: why}})
          {nil, %{}, {:refused, refusal(why)}}

        {:ok, allowed} ->
          # A call missing what the tool requires goes back to the agent to fix,
          # before anything is inspected or the user is asked.
          case missing(tool.definition, args) do
            [] ->
              {class, reason, task} = classify(task, tool, args)

              task.notify.(
                {:tool_call, %{tool: name, class: class, reason: reason, args: Redact.deep(args)}}
              )

              {class, task, decide(task, tool, args, {class, reason}, allowed)}

            keys ->
              {nil, %{}, {:refused, refusal("#{name} needs #{Enum.join(keys, ", ")}")}}
          end
      end

    assessment = judged[:assessment]
    verification = judged[:verification]
    choice = judged[:choice]
    {result, report} = take_report(result)
    action = settle(task, tool, args, assessment, decision, result, report)
    result = result |> note(action) |> Redact.result()

    {result, examples} =
      advise(task, tool, %{
        assessment: assessment,
        action: action,
        verification: verification,
        decision: decision,
        result: result
      })

    ms = System.monotonic_time(:millisecond) - t0
    error = result["isError"] == true

    traced =
      cond do
        assessment ->
          trace(task.id, assessment.decisions, assessment.binding.tool, decision, error)

        verification ->
          trace(task.id, verification.decisions, verification.action.tool, decision, error)

        true ->
          []
      end

    traced =
      if choice,
        do: traced ++ trace(task.id, choice.decisions, "browser_choose", decision, error),
        else: traced

    Tools.Journal.append(task.id, %{
      tool: name,
      args: Redact.deep(args),
      decision: decision,
      error: error,
      result: summary(result),
      assessment: Decisions.journal(assessment),
      action: Outcomes.journal(action),
      verification: Outcomes.journal_verification(verification),
      choice: Choices.journal(choice),
      hint: judged[:hint],
      examples: examples,
      decisions: traced,
      ms: ms
    })

    # Asking first leaves no trace in later decisions' recent actions, so an
    # assessed call and a direct one are judged on the same evidence.
    if tool && not gate?(tool) do
      GenServer.cast(
        __MODULE__,
        {:outcome, task.id, %{tool: tool.tool, class: class, decision: decision, error: error}}
      )
    end

    task.notify.(
      {:tool_result,
       %{
         tool: name,
         decision: decision,
         error: result["isError"] == true,
         summary: summary(result)
       }}
    )

    result
  end

  # Reviewed examples for what this browser call came to: retrieved from
  # the harness's own facts (never page text), after the call was decided,
  # so nothing here can change it. Shown only when retrieval is on, as an
  # item of its own marked with the task's nonce; page text imitating one
  # is made harmless first. The action has already run and its journal
  # entry is still to be written, so nothing here may raise: on any error
  # the result goes back as it was.
  defp advise(task, tool, facts) do
    mode = Examples.mode()

    with true <- mode != :off and tool != nil and (browser?(tool) or gate?(tool)),
         %{} = now <- GenServer.call(__MODULE__, {:get, task.id}) do
      page = if mode == :on, do: neutralise(facts.result), else: facts.result

      case Examples.signals(facts) do
        [] ->
          {page, nil}

        signals ->
          seen = now[:examples] || %{start: [], step: []}

          # Never one already shown in this task, at the start or after a call.
          picked =
            Examples.retrieve(%{
              stage: :step,
              objective: now[:objective],
              signals: signals,
              shown: seen.start ++ seen.step,
              total: length(Enum.uniq(seen.start ++ seen.step))
            })

          if picked != [],
            do:
              :ok =
                GenServer.call(
                  __MODULE__,
                  {:examples, task.id, :step, Enum.map(picked, & &1["id"])}
                )

          entry = Examples.journal(mode, :step, signals, picked)

          result =
            if mode == :on and picked != [],
              do:
                append(
                  page,
                  Examples.render(picked, Examples.attempts(now.actions), now.examples_nonce)
                ),
              else: page

          {result, entry}
      end
    else
      _ -> {facts.result, nil}
    end
  rescue
    error ->
      Logger.warning("tiny-axe left out examples for #{task.id}: #{Exception.message(error)}")
      {facts.result, nil}
  end

  defp neutralise(%{"content" => content} = result) when is_list(content) do
    %{
      result
      | "content" =>
          Enum.map(content, fn
            %{"text" => text} = item when is_binary(text) ->
              %{item | "text" => Examples.neutralise(text)}

            item ->
              item
          end)
    }
  end

  defp neutralise(result), do: result

  defp append(%{"content" => content} = result, text) when is_list(content),
    do: %{result | "content" => content ++ [%{"type" => "text", "text" => text}]}

  defp append(result, _text), do: result

  # Each decision record goes to the task's trace with what happened next;
  # returns their ids, for the call's journal entry.
  defp trace(id, records, tool, decision, error) do
    for record <- records do
      Tools.Journal.append_decision(
        id,
        Map.merge(record, %{task: id, tool: tool, result: %{decision: decision, error: error}})
      )

      record.id
    end
  end

  # The browser's report of what an action did, and the purchase gate's
  # receipt, are tiny-axe's own: taken off the result before the agent sees it.
  defp take_report(%{} = result) do
    {ours, result} = Map.split(result, ["_tinyaxe", "_tinyaxe_receipt"])

    {result,
     %{execution: get_in(ours, ["_tinyaxe", "action"]), receipt: ours["_tinyaxe_receipt"]}}
  end

  defp take_report(result), do: {result, %{}}

  # An action that can change something gets its record, settled from what
  # the browser reported; the task hears if it couldn't be confirmed.
  defp settle(_task, _tool, _args, nil, _decision, _result, _report), do: nil
  defp settle(_task, _tool, _args, %{action_id: nil}, _decision, _result, _report), do: nil

  defp settle(task, tool, args, assessment, decision, result, report) do
    record =
      Decisions.record(assessment, %{
        decision: decision,
        browser_tool: tool.tool,
        args: args,
        execution: report[:execution],
        receipt: report[:receipt],
        error_result: is_map(result) and result["isError"] == true
      })

    :ok = GenServer.call(__MODULE__, {:action, task.id, record})

    if record.status == :unresolved or
         (record.status == :failed and record.codes != ["not_executed"]),
       do: task.notify.({:outcome, outcome_event(record, :gate)})

    record
  end

  defp note(result, nil), do: result

  defp note(%{"content" => content} = result, action) when is_list(content) do
    case Decisions.note(action) do
      nil -> result
      text -> %{result | "content" => content ++ [%{"type" => "text", "text" => text}]}
    end
  end

  defp note(result, _action), do: result

  defp outcome_event(record, by),
    do: %{
      id: record.id,
      action: record.description,
      status: record.status,
      codes: record.codes,
      by: by
    }

  # The gate's own tools first; then the task's servers'.
  defp find(task, name) do
    tools = MCP.tools(task.servers)

    # Drivers may show the gate's own tools with their prefix.
    own = Decisions.listed_name(name)

    cond do
      own == Dispatch.name() and dispatches?(task) ->
        %{
          name: own,
          server: nil,
          tool: own,
          definition: Dispatch.definition(),
          policy: %{"gate" => true, "dispatch" => true}
        }

      own == ShellTool.name() and shells?(task) ->
        %{
          name: own,
          server: nil,
          tool: own,
          definition: ShellTool.definition(),
          policy: %{"gate" => true, "shell" => true}
        }

      own == SiteTool.name() and SiteTool.offered?(task.servers) ->
        %{
          name: own,
          server: nil,
          tool: own,
          definition: SiteTool.definition(),
          policy: %{"gate" => true, "site" => true}
        }

      Decisions.owns?(own) and Enum.any?(tools, &browser?/1) ->
        [definition] = for d <- Decisions.definitions(), d["name"] == own, do: d
        %{name: own, server: nil, tool: own, definition: definition, policy: %{"gate" => true}}

      true ->
        Enum.find(tools, &(&1.name == name))
    end
  end

  defp browser?(tool), do: tool.policy["browser"] == true
  defp gate?(tool), do: tool.policy["gate"] == true
  defp dispatch?(tool), do: tool.policy["dispatch"] == true
  defp shell?(tool), do: tool.policy["shell"] == true
  defp site?(tool), do: tool.policy["site"] == true

  # Browser actions are assessed by what they'd do on the page (the gate
  # looks first, with browser_inspect); other tools are classed by their
  # server's policy. `browser_assess` runs the same assessment as advice; it
  # can only assess a browser action, never itself.
  defp classify(task, tool, args) do
    cond do
      hidden?(tool) ->
        {:refused, "that tool is for tiny-axe only", task}

      # Starting work on this machine: runs without asking. The sub-agents'
      # own calls come through here like any other.
      dispatch?(tool) ->
        case Dispatch.parts(args) do
          {:ok, parts} -> {:local, "starts #{length(parts)} sub-agent(s) here", task}
          {:error, why} -> {:refused, why, task}
        end

      # A window on this computer, on the user's own page: runs without asking.
      site?(tool) ->
        {:local, "opens the user's page of tiny-axe's website in their browser", task}

      # Read-only runs at once; anything else asks (decide/5).
      shell?(tool) ->
        case ShellTool.check(args) do
          {:refused, why} -> {:refused, why, task}
          {class, reason, plan} -> {class, reason, Map.put(task, :shell, plan)}
        end

      gate?(tool) and tool.name == "browser_verify" ->
        case find_action(task.id, args["action_id"]) do
          nil ->
            {:refused,
             "there's no browser action #{if is_binary(args["action_id"]), do: args["action_id"] <> " ", else: ""}in this task to verify",
             task}

          record ->
            claim = if is_binary(args["claimed_outcome"]), do: args["claimed_outcome"]
            {:read, nil, Map.put(task, :verification, verify(task, record, claim, :agent))}
        end

      gate?(tool) and tool.name == "browser_choose" ->
        case Choices.refs(args["candidates"]) do
          {:error, why} ->
            {:refused, why, task}

          {:ok, refs} ->
            server = Enum.find_value(MCP.tools(task.servers), &(browser?(&1) && &1.server))
            choice = choose(task, server, refs, :agent, args)
            {:read, nil, Map.put(task, :choice, choice)}
        end

      gate?(tool) ->
        name = Decisions.listed_name(args["tool"])
        target = Enum.find(MCP.tools(task.servers), &(&1.name == name))
        proposed = arguments(args["arguments"])

        cond do
          target == nil or not browser?(target) or hidden?(target) ->
            {:refused, "browser_assess only assesses this task's browser actions", task}

          proposed == nil ->
            {:refused, "browser_assess needs the action's arguments as an object", task}

          (keys = missing(target.definition, Decisions.clean(proposed))) != [] ->
            {:refused, "#{target.name} needs #{Enum.join(keys, ", ")}", task}

          true ->
            assessment = assess(task, target, Decisions.clean(proposed), :advice, args)
            {:read, nil, Map.put(task, :assessment, assessment)}
        end

      browser?(tool) ->
        assessment = assess(task, tool, args, :execute, %{})

        # Held because something like it may already have gone through: only
        # the user can say to do it again, never the agent.
        repeat =
          "outcome_unresolved" in assessment.reason_codes and
            repeat_ok?(task, tool, args, assessment)

        assessment =
          if repeat,
            do: release(task, assessment) && assess(task, tool, args, :execute, %{}),
            else: assessment

        # The user has just said to do this very action again: nothing holds
        # it now, or the hold they lifted would be gone without it running.
        {assessment, choice, hint} =
          if repeat,
            do: {assessment, nil, nil},
            else: check_candidates(task, tool, args, assessment)

        task =
          task
          |> Map.put(:assessment, assessment)
          |> Map.put(:choice, choice)
          |> Map.put(:hint, hint)

        {assessment.class, assessment.reason, task}

      true ->
        {Policy.classify(tool.definition, tool.policy), nil, task}
    end
  end

  defp arguments(%{} = args), do: args

  defp arguments(json) when is_binary(json) do
    case JSON.decode(json) do
      {:ok, %{} = args} -> args
      _ -> nil
    end
  end

  defp arguments(_), do: nil

  # One assessment, bound to this task and its tabs, and remembered for it.
  defp assess(task, tool, args, mode, asked) do
    GenServer.cast(__MODULE__, {:leased, task.id, tool.server})
    record = GenServer.call(__MODULE__, {:assessments, task.id})

    assessment =
      Decisions.assess(
        %{
          task: task.id,
          server: tool.server,
          name: tool.name,
          tool: tool.tool,
          args: args,
          mode: mode,
          observation: asked["observation_id"],
          expected: asked["expected_effect"]
        },
        inspect: &look_at(task, tool.server, &1),
        context: %{
          objective: Map.get(task, :objective),
          intent: Map.get(task, :intent),
          recent: Map.get(task, :outcomes, [])
        },
        prior: record[:assessments],
        floors: record[:floors],
        unresolved: MapSet.union(Decisions.unresolved_keys(record[:actions] || []), held_keys()),
        purchases: Purchases.enabled?()
      )

    # Stored before the call returns, so the agent's next call sees it.
    :ok = GenServer.call(__MODULE__, {:assessed, task.id, assessment})
    assessment
  end

  defp look_at(task, server, ref) do
    args = Browser.bind(if(ref, do: %{"ref" => ref}, else: %{}), task.id)

    with {:ok, %{"content" => [%{"text" => json} | _]} = result} <-
           MCP.call(server, "browser_inspect", args, 15_000),
         false <- result["isError"] == true,
         {:ok, meta} <- JSON.decode(json) do
      meta
    else
      _ -> nil
    end
  end

  ## Choosing (TinyAxe.Browser.Choices)

  # One choice among elements on the task's tab, looked at afresh.
  defp choose(task, server, refs, mode, args) do
    Decisions.choose(
      %{
        task: task.id,
        server: server,
        mode: mode,
        refs: refs,
        observation: args["observation_id"],
        subgoal: args["subgoal"]
      },
      inspect: &look_at(task, server, &1),
      more: fn -> extract(task, server) end,
      context: %{objective: Map.get(task, :objective), intent: Map.get(task, :intent)}
    )
  end

  # Before a click on a control whose label others on the page share: the
  # same choice, made by the gate, once per element (its ref and signature:
  # same-label controls share a signature, never a ref) and observation. In
  # shadow it's only recorded; on with hints, a target that clearly doesn't
  # fit is held once (nothing runs; its record says so), and repeating the
  # call goes ahead with the usual checks. Only for local and outward
  # clicks: refused, purchase and handoff classes keep their own paths. The
  # page is described without a snapshot, so the agent's refs are untouched
  # unless a hint is about to name one.
  defp check_candidates(task, tool, args, assessment) do
    ref = args["ref"]
    key = {tool.server, assessment.binding.observation, ref, assessment.binding.targets[ref]}

    with true <- Choices.checks?(),
         true <- Choices.checkable?(tool.tool, ref, assessment.class),
         false <- GenServer.call(__MODULE__, {:checked?, task.id, key}),
         {:ok, [_, _ | _] = found} <- similar(task, tool.server, ref, false) do
      metas = found |> Enum.with_index(1) |> Map.new(fn {m, i} -> {"similar-#{i}", m} end)
      target = Enum.find_value(metas, fn {id, m} -> m["target"] == true && id end)
      mode = if Choices.mode() == :on, do: :hint, else: :shadow

      choice =
        Decisions.choose(
          %{
            task: task.id,
            server: tool.server,
            mode: mode,
            refs: for(i <- 1..map_size(metas), do: "similar-#{i}"),
            target: target
          },
          inspect: &metas[&1],
          more: fn -> extract(task, tool.server) end,
          context: %{objective: Map.get(task, :objective), intent: Map.get(task, :intent)}
        )

      hint =
        if mode == :hint and target,
          do: choice |> Choices.hint(target) |> name_refs(task, tool.server, ref, metas)

      :ok =
        GenServer.call(__MODULE__, {:checked, task.id, key, if(hint, do: :held, else: :passed)})

      {assessment, choice, hint}
    else
      # Nothing else on the page shares its label: remembered, not looked at again.
      {:ok, _} ->
        :ok = GenServer.call(__MODULE__, {:checked, task.id, key, :unique})
        {assessment, nil, nil}

      _ ->
        {assessment, nil, nil}
    end
  end

  # A hint names the agent's own ref for the target and, for another
  # candidate, its ref on the page now; one that can't be found isn't held.
  defp name_refs(nil, _task, _server, _ref, _metas), do: nil

  defp name_refs(%{"advice" => "other_candidate"} = hint, task, server, ref, metas) do
    wanted = metas[hint["suggested_ref"]]

    with {:ok, now} <- similar(task, server, ref, true),
         %{"ref" => found} when is_binary(found) <-
           Enum.find(
             now,
             &(&1["row"] == wanted["row"] and &1["signature"] == wanted["signature"])
           ) do
      %{hint | "target" => ref, "suggested_ref" => found}
    else
      _ -> nil
    end
  end

  defp name_refs(hint, _task, _server, ref, _metas), do: %{hint | "target" => ref}

  # The controls on the task's tab that share the target's role and name,
  # described by the browser (with their refs only when asked).
  defp similar(task, server, ref, refs) do
    with {:ok, %{"content" => [%{"text" => json} | _]} = result} <-
           MCP.call(
             server,
             "browser_similar",
             Browser.bind(%{"ref" => ref, "refs" => refs}, task.id),
             30_000
           ),
         false <- result["isError"] == true,
         {:ok, %{"candidates" => found}} when is_list(found) <- JSON.decode(json) do
      {:ok, found}
    else
      _ -> :error
    end
  end

  # The page's readable text, for a choice that needs more evidence.
  defp extract(task, server) do
    case MCP.call(server, "browser_extract", Browser.bind(%{}, task.id), 30_000) do
      {:ok, %{"isError" => true}} -> nil
      {:ok, %{"content" => content}} -> Enum.map_join(content, "\n", &(&1["text"] || ""))
      _ -> nil
    end
  end

  ## Outcomes (TinyAxe.Browser.Outcomes)

  # Unresolved submissions are held across tasks, per browser server and
  # target (signature or form, which name the site), for `:hold_ttl`
  # (30 minutes): the next task on the same tab can't send it again either.
  @holds :tiny_axe_gate_holds

  defp hold_ttl, do: Application.get_env(:tiny_axe, :tools, [])[:hold_ttl] || :timer.minutes(30)

  defp hold_table do
    if :ets.whereis(@holds) == :undefined,
      do: :ets.new(@holds, [:named_table, :public, :set, read_concurrency: true])

    @holds
  end

  # Called from the gate's process whenever a record changes.
  defp sync_hold(task_id, record) do
    table = hold_table()

    if record.status == :unresolved and not record.released do
      until = System.monotonic_time(:millisecond) + hold_ttl()

      for key <- record.keys,
          do:
            :ets.insert(
              table,
              {key,
               %{action: record.id, task: task_id, description: record.description, until: until}}
            )
    else
      for key <- record.keys,
          match?([{_, %{action: id}}] when id == record.id, :ets.lookup(table, key)),
          do: :ets.delete(table, key)
    end

    save_holds()
  end

  # Holds outlive tiny-axe too: written to `<state>/holds.json` (the redacted
  # keys, the action's id and description and when the hold ends, never a
  # value), and read back when the gate starts, each with what's left of
  # its time.
  defp holds_file, do: Path.join(TinyAxe.Ops.Journal.state_dir(), "holds.json")

  defp save_holds do
    now = System.monotonic_time(:millisecond)
    wall = System.os_time(:millisecond)

    entries =
      for {key, h} <- :ets.tab2list(hold_table()), h.until > now do
        %{
          key: Redact.text(key),
          action: h.action,
          task: h.task,
          description: Redact.text(h.description || ""),
          expires_at: wall + (h.until - now)
        }
      end

    path = holds_file()

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path <> ".tmp", JSON.encode!(entries)),
         :ok <- File.rename(path <> ".tmp", path) do
      :ok
    else
      error -> Logger.warning("tiny-axe couldn't save its holds: #{inspect(error)}")
    end
  end

  @doc false
  # Reads the saved holds back (as the gate does when it starts); expired
  # ones are dropped.
  def load_holds do
    now = System.monotonic_time(:millisecond)
    wall = System.os_time(:millisecond)

    with {:ok, raw} <- File.read(holds_file()),
         {:ok, entries} when is_list(entries) <- JSON.decode(raw) do
      for %{"key" => key, "expires_at" => at} = e <- entries, is_integer(at), at > wall do
        :ets.insert(
          hold_table(),
          {key,
           %{
             action: e["action"],
             task: e["task"],
             description: e["description"],
             until: now + (at - wall)
           }}
        )
      end
    end

    :ok
  end

  @doc false
  # The keys held by any task's unresolved submissions, not yet expired.
  def held_keys do
    now = System.monotonic_time(:millisecond)
    table = hold_table()
    for {key, %{until: until}} <- :ets.tab2list(table), until > now, into: MapSet.new(), do: key
  end

  @doc false
  # For tests that share one browser server: forget every hold.
  def clear_holds do
    :ets.delete_all_objects(hold_table())
    save_holds()
  end

  defp held_by(keys) do
    now = System.monotonic_time(:millisecond)

    Enum.find_value(keys, fn key ->
      case :ets.lookup(hold_table(), key) do
        [{_, %{until: until} = h}] when until > now -> h
        _ -> nil
      end
    end)
  end

  # Asks the user whether to do it again, through the usual approval.
  defp repeat_ok?(task, tool, args, assessment) do
    mine =
      Enum.find(
        GenServer.call(__MODULE__, {:actions, task.id}),
        &(&1.status == :unresolved and Enum.any?(&1.keys, fn k -> k in assessment.effect.keys end))
      )

    earlier =
      (mine && mine.description) || (held_by(assessment.effect.keys) || %{})[:description] ||
        "action like this"

    reason =
      "would do again what may already have gone through: an earlier #{earlier} couldn't be " <>
        "confirmed either way. Approve only if you've checked it didn't happen"

    ask(task, tool, args, :outward, reason, %{repeat: true}) in [:once, :session]
  end

  # The user said to go ahead: the holds on this target are lifted, here and
  # for every task.
  defp release(task, assessment) do
    GenServer.call(__MODULE__, {:release, task.id, assessment.effect.keys})
  end

  @doc """
  Takes in what a Chrome call showed (the `PostToolUse` hook's JSON:
  `tool_name`, `tool_input`, `tool_response`), so the next permission
  question is decided knowing each tab's address and each ref's label.
  """
  @spec observe(map(), map()) :: :ok
  def observe(task, %{"tool_name" => tool} = hook) do
    if Chrome.tool?(tool),
      do:
        GenServer.call(
          __MODULE__,
          {:chrome_seen, task.id, tool, hook["tool_input"] || %{}, hook["tool_response"]}
        ),
      else: :ok
  end

  def observe(_task, _hook), do: :ok

  # Claude Code asks before every Chrome call; the answer is its JSON:
  # {"behavior": "allow", "updatedInput": …} or {"behavior": "deny", "message": …}.
  defp chrome_permission(task, args) do
    tool = args["tool_name"]
    input = if is_map(args["input"]), do: args["input"], else: %{}

    {decision, answer} =
      if Chrome.tool?(tool) do
        case GenServer.call(__MODULE__, {:begin, task.id, tool, input}) do
          {:limit, why} ->
            task.notify.({:tool_limit, %{task: task.id, reason: why}})
            {:refused, chrome_deny(why)}

          {:ok, _allowed} ->
            chrome_decide(task, tool, input)
        end
      else
        {:refused, chrome_deny("only the user's Chrome is asked about here")}
      end

    short = if is_binary(tool), do: Chrome.short(tool), else: "?"

    Tools.Journal.append(task.id, %{
      tool: "chrome:" <> short,
      args: Redact.deep(input),
      decision: decision,
      error: answer["behavior"] == "deny",
      result: answer["message"] || "",
      ms: 0
    })

    if answer["behavior"] == "deny" do
      task.notify.(
        {:tool_result,
         %{tool: short, decision: decision, error: true, summary: answer["message"]}}
      )
    end

    %{"content" => [%{"type" => "text", "text" => JSON.encode!(answer)}]}
  end

  defp chrome_decide(task, tool, input) do
    {class, reason, host} = Chrome.classify(task.chrome_seen, tool, input)
    short = Chrome.short(tool)
    shown = %{read: :read, act: :outward, commit: :commit, refused: :refused}[class]

    task.notify.(
      {:tool_call, %{tool: short, class: shown, reason: reason, args: Redact.deep(input)}}
    )

    case class do
      :read ->
        {:ran, chrome_allow(input)}

      :refused ->
        {:refused, chrome_deny(reason)}

      # Purchases through Chrome come with the purchase gate for it (P2).
      :commit ->
        {:refused,
         chrome_deny(
           "#{reason} would place an order, and placing orders in the user's Chrome isn't " <>
             "switched on yet. Stop here and tell the user what's in the basket, the total, " <>
             "and that they can place the order themselves"
         )}

      :act ->
        if host && MapSet.member?(task.chrome_sites, host) do
          {:allowed_for_session, chrome_allow(input)}
        else
          where = if host, do: " on #{host}", else: ""

          pseudo = %{
            name: "chrome · #{short}",
            server: "chrome",
            definition: %{"description" => "Acts in your own Chrome#{where}."},
            policy: %{}
          }

          # "a" allows the whole site for this task, when there is one.
          case ask(task, pseudo, input, :outward, reason, %{session_ok: host != nil, site: host}) do
            :once ->
              {:approved, chrome_allow(input)}

            :session ->
              GenServer.call(__MODULE__, {:chrome_site, task.id, host})
              {:approved, chrome_allow(input)}

            :deny ->
              {:denied, chrome_deny("the user said no")}
          end
        end
    end
  end

  defp chrome_allow(input), do: %{"behavior" => "allow", "updatedInput" => input}

  defp chrome_deny(why),
    do: %{"behavior" => "deny", "message" => "tiny-axe stopped this call: #{why}."}

  @doc """
  The completion check, before an agent's answer reaches the user: one more
  look at anything the task sent but hasn't verified, or that's unresolved,
  then the answer compared with what the task's browser actions came to.
  Returns the text to deliver: the answer; the answer under a note naming
  what isn't confirmed; or, when a verified outcome contradicts it,
  tiny-axe's own report instead. A task without browser actions gets its answer back untouched.
  """
  @spec complete(String.t(), String.t()) :: String.t()
  def complete(id, reply) do
    with %{} = task <- GenServer.call(__MODULE__, {:get, id}),
         [_ | _] <- GenServer.call(__MODULE__, {:actions, id}) do
      t0 = System.monotonic_time(:millisecond)
      verified = Enum.map(Decisions.unverified(task.actions), &verify(task, &1, nil, :completion))

      for v <- verified,
          do: trace(id, v.decisions, v.action.tool, :verified, false)

      records = GenServer.call(__MODULE__, {:actions, id})
      checked = Decisions.completion(records, reply, context: %{objective: task[:objective]})
      traced = trace(id, checked.records, "completion", checked.outcome, false)

      Tools.Journal.append(id, %{
        tool: "tiny-axe/completion",
        args: %{},
        decision: checked.outcome,
        error: false,
        result: "",
        completion: %{
          schema: "browser-completion/1",
          outcome: checked.outcome,
          contradicted: checked.contradicted,
          unconfirmed: checked.unconfirmed,
          problems: Enum.map(checked.problems, & &1.id),
          confirmed: for(r <- records, r.status == :succeeded, r.submission, do: r.id)
        },
        verifications: Enum.map(verified, &Outcomes.journal_verification/1),
        decisions: traced,
        ms: System.monotonic_time(:millisecond) - t0
      })

      task.notify.(
        {:completion,
         %{
           outcome: checked.outcome,
           confirmed: for(r <- records, r.status == :succeeded, r.submission, do: r.description),
           unresolved: for(r <- checked.problems, r.status == :unresolved, do: r.description),
           failed: for(r <- checked.problems, r.status == :failed, do: r.description)
         }}
      )

      checked.text
    else
      _ -> reply
    end
  end

  # The task's action an agent named: by its own id, by the browser_assess
  # decision it reused, or else its latest that sent something.
  defp find_action(id, wanted) do
    records = GenServer.call(__MODULE__, {:actions, id})

    case wanted do
      "act-" <> _ ->
        Enum.find(records, &(&1.id == wanted))

      "asm-" <> _ ->
        Enum.find(records, &(&1.assessment_id == wanted or &1.reused_from == wanted))

      _ ->
        Enum.find(records, &(&1.submission and &1.status != :failed)) ||
          Enum.find(records, &("not_executed" not in &1.codes))
    end
  end

  # A fresh look at the page, with what the browser recorded for the action.
  defp verify(task, record, claim, by) do
    {v, updated} =
      Decisions.verify(record,
        observe: fn -> observe(task.id, record.server, record.id) end,
        claim: claim,
        by: by,
        context: %{objective: Map.get(task, :objective)}
      )

    :ok = GenServer.call(__MODULE__, {:action, task.id, updated})
    task.notify.({:outcome, outcome_event(updated, by)})
    v
  end

  defp observe(task_id, server, action_id) do
    with {:ok, %{"content" => [%{"text" => json} | _]} = result} <-
           MCP.call(
             server,
             "browser_observe",
             Browser.bind(%{"action" => action_id}, task_id),
             30_000
           ),
         false <- result["isError"] == true,
         {:ok, %{} = seen} <- JSON.decode(json) do
      {:ok, seen}
    else
      other -> {:error, other}
    end
  end

  defp hidden?(tool), do: tool.tool in List.wrap(tool.policy["hidden"])

  defp missing(definition, args) do
    required = get_in(definition, ["inputSchema", "required"]) || []
    Enum.reject(required, &(Map.get(args, &1) not in [nil, ""]))
  end

  defp decide(_task, _tool, _args, {:refused, reason}, _allowed),
    do: {:refused, refusal(reason || "tiny-axe doesn't allow this tool")}

  defp decide(_task, %{policy: %{"site" => true}}, args, _class, _allowed),
    do: {:ran, SiteTool.run(args)}

  # Waits here, in the HTTP request, for the sub-agents' results.
  defp decide(task, %{policy: %{"dispatch" => true}}, args, _class, _allowed),
    do: {:ran, Dispatch.run(task, args)}

  # A command waits here for its run; one that changes things asks first,
  # every time: allowing shell_run for the session would allow any command.
  defp decide(task, %{policy: %{"shell" => true}}, _args, {:read, _reason}, _allowed),
    do: {:ran, ShellTool.run(task, task.shell, :read_only)}

  defp decide(task, %{policy: %{"shell" => true}} = tool, args, {:outward, reason}, _allowed) do
    shown = %{command: task.shell.command, dir: Ops.show(task.shell.dir)}

    case ask(task, tool, args, :outward, reason, %{shell: shown}) do
      :deny -> {:denied, refusal("the user said no to this command")}
      _once -> {:approved, ShellTool.run(task, task.shell, :approved)}
    end
  end

  # browser_assess answers with the assessment, browser_verify with the
  # verification; nothing runs.
  defp decide(%{verification: v}, %{policy: %{"gate" => true}}, _args, _class, _allowed),
    do: {:ran, Decisions.verification_result(v)}

  defp decide(%{choice: %{} = c}, %{policy: %{"gate" => true}}, _args, _class, _allowed),
    do: {:ran, Choices.result(c)}

  # Held once by the gate's own candidate check: nothing runs.
  defp decide(%{hint: %{} = hint}, _tool, _args, _class, _allowed),
    do: {:advised, Choices.hint_result(hint)}

  defp decide(task, %{policy: %{"gate" => true}}, _args, _class, _allowed),
    do: {:ran, Decisions.result(task.assessment)}

  defp decide(task, tool, args, {:payment_step, reason}, _allowed) do
    if Purchases.enabled?() and tool.policy["browser"] == true,
      do: payment_step(task, tool, args, reason),
      else: {:refused, refusal("spending money isn't enabled in tiny-axe (purchases are off)")}
  end

  defp decide(task, tool, args, {:commit, reason}, _allowed) do
    cond do
      not Purchases.enabled?() ->
        {:refused, refusal("spending money isn't enabled in tiny-axe (purchases are off)")}

      tool.policy["browser"] != true ->
        {:refused,
         refusal("only tiny-axe's browser can buy things, at a checkout the user confirms")}

      true ->
        purchase(task, tool, args, reason)
    end
  end

  # The user does it in the browser window; the agent hears whether they did.
  defp decide(task, tool, args, {:handoff, reason}, _allowed) do
    case MCP.call(tool.server, tool.tool, Browser.bind(args, task.id)) do
      {:ok, _shown} ->
        case ask(task, tool, args, :handoff, reason) do
          :deny ->
            {:denied, refusal("the user didn't do it")}

          _ ->
            {:approved,
             %{
               "content" => [
                 %{
                   "type" => "text",
                   "text" =>
                     "The user says they've done it. Take a fresh snapshot to see the page."
                 }
               ]
             }}
        end

      {:error, reason} ->
        {:failed, refusal("the browser couldn't show its window: #{inspect(reason)}")}
    end
  end

  # Browser actions are asked about every time: allowing "click" for the
  # session would allow every click.
  defp decide(task, tool, args, {:outward, reason}, false) do
    ask_and_forward(task, tool, args, reason)
  end

  defp decide(task, %{policy: %{"browser" => true}} = tool, args, {:outward, reason}, _allowed),
    do: ask_and_forward(task, tool, args, reason)

  defp decide(task, tool, args, {class, _reason}, _allowed),
    do: forward(task, tool, args, if(class == :outward, do: :allowed_for_session, else: :ran))

  defp ask_and_forward(task, tool, args, reason) do
    case ask(task, tool, args, :outward, reason) do
      :once ->
        forward(task, tool, args, :approved)

      :session ->
        if tool.policy["browser"] != true,
          do: GenServer.call(__MODULE__, {:allow, task.id, tool.name})

        forward(task, tool, args, :approved)

      :deny ->
        {:denied, refusal("the user said no to this call")}
    end
  end

  ## Purchases (TinyAxe.Purchases): summary, checks, typed approval, recheck, click, receipt

  defp purchase(task, tool, args, reason) do
    id = Purchases.start(task.intent)
    # The user watches every purchase: the window is shown before they're asked.
    TinyAxe.Browser.show(tool.server, task.id)
    target = look_at(task, tool.server, args["ref"])

    case Purchases.summary(tool.server, task.id) do
      {:ok, summary} ->
        summary = Map.put(summary, "paying_with", Purchases.paying_with(summary))
        {card, needs} = paying_card(task, summary)

        Purchases.event(id, %{
          t: "summary",
          summary: summary,
          reason: reason,
          action: %{tool: tool.tool, args: args}
        })

        checks = Purchases.checks(task.intent, summary, card)

        case for({:fail, why} <- checks, do: why) do
          [] ->
            case ask_purchase(task, summary, checks, needs, :order) do
              {:confirm, ref} ->
                Purchases.event(id, %{t: "confirmed"})
                place(task, tool, args, id, summary, target, ref)

              {:deny, _ref} ->
                Purchases.event(id, %{t: "declined"})
                {:denied, refusal("the user didn't confirm the purchase")}
            end

          failed ->
            Purchases.event(id, %{t: "refused", checks: failed})
            task.notify.({:purchase_refused, %{summary: summary, failed: failed}})

            hint =
              if task.intent && task.intent.max == nil,
                do: " Ask the user the most they want to spend, then they can ask again.",
                else: ""

            {:refused,
             refusal("tiny-axe won't place this order: #{Enum.join(failed, "; ")}.#{hint}")}
        end

      {:error, why} ->
        Purchases.event(id, %{t: "refused", checks: [why]})
        {:refused, refusal("#{why}, and it won't place an order it can't check")}
    end
  end

  # The card this order is paid with: one tiny-axe will fill in now (and
  # what must be typed to unlock it), or one it filled at an earlier payment
  # step of this checkout, whose rules still apply.
  defp paying_card(task, summary) do
    case Purchases.payment(summary) do
      {:virtual, card} ->
        {card, TinyAxe.Cards.needs(card)}

      _ ->
        host = summary["host"]

        case task[:card_used] do
          %{host: ^host, card: card} -> {card, []}
          _ -> {nil, []}
        end
    end
  end

  # The page is read again: if the shop, the total or the button changed while
  # the user was deciding, nothing is clicked.
  defp place(task, tool, args, id, summary, target, ref) do
    now = look_at(task, tool.server, args["ref"])

    changed =
      case Purchases.summary(tool.server, task.id) do
        {:ok, again} ->
          cond do
            again["host"] != summary["host"] ->
              "the shop changed (#{again["host"]})"

            again["total"] != summary["total"] ->
              "the total changed from #{summary["total_text"]} to #{again["total_text"] || "nothing"}"

            target == nil or now == nil ->
              "tiny-axe can't find the button any more"

            Map.take(now, ["text", "tag", "isSubmit"]) !=
                Map.take(target, ["text", "tag", "isSubmit"]) ->
              "the button changed"

            true ->
              nil
          end

        {:error, why} ->
          why
      end

    filled = if changed == nil, do: fill_card(task, tool.server, summary, id, ref), else: :ok

    cond do
      changed ->
        Purchases.event(id, %{t: "changed", why: changed})
        task.notify.({:purchase_changed, changed})

        {:refused,
         refusal("#{changed} while the user was deciding, so nothing was bought. Look again")}

      filled != :ok ->
        task.notify.({:purchase_changed, filled})
        {:refused, refusal("#{filled}, so nothing was bought")}

      true ->
        click_and_receipt(task, tool, args, id, summary)
    end
  end

  # The user's card is filled in only now: after they confirmed (and typed its
  # PIN or CVC, if it needs them) and the page was read again, on the shop
  # they confirmed. Its details come from the vault for this one fill and go
  # straight to the browser; only "filled" and the card's id are recorded.
  defp fill_card(task, server, summary, id, ref) do
    case Purchases.payment(summary) do
      {:virtual, card} ->
        with {:ok, details} <- TinyAxe.Cards.details(card, ref),
             {:ok, %{} = result} <-
               MCP.call(
                 server,
                 "browser_fill_card",
                 Browser.bind(%{"expect_host" => summary["host"], "card" => details}, task.id),
                 30_000
               ),
             false <- result["isError"] == true do
          Purchases.event(id, %{t: "card_filled", card: card.label, card_id: card[:id]})
          GenServer.call(__MODULE__, {:card_used, task.id, %{host: summary["host"], card: card}})
          :ok
        else
          {:error, why} when is_binary(why) ->
            Purchases.event(id, %{t: "card_not_filled"})
            why

          true ->
            Purchases.event(id, %{t: "card_not_filled"})
            "#{card.label} couldn't be filled in (the page must be https, on #{summary["host"]})"

          _ ->
            Purchases.event(id, %{t: "card_not_filled"})
            "#{card.label} couldn't be filled in"
        end

      _ ->
        :ok
    end
  end

  # A checkout that takes the card on one page ("Continue") and the order on a
  # later one: this step fills the card (once the user says so, and types its
  # PIN or CVC), but spends nothing; the order is its own purchase later, with
  # the card's rules still applying.
  defp payment_step(task, tool, args, reason) do
    case Purchases.summary(tool.server, task.id) do
      {:ok, summary} ->
        cond do
          task.intent == nil ->
            {:refused, refusal("the user didn't ask to buy anything in this request")}

          true ->
            case Purchases.payment(summary) do
              {:virtual, card} ->
                card_step(task, tool, args, summary, card)

              {:none, why} ->
                {:refused, refusal(why)}

              # The user typed the card (a handoff), or chose one saved at the shop.
              _ ->
                ask_and_forward(task, tool, args, reason)
            end
        end

      {:error, why} ->
        {:refused, refusal(why)}
    end
  end

  defp card_step(task, tool, args, summary, card) do
    TinyAxe.Browser.show(tool.server, task.id)
    id = Purchases.start(task.intent)
    Purchases.event(id, %{t: "card_step", summary: Map.put(summary, "paying_with", card.label)})

    checks =
      Purchases.checks(task.intent, Map.put(summary, "total", nil), card)
      |> Enum.reject(&match?({:fail, "tiny-axe couldn't read the total" <> _}, &1))

    case for({:fail, why} <- checks, do: why) do
      [] ->
        case ask_purchase(
               task,
               Map.put(summary, "paying_with", card.label),
               checks,
               TinyAxe.Cards.needs(card),
               :card_step
             ) do
          {:confirm, ref} ->
            case fill_card(task, tool.server, summary, id, ref) do
              :ok ->
                Purchases.event(id, %{t: "card_step_done"})
                # Filling the card may change the page; the purchase gate
                # has its own checks, so this click carries no signatures.
                forward(Map.delete(task, :assessment), tool, args, :approved)

              why ->
                {:refused, refusal("#{why}, so nothing was sent")}
            end

          {:deny, _ref} ->
            Purchases.event(id, %{t: "declined"})
            {:denied, refusal("the user didn't want the card filled in")}
        end

      failed ->
        Purchases.event(id, %{t: "refused", checks: failed})
        task.notify.({:purchase_refused, %{summary: summary, failed: failed}})
        {:refused, refusal("tiny-axe won't use #{card.label} here: #{Enum.join(failed, "; ")}")}
    end
  end

  defp click_and_receipt(task, tool, args, id, summary) do
    # Write-ahead: if tiny-axe dies after this, the next start says the order
    # may have gone through, and it is never clicked again.
    Purchases.event(id, %{t: "clicking"})

    case MCP.call(tool.server, tool.tool, Browser.bind(args, task.id)) do
      {:ok, result} ->
        Purchases.event(id, %{t: "clicked"})
        receipt = receipt(task, tool.server, id)

        task.notify.(
          {:purchased,
           Map.merge(receipt, %{
             host: summary["host"],
             total_text: summary["total_text"],
             id: id
           })}
        )

        note = %{
          "type" => "text",
          "text" =>
            "tiny-axe placed the order after the user confirmed it" <>
              if(receipt.order, do: "; order #{receipt.order}.", else: ".")
        }

        # The receipt also settles the action's outcome record (Outcomes).
        {:approved,
         result
         |> Map.update("content", [note], &[note | &1])
         |> Map.put("_tinyaxe_receipt", %{order: receipt.order})}

      {:error, reason} ->
        Purchases.event(id, %{t: "click_failed", error: inspect(reason)})

        {:failed,
         refusal(
           "the click failed (#{inspect(reason)}); the order may or may not have gone through, so check the page"
         )}
    end
  end

  # The confirmation page's text, order number and a screenshot.
  defp receipt(task, server, id) do
    dir = Purchases.dir(id)

    text =
      case MCP.call(server, "browser_extract", Browser.bind(%{}, task.id), 30_000) do
        {:ok, %{"content" => content}} -> Enum.map_join(content, "\n", &(&1["text"] || ""))
        _ -> ""
      end

    File.write!(Path.join(dir, "receipt.txt"), text)

    case MCP.call(
           server,
           "browser_take_screenshot",
           Browser.bind(%{"fullPage" => true}, task.id),
           30_000
         ) do
      {:ok, %{"content" => [%{"type" => "image", "data" => data} | _]}} ->
        File.write!(Path.join(dir, "receipt.png"), Base.decode64!(data))

      _ ->
        :ok
    end

    order =
      case Regex.run(
             ~r/(?i:order|confirmation)\s*(?i:number|no\.?|#|id)?\s*[:#]?\s*([A-Z0-9][A-Z0-9-]{3,})/,
             text
           ) do
        [_, order] -> order
        nil -> nil
      end

    Purchases.event(id, %{t: "receipt", order: order})
    %{order: order, dir: dir}
  end

  # `needs`: what the user types to unlock the card for this purchase (its PIN,
  # its CVC); `mode`: :order (type the total) or :card_step (fill the card in).
  defp ask_purchase(task, summary, checks, needs, mode) do
    ref = make_ref()
    timeout = Application.get_env(:tiny_axe, :tools, [])[:approval_timeout] || :timer.minutes(10)

    task.notify.(
      {:purchase_approval,
       %{summary: summary, checks: checks, needs: needs, mode: mode, reply_to: self(), ref: ref}}
    )

    receive do
      {:purchase_answer, ^ref, answer} when answer in [:confirm, :deny] -> {answer, ref}
    after
      timeout -> {:deny, ref}
    end
  end

  # A browser action goes to the task's tab with what was assessed, which
  # the browser checks again just before acting: after the user's approval
  # too. A target that changed meanwhile isn't touched, and a browser_assess
  # record it reused is dropped, so the next call is judged afresh.
  defp forward(task, tool, args, decision) do
    args =
      if browser?(tool),
        do:
          Browser.bind(
            args,
            task.id,
            Decisions.expect(task[:assessment]),
            task[:assessment] && task.assessment[:action_id]
          ),
        else: args

    timeout = Application.get_env(:tiny_axe, :tools, [])[:action_timeout] || 120_000

    case MCP.call(tool.server, tool.tool, args, timeout) do
      {:ok, result} ->
        if Decisions.stale_result?(result) do
          if task.assessment.reused_from,
            do: GenServer.cast(__MODULE__, {:forget, task.id, task.assessment.reused_from})

          {:refused,
           refusal(
             "the page changed after tiny-axe checked this action (stale_target), so nothing was done. " <>
               "Take a fresh browser_snapshot and use its refs"
           )}
        else
          {decision, result}
        end

      {:error, reason} ->
        {:failed, refusal("the tool failed: #{inspect(reason)}")}
    end
  end

  # Waits for the user in the caller (the HTTP request), so other calls go on.
  defp ask(task, tool, args, class, reason, extra \\ %{}) do
    ref = make_ref()
    timeout = Application.get_env(:tiny_axe, :tools, [])[:approval_timeout] || :timer.minutes(10)

    task.notify.({:tool_approval,
     %{
       tool: tool.name,
       server: tool.server,
       description: tool.definition["description"],
       args: Redact.deep(args),
       class: class,
       reason: reason,
       # Browser actions are asked about one by one.
       session_ok:
         tool.policy["browser"] != true and tool.policy["shell"] != true and
           class == :outward,
       reply_to: self(),
       ref: ref
     }
     |> Map.merge(extra)})

    receive do
      {:tool_answer, ^ref, answer} when answer in [:once, :session, :deny] -> answer
    after
      timeout -> :deny
    end
  end

  defp refusal(why),
    do: %{
      "isError" => true,
      "content" => [%{"type" => "text", "text" => "tiny-axe stopped this call: #{why}."}]
    }

  defp summary(%{"content" => content}) do
    content
    |> Enum.map_join(" ", fn
      %{"type" => "text", "text" => t} -> t
      %{"type" => type} -> "[#{type}]"
    end)
    |> String.slice(0, 300)
  end

  defp summary(_), do: ""

  defp port do
    case ThousandIsland.listener_info(@http) do
      {:ok, {_ip, port}} -> {:ok, port}
      _ -> {:error, :gate_not_listening}
    end
  catch
    :exit, _ -> {:error, :gate_not_listening}
  end

  ## Server

  @impl true
  def init(:ok) do
    hold_table()
    load_holds()
    {:ok, %{}}
  end

  @impl true
  def handle_call({:open, task}, _from, tasks) do
    # A run that was killed never closed its task; forget it once well
    # expired, and free its browser tabs.
    now = System.monotonic_time(:millisecond)

    {expired, tasks} =
      Map.split_with(tasks, fn {_id, t} -> now > t.deadline + :timer.minutes(5) end)

    for {id, t} <- expired,
        server <- t.leased,
        do: Task.start(fn -> Browser.release(server, id) end)

    task = Map.put(task, :monitor, Process.monitor(task.owner))
    {:reply, :ok, Map.put(tasks, task.id, task)}
  end

  def handle_call({:close, id}, _from, tasks) do
    if tasks[id], do: Process.demonitor(tasks[id].monitor, [:flush])
    {:reply, tasks[id], Map.delete(tasks, id)}
  end

  def handle_call({:get, id}, _from, tasks), do: {:reply, tasks[id], tasks}

  def handle_call({:driver, id, choice}, _from, tasks) do
    tasks = update_task(tasks, id, &%{&1 | driver: choice})
    {:reply, dispatches?(tasks[id]), tasks}
  end

  def handle_call({:examples, id, stage, ids}, _from, tasks),
    do:
      {:reply, :ok,
       update_task(tasks, id, fn t ->
         seen = t[:examples] || %{start: [], step: []}
         Map.put(t, :examples, Map.update!(seen, stage, &Enum.uniq(&1 ++ ids)))
       end)}

  def handle_call(:open_ids, _from, tasks), do: {:reply, Map.keys(tasks), tasks}

  def handle_call({:assessments, id}, _from, tasks),
    do: {:reply, tasks[id] && Map.take(tasks[id], [:assessments, :floors, :actions]), tasks}

  def handle_call({:actions, id}, _from, tasks),
    do: {:reply, (tasks[id] && tasks[id].actions) || [], tasks}

  # A new record, or one verified since. Unresolved ones (they hold their
  # target) and failed or declined ones (the completion check needs them)
  # are always kept; of the rest, the newest 50.
  def handle_call({:action, id, record}, _from, tasks) do
    sync_hold(id, record)

    {:reply, :ok,
     update_task(tasks, id, fn t ->
       all =
         Enum.sort_by([record | Enum.reject(t.actions, &(&1.id == record.id))], & &1.seq, :desc)

       {held, rest} = Enum.split_with(all, &(&1.status in [:unresolved, :failed]))
       %{t | actions: Enum.sort_by(held ++ Enum.take(rest, 50), & &1.seq, :desc)}
     end)}
  end

  # The user said to do it again: this task's records on those keys stop
  # holding, and so does any task's hold on them.
  def handle_call({:release, id, keys}, _from, tasks) do
    for key <- keys, do: :ets.delete(hold_table(), key)
    save_holds()

    {:reply, true,
     update_task(tasks, id, fn t ->
       %{
         t
         | actions:
             Enum.map(t.actions, fn r ->
               if r.status == :unresolved and Enum.any?(r.keys, &(&1 in keys)),
                 do: %{r | released: true},
                 else: r
             end)
       }
     end)}
  end

  # The card tiny-axe filled in at a payment step, so the order later in the
  # same checkout still answers to that card's rules.
  def handle_call({:card_used, id, used}, _from, tasks) do
    {:reply, :ok,
     if(Map.has_key?(tasks, id), do: put_in(tasks, [id, :card_used], used), else: tasks)}
  end

  def handle_call({:chrome_seen, id, tool, input, response}, _from, tasks),
    do:
      {:reply, :ok,
       update_task(tasks, id, fn task ->
         %{task | chrome_seen: Chrome.observe(task.chrome_seen, tool, input, response)}
       end)}

  def handle_call({:chrome_site, id, host}, _from, tasks),
    do:
      {:reply, :ok,
       update_task(tasks, id, &%{&1 | chrome_sites: MapSet.put(&1.chrome_sites, host)})}

  def handle_call({:allow, id, name}, _from, tasks) do
    {:reply, :ok, update_in(tasks, [id, :allowed], &MapSet.put(&1, name))}
  catch
    _, _ -> {:reply, :ok, tasks}
  end

  # Counts the call against the task's limits before it runs.
  def handle_call({:begin, id, name, args}, _from, tasks) do
    case tasks[id] do
      nil ->
        {:reply, {:limit, "this task is closed"}, tasks}

      task ->
        key = {name, args}

        cond do
          task.calls >= task.max_calls ->
            {:reply, {:limit, "the task reached its limit of #{task.max_calls} tool calls"},
             tasks}

          System.monotonic_time(:millisecond) > task.deadline ->
            {:reply, {:limit, "the task ran out of time"}, tasks}

          Enum.take(task.recent, 2) == [key, key] ->
            {:reply, {:limit, "the same call came three times in a row"}, tasks}

          true ->
            task = %{task | calls: task.calls + 1, recent: Enum.take([key | task.recent], 5)}
            {:reply, {:ok, MapSet.member?(task.allowed, name)}, Map.put(tasks, id, task)}
        end
    end
  end

  def handle_call({:checked?, id, key}, _from, tasks),
    do: {:reply, tasks[id] != nil and Map.has_key?(tasks[id].candidate_checks, key), tasks}

  def handle_call({:checked, id, key, verdict}, _from, tasks),
    do:
      {:reply, :ok,
       update_task(
         tasks,
         id,
         &%{&1 | candidate_checks: Map.put(&1.candidate_checks, key, verdict)}
       )}

  def handle_call({:assessed, id, assessment}, _from, tasks),
    do: {:reply, :ok, update_task(tasks, id, &Map.merge(&1, Decisions.remember(&1, assessment)))}

  # The process that opened a task died without closing it (a run killed on
  # cancel, whose `after` never ran): close it now, and free its tabs, which
  # makes the browser forget what its actions typed.
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, tasks) do
    case Enum.find(tasks, fn {_id, t} -> t[:monitor] == ref end) do
      {id, t} ->
        for server <- t.leased, do: Task.start(fn -> Browser.release(server, id) end)
        TinyAxe.Vault.task_closed(id)
        {:noreply, Map.delete(tasks, id)}

      nil ->
        {:noreply, tasks}
    end
  end

  def handle_info(_message, tasks), do: {:noreply, tasks}

  @impl true
  def handle_cast({:forget, id, assessment_id}, tasks),
    do:
      {:noreply,
       update_task(tasks, id, fn t ->
         %{t | assessments: Enum.reject(t.assessments, &(&1.id == assessment_id))}
       end)}

  def handle_cast({:leased, id, server}, tasks),
    do: {:noreply, update_task(tasks, id, &%{&1 | leased: MapSet.put(&1.leased, server)})}

  # What a call came to, for the next browser decisions' recent actions.
  def handle_cast({:outcome, id, outcome}, tasks) do
    {:noreply,
     if(Map.has_key?(tasks, id),
       do: update_in(tasks, [id, :outcomes], &Enum.take(&1 ++ [outcome], -5)),
       else: tasks
     )}
  end

  defp update_task(tasks, id, fun),
    do: if(Map.has_key?(tasks, id), do: Map.update!(tasks, id, fun), else: tasks)
end
