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

  alias TinyAxe.{MCP, Tools}
  alias TinyAxe.Tools.{BrowserPolicy, Policy, Redact}

  @http TinyAxe.Tools.GateHTTP

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc """
  Opens a task: its own address and token for the driver. `notify` gets the
  task's events (and approval questions). `opts`: `:servers` (`:all` or a
  list of names), `:max_calls`, `:max_minutes`.
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
        allowed: MapSet.new()
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
  defp keep_special(_stricter, :handoff), do: :handoff
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

  defp decide(_task, _tool, _args, {:commit, _reason}, _allowed),
    do: {:refused, refusal("spending money isn't enabled in tiny-axe yet")}

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
