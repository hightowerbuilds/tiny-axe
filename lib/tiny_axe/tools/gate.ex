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

  Each task leases its own browser tabs (`TinyAxe.Browser.bind/3`); closing
  the task frees them for the next one.

  A refusal comes back to the agent as a tool error saying why, so it can
  carry on or tell the user.
  """

  use GenServer

  require Logger

  alias TinyAxe.{Browser, MCP, Purchases, Tools}
  alias TinyAxe.Browser.Decisions
  alias TinyAxe.Tools.{Policy, Redact}

  @http TinyAxe.Tools.GateHTTP

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc """
  Opens a task: its own address and token for the driver. `notify` gets the
  task's events (and approval questions). `opts`: `:servers` (`:all` or a
  list of names), `:max_calls`, `:max_minutes`, `:intent`, what the user
  asked to buy, if anything (`TinyAxe.Purchases.intent/2`), and `:objective`,
  the user's request, which browser decisions are shown as the task.
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
        # The latest calls and what the gate did, newest last, for decisions.
        outcomes: [],
        # Its browser assessments, for reuse and held restrictions
        # (Decisions.remember/2), and the browser servers whose tabs it holds.
        assessments: [],
        floors: %{},
        leased: MapSet.new()
      }

      :ok = GenServer.call(__MODULE__, {:open, task})
      Tools.Journal.start(id)
      {:ok, %{id: id, token: token, url: "http://127.0.0.1:#{port}/mcp/#{id}"}}
    end
  end

  @doc "Closes a task; the browser tabs it held stay open, free for the next task."
  @spec close_task(String.t()) :: :ok
  def close_task(id) do
    case GenServer.call(__MODULE__, {:close, id}) do
      %{leased: leased} -> Enum.each(leased, &Browser.release(&1, id))
      _ -> :ok
    end

    :ok
  end

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
  with a browser, the gate's own `browser_assess`.
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

    if Enum.any?(all, &browser?/1), do: listed ++ Decisions.definitions(), else: listed
  end

  @doc "Runs one tool call through the gate. Returns an MCP result."
  @spec call(map(), String.t(), map()) :: map()
  def call(task, name, args) do
    t0 = System.monotonic_time(:millisecond)
    tool = find(task, name)
    # The gate's own browser keys (tab lease, signatures) come from the gate.
    args = if tool && (browser?(tool) or gate?(tool)), do: Decisions.clean(args), else: args

    {class, assessment, {decision, result}} =
      case tool && GenServer.call(__MODULE__, {:begin, task.id, name, args}) do
        nil ->
          {nil, nil, {:refused, refusal("there's no tool called #{name}")}}

        {:limit, why} ->
          task.notify.({:tool_limit, %{task: task.id, reason: why}})
          {nil, nil, {:refused, refusal(why)}}

        {:ok, allowed} ->
          # A call missing what the tool requires goes back to the agent to fix,
          # before anything is inspected or the user is asked.
          case missing(tool.definition, args) do
            [] ->
              {class, reason, task} = classify(task, tool, args)

              task.notify.(
                {:tool_call, %{tool: name, class: class, reason: reason, args: Redact.deep(args)}}
              )

              {class, task[:assessment], decide(task, tool, args, {class, reason}, allowed)}

            keys ->
              {nil, nil, {:refused, refusal("#{name} needs #{Enum.join(keys, ", ")}")}}
          end
      end

    result = Redact.result(result)
    ms = System.monotonic_time(:millisecond) - t0
    error = result["isError"] == true
    traced = (assessment && assessment.decisions) || []

    for record <- traced do
      Tools.Journal.append_decision(
        task.id,
        Map.merge(record, %{
          task: task.id,
          tool: assessment.binding.tool,
          result: %{decision: decision, error: error}
        })
      )
    end

    Tools.Journal.append(task.id, %{
      tool: name,
      args: Redact.deep(args),
      decision: decision,
      error: error,
      result: summary(result),
      assessment: Decisions.journal(assessment),
      decisions: Enum.map(traced, & &1.id),
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

  # The gate's own tools first; then the task's servers'.
  defp find(task, name) do
    tools = MCP.tools(task.servers)

    cond do
      Decisions.owns?(name) and Enum.any?(tools, &browser?/1) ->
        [definition] = for d <- Decisions.definitions(), d["name"] == name, do: d
        %{name: name, server: nil, tool: name, definition: definition, policy: %{"gate" => true}}

      true ->
        Enum.find(tools, &(&1.name == name))
    end
  end

  defp browser?(tool), do: tool.policy["browser"] == true
  defp gate?(tool), do: tool.policy["gate"] == true

  # Browser actions are assessed by what they'd do on the page (the gate
  # looks first, with browser_inspect); other tools are classed by their
  # server's policy. `browser_assess` runs the same assessment as advice; it
  # can only assess a browser action, never itself.
  defp classify(task, tool, args) do
    cond do
      hidden?(tool) ->
        {:refused, "that tool is for tiny-axe only", task}

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
        {assessment.class, assessment.reason, Map.put(task, :assessment, assessment)}

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

  defp hidden?(tool), do: tool.tool in List.wrap(tool.policy["hidden"])

  defp missing(definition, args) do
    required = get_in(definition, ["inputSchema", "required"]) || []
    Enum.reject(required, &(Map.get(args, &1) not in [nil, ""]))
  end

  defp decide(_task, _tool, _args, {:refused, reason}, _allowed),
    do: {:refused, refusal(reason || "tiny-axe doesn't allow this tool")}

  # browser_assess answers with the assessment; nothing runs.
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

        {:approved, Map.update(result, "content", [note], &[note | &1])}

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
        do: Browser.bind(args, task.id, Decisions.expect(task[:assessment])),
        else: args

    case MCP.call(tool.server, tool.tool, args) do
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
  defp ask(task, tool, args, class, reason) do
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
       session_ok: tool.policy["browser"] != true and class == :outward,
       reply_to: self(),
       ref: ref
     }})

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
  def init(:ok), do: {:ok, %{}}

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

    {:reply, :ok, Map.put(tasks, task.id, task)}
  end

  def handle_call({:close, id}, _from, tasks), do: {:reply, tasks[id], Map.delete(tasks, id)}
  def handle_call({:get, id}, _from, tasks), do: {:reply, tasks[id], tasks}

  def handle_call({:assessments, id}, _from, tasks),
    do: {:reply, tasks[id] && Map.take(tasks[id], [:assessments, :floors]), tasks}

  # The card tiny-axe filled in at a payment step, so the order later in the
  # same checkout still answers to that card's rules.
  def handle_call({:card_used, id, used}, _from, tasks) do
    {:reply, :ok,
     if(Map.has_key?(tasks, id), do: put_in(tasks, [id, :card_used], used), else: tasks)}
  end

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

  def handle_call({:assessed, id, assessment}, _from, tasks),
    do: {:reply, :ok, update_task(tasks, id, &Map.merge(&1, Decisions.remember(&1, assessment)))}

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
