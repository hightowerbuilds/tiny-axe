defmodule TinyAxe.FakeRealtime do
  @moduledoc """
  Supabase as `TinyAxe.Remote` sees it, on 127.0.0.1: the `ta-remote-*` edge
  functions and a Realtime websocket speaking Phoenix channels (vsn 1.0.0).

  Everything that arrives is sent to the test process that started it:

    * `{:realtime, :token, previous}` — a session asked for (`previous` or nil);
    * `{:realtime, :pending, session}`, `{:realtime, :reply, session, body}`;
    * `{:realtime, :socket, pid, query}` — a websocket opened (`query` decoded);
    * `{:realtime, :in, message}` — each frame tiny-axe sends, decoded.

  Sessions are `"session-1"`, `"session-2"`, … in order. `set/3` changes how
  it behaves: `:pending` (the waiting messages), `:refuse_join`,
  `:silent_heartbeat`, `:expires_in` (seconds), `:reply_status` (what
  `ta-remote-reply` answers: 200, or an error status). `message/2` puts a
  `buster_ta_remote` row on the socket, as the table's trigger would;
  `close/1` closes the socket from the server's end.

  `start/0` returns `%{url:, key:, control:, stop:}`.
  """

  @behaviour Plug

  @key String.duplicate("k", 43)
  @owner "owner-1"

  def start do
    {:ok, control} =
      Agent.start_link(fn ->
        %{
          tokens: 0,
          pending: [],
          refuse_join: false,
          silent_heartbeat: false,
          expires_in: 3600,
          reply_status: 200
        }
      end)

    plug = {__MODULE__, %{test: self(), control: control}}
    {:ok, pid} = Bandit.start_link(plug: plug, ip: {127, 0, 0, 1}, port: 0, startup_log: false)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)

    %{
      url: "http://127.0.0.1:#{port}",
      key: @key,
      control: control,
      stop: fn -> Supervisor.stop(pid) end
    }
  end

  def set(%{control: control}, key, value), do: Agent.update(control, &Map.put(&1, key, value))

  def topic, do: "realtime:remote:" <> @owner

  def message(socket, row) do
    send(
      socket,
      {:send,
       %{
         topic: topic(),
         event: "broadcast",
         payload: %{type: "broadcast", event: "message", payload: row},
         ref: nil
       }}
    )
  end

  def close(socket), do: send(socket, :close)

  ## Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{request_path: "/realtime/v1/websocket"} = conn, opts) do
    query = URI.decode_query(conn.query_string)

    conn
    |> Plug.Conn.upgrade_adapter(
      :websocket,
      {__MODULE__.Socket, Map.put(opts, :query, query), []}
    )
    |> Plug.Conn.halt()
  end

  def call(%Plug.Conn{request_path: "/functions/v1/" <> function, method: "POST"} = conn, opts) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    body = if body == "", do: %{}, else: JSON.decode!(body)

    bearer =
      case Plug.Conn.get_req_header(conn, "authorization") do
        ["Bearer " <> value] -> value
        _ -> nil
      end

    function(conn, function, bearer, body, opts)
  end

  def call(conn, _opts), do: Plug.Conn.send_resp(conn, 404, "")

  defp function(conn, "ta-remote-token", @key, body, %{test: test, control: control}) do
    send(test, {:realtime, :token, body["previous"]})

    {n, expires_in} =
      Agent.get_and_update(control, fn c ->
        {{c.tokens + 1, c.expires_in}, %{c | tokens: c.tokens + 1}}
      end)

    reply(conn, 200, %{
      access_token: "session-#{n}",
      expires_at: System.os_time(:second) + expires_in,
      owner_id: @owner,
      topic: "remote:" <> @owner,
      apikey: "public-key"
    })
  end

  defp function(conn, "ta-remote-token", _bearer, _body, _opts),
    do: reply(conn, 401, %{error: "A valid tiny-axe key is needed"})

  defp function(conn, function, "session-" <> _ = session, body, %{test: test, control: control}) do
    case function do
      "ta-remote-pending" ->
        send(test, {:realtime, :pending, session})
        reply(conn, 200, %{messages: Agent.get(control, & &1.pending)})

      "ta-remote-reply" ->
        send(test, {:realtime, :reply, session, body})

        case Agent.get(control, & &1.reply_status) do
          200 ->
            reply(conn, 200, %{message: %{id: body["id"], status: body["status"]}, reply: nil})

          status ->
            reply(conn, status, %{error: "no"})
        end

      _ ->
        Plug.Conn.send_resp(conn, 404, "")
    end
  end

  defp function(conn, _function, _bearer, _body, _opts),
    do: reply(conn, 401, %{error: "Sign in first."})

  defp reply(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, JSON.encode!(body))
  end

  defmodule Socket do
    @moduledoc false
    @behaviour WebSock

    @impl true
    def init(state) do
      send(state.test, {:realtime, :socket, self(), state.query})
      {:ok, state}
    end

    @impl true
    def handle_in({text, opcode: :text}, state) do
      message = JSON.decode!(text)
      send(state.test, {:realtime, :in, message})
      # The test ended (and the control with it) while tiny-axe was still talking.
      control = if Process.alive?(state.control), do: Agent.get(state.control, & &1), else: %{}

      case message do
        %{"event" => "phx_join", "ref" => ref, "topic" => topic} ->
          payload =
            if control[:refuse_join],
              do: %{status: "error", response: %{reason: "Unauthorized"}},
              else: %{status: "ok", response: %{}}

          reply(state, topic, ref, payload)

        %{"event" => "heartbeat", "ref" => ref} ->
          if control[:silent_heartbeat],
            do: {:ok, state},
            else: reply(state, "phoenix", ref, %{status: "ok", response: %{}})

        _ ->
          {:ok, state}
      end
    end

    @impl true
    def handle_info({:send, message}, state), do: {:push, {:text, JSON.encode!(message)}, state}
    def handle_info(:close, state), do: {:stop, :normal, state}

    @impl true
    def terminate(_reason, _state), do: :ok

    defp reply(state, topic, ref, payload) do
      frame = %{topic: topic, event: "phx_reply", payload: payload, ref: ref, join_ref: ref}
      {:push, {:text, JSON.encode!(frame)}, state}
    end
  end
end
