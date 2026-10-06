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
       or refused; the model never does
    3. **approval** — an outward call waits for the user (`{:tool_approval, ...}`,
       answered with `{:tool_answer, ref, :once | :session | :deny}`), unless
       they allowed that tool for the session; commits are refused until the
       purchase gate exists
    4. **forward** to the server, then **redact** the result
    5. **journal** the call, and report it to the task (`{:tool_call, ...}`)

  A refusal comes back to the agent as a tool error saying why, so it can
  carry on or tell the user.
  """

  use GenServer

  require Logger

  alias TinyAxe.{MCP, Purchases, Tools}
  alias TinyAxe.Tools.{BrowserPolicy, Policy, Redact}

  @http TinyAxe.Tools.GateHTTP

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc """
  Opens a task: its own address and token for the driver. `notify` gets the
  task's events (and approval questions). `opts`: `:servers` (`:all` or a
  list of names), `:max_calls`, `:max_minutes`, and `:intent`, what the user
  asked to buy, if anything (`TinyAxe.Purchases.intent/2`).
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
        intent: Keyword.get(opts, :intent)
      }

      :ok = GenServer.call(__MODULE__, {:open, task})
      Tools.Journal.start(id)
      {:ok, %{id: id, token: token, url: "http://127.0.0.1:#{port}/mcp/#{id}"}}
    end
  end

  @spec close_task(String.t()) :: :ok
  def close_task(id), do: GenServer.call(__MODULE__, {:close, id})

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

  @doc "The tools a task may use, as MCP tool definitions."
  @spec tools(map()) :: [map()]
  def tools(task) do
    for t <- MCP.tools(task.servers),
        not hidden?(t),
        Policy.classify(t.definition, t.policy) != :refused do
      Map.take(t.definition, ["description", "inputSchema", "annotations", "title"])
      |> Map.put("name", t.name)
    end
  end

  @doc "Runs one tool call through the gate. Returns an MCP result."
  @spec call(map(), String.t(), map()) :: map()
  def call(task, name, args) do
    t0 = System.monotonic_time(:millisecond)
    tool = Enum.find(MCP.tools(task.servers), &(&1.name == name))

    {decision, result} =
      case tool && GenServer.call(__MODULE__, {:begin, task.id, name, args}) do
        nil ->
          {:refused, refusal("there's no tool called #{name}")}

        {:limit, why} ->
          task.notify.({:tool_limit, %{task: task.id, reason: why}})
          {:refused, refusal(why)}

        {:ok, allowed} ->
          # A call missing what the tool requires goes back to the agent to fix,
          # before anything is inspected or the user is asked.
          case missing(tool.definition, args) do
            [] ->
              {class, reason} = classify(tool, args)

              task.notify.(
                {:tool_call, %{tool: name, class: class, reason: reason, args: Redact.deep(args)}}
              )

              decide(task, tool, args, {class, reason}, allowed)

            keys ->
              {:refused, refusal("#{name} needs #{Enum.join(keys, ", ")}")}
          end
      end

    result = Redact.result(result)
    ms = System.monotonic_time(:millisecond) - t0

    Tools.Journal.append(task.id, %{
      tool: name,
      args: Redact.deep(args),
      decision: decision,
      error: result["isError"] == true,
      result: summary(result),
      ms: ms
    })

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

  # Browser actions are classed by what they'd do on the page (the gate looks
  # first, with browser_inspect); other tools by their server's policy.
  defp classify(tool, args) do
    cond do
      hidden?(tool) ->
        {:refused, "that tool is for tiny-axe only"}

      tool.policy["browser"] == true ->
        BrowserPolicy.classify(tool.tool, args, &look_at(tool.server, &1))
        |> then(fn {class, reason} ->
          {Policy.stricter(class_floor(tool), class) |> keep_special(class), reason}
        end)

      true ->
        {Policy.classify(tool.definition, tool.policy), nil}
    end
  end

  # A browser tool's own policy class is a floor (e.g. never below read); a
  # handoff stays a handoff.
  defp class_floor(_tool), do: :read
  defp keep_special(_stricter, special) when special in [:handoff, :payment_step], do: special
  defp keep_special(stricter, _class), do: stricter

  defp look_at(server, ref) do
    args = if ref, do: %{"ref" => ref}, else: %{}

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
    case MCP.call(tool.server, tool.tool, args) do
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

  defp decide(_task, tool, args, {class, _reason}, _allowed),
    do: forward(tool, args, if(class == :outward, do: :allowed_for_session, else: :ran))

  defp ask_and_forward(task, tool, args, reason) do
    case ask(task, tool, args, :outward, reason) do
      :once ->
        forward(tool, args, :approved)

      :session ->
        if tool.policy["browser"] != true,
          do: GenServer.call(__MODULE__, {:allow, task.id, tool.name})

        forward(tool, args, :approved)

      :deny ->
        {:denied, refusal("the user said no to this call")}
    end
  end

  ## Purchases (TinyAxe.Purchases): summary, checks, typed approval, recheck, click, receipt

  defp purchase(task, tool, args, reason) do
    id = Purchases.start(task.intent)
    # The user watches every purchase: the window is shown before they're asked.
    TinyAxe.Browser.show(tool.server)
    target = look_at(tool.server, args["ref"])

    case Purchases.summary(tool.server) do
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
    now = look_at(tool.server, args["ref"])

    changed =
      case Purchases.summary(tool.server) do
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
                 %{"expect_host" => summary["host"], "card" => details},
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
    case Purchases.summary(tool.server) do
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
    TinyAxe.Browser.show(tool.server)
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
                forward(tool, args, :approved)

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

    case MCP.call(tool.server, tool.tool, args) do
      {:ok, result} ->
        Purchases.event(id, %{t: "clicked"})
        receipt = receipt(tool.server, id)

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
  defp receipt(server, id) do
    dir = Purchases.dir(id)

    text =
      case MCP.call(server, "browser_extract", %{}, 30_000) do
        {:ok, %{"content" => content}} -> Enum.map_join(content, "\n", &(&1["text"] || ""))
        _ -> ""
      end

    File.write!(Path.join(dir, "receipt.txt"), text)

    case MCP.call(server, "browser_take_screenshot", %{"fullPage" => true}, 30_000) do
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

  defp forward(tool, args, decision) do
    case MCP.call(tool.server, tool.tool, args) do
      {:ok, result} -> {decision, result}
      {:error, reason} -> {:failed, refusal("the tool failed: #{inspect(reason)}")}
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
    # A run that was killed never closed its task; forget it once well expired.
    now = System.monotonic_time(:millisecond)
    tasks = Map.reject(tasks, fn {_id, t} -> now > t.deadline + :timer.minutes(5) end)
    {:reply, :ok, Map.put(tasks, task.id, task)}
  end

  def handle_call({:close, id}, _from, tasks), do: {:reply, :ok, Map.delete(tasks, id)}
  def handle_call({:get, id}, _from, tasks), do: {:reply, tasks[id], tasks}

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
end
