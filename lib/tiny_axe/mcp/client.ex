defmodule TinyAxe.MCP.Client do
  @moduledoc """
  A connection to one MCP server, over stdio or streamable HTTP.

  It connects (`initialize`, then `notifications/initialized`), lists the
  server's tools, and answers `call/4`. Calls don't block the process: each
  waits for its own reply, so a slow tool doesn't hold up the others. Requests
  the server sends to us (sampling, roots, elicitation) are declined: tiny-axe
  gives MCP servers nothing but tool calls.

  A stdio server runs in its own process group, which is killed when this
  process stops, and its stderr goes to `<state>/mcp/<name>.log`. If the server dies, this process stops too, and its
  supervisor restarts both.

  `config` is one server's entry from `mcp.json` (`TinyAxe.MCP`):
  `%{"type" => "stdio", "command" => ..., "args" => [...], "env" => %{...}}` or
  `%{"type" => "http", "url" => ..., "headers" => %{...}}`.
  """

  use GenServer, restart: :transient

  require Logger

  @protocol "2025-06-18"
  @connect_timeout 20_000

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: via(name))
  end

  def via(name), do: {:via, Registry, {TinyAxe.MCP.Registry, name}}

  @doc "The server's tools, as it listed them."
  @spec tools(String.t()) :: [map()]
  def tools(name), do: GenServer.call(via(name), :tools)

  @doc "The server's config (including its `policy`)."
  @spec config(String.t()) :: map()
  def config(name), do: GenServer.call(via(name), :config)

  @doc "Calls a tool. Returns the MCP result (`%{\"content\" => [...]}`) or an error."
  @spec call(String.t(), String.t(), map(), timeout()) :: {:ok, map()} | {:error, term()}
  def call(name, tool, args, timeout \\ 120_000) do
    GenServer.call(via(name), {:call, tool, args, timeout}, timeout + 5_000)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, {:noproc, _} -> {:error, :server_not_running}
    :exit, reason -> {:error, {:server_down, reason}}
  end

  ## Server

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    config = Keyword.fetch!(opts, :config)

    state = %{
      name: Keyword.fetch!(opts, :name),
      config: config,
      port: nil,
      os_pid: nil,
      buffer: "",
      session: nil,
      next_id: 1,
      pending: %{},
      tools: []
    }

    case open(state) do
      {:ok, state} ->
        case handshake(state) do
          {:ok, state} -> {:ok, state}
          {:error, reason} -> stop_port(state) && {:stop, {:connect_failed, reason}}
        end

      {:error, reason} ->
        {:stop, {:connect_failed, reason}}
    end
  end

  defp open(%{config: %{"type" => "http"}} = state), do: {:ok, state}

  defp open(%{config: config} = state) do
    case System.find_executable(config["command"] || "") do
      nil ->
        {:error, {:not_found, config["command"]}}

      exe ->
        # Its stderr goes to a log file: on the terminal it would draw over the TUI.
        log = Path.join([TinyAxe.Ops.Journal.state_dir(), "mcp", "#{state.name}.log"])
        File.mkdir_p!(Path.dirname(log))

        port =
          Port.open({:spawn_executable, System.find_executable("sh")}, [
            :binary,
            :exit_status,
            {:args,
             ["-c", ~s(log=$1; shift; exec "$@" 2>>"$log"), "sh", log, exe] ++
               Enum.map(config["args"] || [], &to_string/1)},
            {:env, Enum.map(config["env"] || %{}, fn {k, v} -> {~c"#{k}", ~c"#{v}"} end)},
            {:cd, config["cwd"] || System.tmp_dir!()}
          ])

        {:os_pid, os_pid} = Port.info(port, :os_pid)
        {:ok, %{state | port: port, os_pid: os_pid}}
    end
  end

  # Runs before the process takes calls, so it waits for its replies directly.
  defp handshake(state) do
    init_params = %{
      protocolVersion: @protocol,
      capabilities: %{},
      clientInfo: %{name: "tiny-axe", version: "0.1"}
    }

    with {:ok, _info, state} <- request_sync(state, "initialize", init_params),
         {:ok, state} <- notify_server(state, "notifications/initialized"),
         {:ok, %{"tools" => tools}, state} <- request_sync(state, "tools/list", %{}) do
      {:ok, %{state | tools: tools}}
    end
  end

  defp request_sync(state, method, params) do
    {id, state} = next_id(state)
    message = %{jsonrpc: "2.0", id: id, method: method, params: params}

    case state.config do
      %{"type" => "http"} ->
        case http_post(state, message) do
          {:ok, replies, session} ->
            state = %{state | session: session || state.session}

            case Enum.find(replies, &(&1["id"] == id)) do
              %{"result" => result} -> {:ok, result, state}
              %{"error" => error} -> {:error, error}
              nil -> {:error, :no_reply}
            end

          {:error, reason} ->
            {:error, reason}
        end

      _stdio ->
        send_line(state, message)
        await_line(state, id, System.monotonic_time(:millisecond) + @connect_timeout)
    end
  end

  defp await_line(state, id, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {port, {:data, data}} when port == state.port ->
        {lines, rest} = split_lines(state.buffer <> data)
        state = %{state | buffer: rest}

        case Enum.find_value(lines, &match_reply(&1, id)) do
          {:ok, result} -> {:ok, result, state}
          {:error, error} -> {:error, error}
          nil -> await_line(state, id, deadline)
        end

      {port, {:exit_status, status}} when port == state.port ->
        {:error, {:exited, status}}
    after
      remaining -> {:error, :timeout}
    end
  end

  defp match_reply(line, id) do
    case JSON.decode(line) do
      {:ok, %{"id" => ^id, "result" => result}} -> {:ok, result}
      {:ok, %{"id" => ^id, "error" => error}} -> {:error, error}
      _ -> nil
    end
  end

  defp notify_server(state, method) do
    message = %{jsonrpc: "2.0", method: method}

    case state.config do
      %{"type" => "http"} ->
        case http_post(state, message) do
          {:ok, _, _} -> {:ok, state}
          error -> error
        end

      _ ->
        send_line(state, message)
        {:ok, state}
    end
  end

  @impl true
  def handle_call(:tools, _from, state), do: {:reply, state.tools, state}
  def handle_call(:config, _from, state), do: {:reply, state.config, state}

  def handle_call({:call, tool, args, timeout}, from, state) do
    {id, state} = next_id(state)

    message = %{
      jsonrpc: "2.0",
      id: id,
      method: "tools/call",
      params: %{name: tool, arguments: args}
    }

    case state.config do
      %{"type" => "http"} ->
        # Each HTTP call waits in its own task, replying when it's done.
        me = self()

        Task.start(fn ->
          reply =
            case http_post(state, message, timeout) do
              {:ok, replies, _} -> reply_of(Enum.find(replies, &(&1["id"] == id)))
              {:error, reason} -> {:error, reason}
            end

          GenServer.reply(from, reply)
          send(me, {:done, id})
        end)

        {:noreply, state}

      _ ->
        send_line(state, message)
        Process.send_after(self(), {:expire, id}, timeout)
        {:noreply, %{state | pending: Map.put(state.pending, id, from)}}
    end
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    {lines, rest} = split_lines(state.buffer <> data)
    state = Enum.reduce(lines, %{state | buffer: rest}, &handle_line/2)
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("MCP server #{state.name} exited (#{status})")
    for {_id, from} <- state.pending, do: GenServer.reply(from, {:error, :server_exited})
    {:stop, {:server_exited, status}, %{state | port: nil, pending: %{}}}
  end

  def handle_info({:expire, id}, state) do
    case Map.pop(state.pending, id) do
      {nil, _} ->
        {:noreply, state}

      {from, pending} ->
        GenServer.reply(from, {:error, :timeout})
        {:noreply, %{state | pending: pending}}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: stop_port(state)

  defp handle_line(line, state) do
    case JSON.decode(line) do
      # A reply to one of our calls.
      {:ok, %{"id" => id} = msg}
      when is_map_key(state.pending, id) and not is_map_key(msg, "method") ->
        {from, pending} = Map.pop(state.pending, id)
        GenServer.reply(from, reply_of(msg))
        %{state | pending: pending}

      # A request from the server: declined.
      {:ok, %{"id" => id, "method" => method}} ->
        send_line(state, %{
          jsonrpc: "2.0",
          id: id,
          error: %{code: -32601, message: "tiny-axe doesn't offer #{method}"}
        })

        state

      # Notifications, stray replies and log lines.
      _ ->
        state
    end
  end

  defp reply_of(%{"result" => result}), do: {:ok, result}
  defp reply_of(%{"error" => error}), do: {:error, {:mcp, error}}
  defp reply_of(nil), do: {:error, :no_reply}

  defp next_id(state), do: {state.next_id, %{state | next_id: state.next_id + 1}}

  defp send_line(state, message), do: Port.command(state.port, JSON.encode!(message) <> "\n")

  defp split_lines(buffer) do
    {complete, [rest]} = buffer |> String.split("\n") |> Enum.split(-1)
    {Enum.reject(complete, &(String.trim(&1) == "")), rest}
  end

  defp stop_port(%{os_pid: os_pid}) when is_integer(os_pid) do
    System.cmd("kill", ["-TERM", "--", "-#{os_pid}"], stderr_to_stdout: true)
    true
  end

  defp stop_port(_state), do: true

  ## Streamable HTTP

  # One POST; the reply is JSON or a short event stream holding JSON messages.
  defp http_post(state, message, timeout \\ @connect_timeout) do
    headers =
      Map.merge(state.config["headers"] || %{}, %{
        "accept" => "application/json, text/event-stream",
        "mcp-protocol-version" => @protocol
      })

    headers =
      if state.session, do: Map.put(headers, "mcp-session-id", state.session), else: headers

    case Req.post(state.config["url"],
           json: message,
           headers: headers,
           receive_timeout: timeout,
           retry: false,
           decode_body: false
         ) do
      {:ok, %Req.Response{status: status} = resp} when status in 200..202 ->
        session = resp |> Req.Response.get_header("mcp-session-id") |> List.first()
        {:ok, parse_body(resp), session}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_body(%Req.Response{body: body} = resp) do
    type = resp |> Req.Response.get_header("content-type") |> List.first("")

    cond do
      body in ["", nil] ->
        []

      type =~ "text/event-stream" ->
        for "data:" <> data <- String.split(body, "\n"),
            {:ok, msg} <- [JSON.decode(String.trim(data))],
            do: msg

      true ->
        case JSON.decode(body) do
          {:ok, list} when is_list(list) -> list
          {:ok, msg} -> [msg]
          _ -> []
        end
    end
  end
end
