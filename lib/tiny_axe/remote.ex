defmodule TinyAxe.Remote do
  @moduledoc """
  Remote chat (`docs/plan-remote-chat.md`): the site's /remote page talks to
  this tiny-axe through Supabase Realtime. Nothing reaches into the machine:
  this process dials out over a websocket, like a browser tab, and joins the
  owner's private channel `remote:<owner_id>`, where the page is too.

  - **The way in:** tiny-axe's site key (`TinyAxe.Account.key/0`) goes to
    the `ta-remote-token` edge function, which hands back a session of the
    key's owner. It's renewed five minutes before it runs out (the old one is
    signed out) and sent down the channel as `access_token`.
  - **Online:** once joined, tiny-axe tracks itself with Presence, which is
    the page's green dot, and sends a heartbeat every 25 s. A missed heartbeat
    reply, a closed socket or a refused join reconnects with backoff
    (1 s … 60 s); no account yet waits five minutes.
  - **Messages** are kept on the site, so none is lost while tiny-axe is off.
    On every join (and every `subscribe/1`) it asks `ta-remote-pending` for
    what it hasn't finished; new ones arrive on the channel as they're sent.
    It asks again every minute while online, in case the channel missed one
    (right after a join, Realtime's database broadcasts can take a moment).
    Each waiting message is taken up first (`ta-remote-reply` "working",
    which only works on a message still pending), then handed to
    subscribers as `{:remote, {:message, msg}}`, once; `msg` is
    `%{id:, body:, created_at:}`. With two tiny-axes online (two windows),
    one takes each message and the other leaves it. Nobody subscribed:
    nothing is taken, the message waits. One left "working" by a tiny-axe
    that stopped stays that way (the page says so); it's never run again
    blind.
  - **Answering:** `progress/3` (what tiny-axe is doing) and `draft/3` (the
    reply so far) go straight out on the channel; they're not kept.
    `send_reply/4` saves where a message stands and its reply through
    `ta-remote-reply`, from an outbox: in order, and kept until the site has
    it, so a reply written while offline goes once tiny-axe is back. Everything is
    redacted (`Tools.Redact.secrets/1`) before it leaves.

  - **Approvals** (`docs/plan-chrome-purchases.md`, P3): `open_approval/3`
    puts a card on the Chat tab (`ta-remote-approval`, with the site key, not
    the session), and the caller gets `{:remote, {:approval_opened, ref,
    approval}}` or `{:approval_failed, ref, why}`. While one waits, it's read
    back when the channel says it changed and every 3 s anyway; once it's
    answered the caller gets `{:remote, {:approval_answer, id, approval}}`
    (with the answer, whose proof only the key can read). `close_approval/3`
    records tiny-axe's word on it.

  `{:remote, {:status, phase}}` goes to subscribers whenever the phase
  changes: `:off`, `:connecting`, `:joining`, `:online` or `:waiting` (with
  `status/1`'s `error` saying why).

  On or off: `/remote on|off` in the TUI (`set_on/1`, kept in
  `<state_dir>/remote.json`), or `config :tiny_axe, :remote, enabled: true`;
  off by default. `url:` is the Supabase project (`TINY_AXE_SUPABASE_URL`
  overrides it).
  """

  use GenServer

  require Logger

  alias TinyAxe.Remote.{Api, Socket}
  alias TinyAxe.Tools.Redact

  @backoff [1_000, 2_000, 5_000, 10_000, 30_000, 60_000]
  @heartbeat 25_000
  @sweep 60_000
  @no_account 5 * 60_000
  # Renew a session this many seconds before it runs out.
  @renew_before 300
  @presence_key "tiny-axe"
  @approval_poll 3_000

  @type phase :: :off | :connecting | :joining | :online | :waiting

  @doc """
  Options (for tests): `:name`, `:enabled`, `:url`, `:key` (a function
  returning `{:ok, key} | :error`), `:backoff` (ms list), `:heartbeat` (ms),
  `:renew_floor` (the soonest a renewal happens, ms), `:sweep` (ms between
  asking for waiting messages while online).
  """
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Whether it connects when tiny-axe starts."
  def enabled?, do: Keyword.get(settings(), :enabled, false) or on?()

  @doc "Whether `/remote on` was the last word."
  def on? do
    with {:ok, text} <- File.read(path()),
         {:ok, %{"on" => true}} <- JSON.decode(text) do
      true
    else
      _ -> false
    end
  end

  @doc "Remembers `/remote on` or `off` for the next start."
  @spec set_on(boolean()) :: :ok | {:error, term()}
  def set_on(on) when is_boolean(on) do
    with :ok <- File.mkdir_p(Path.dirname(path())),
         do: File.write(path(), JSON.encode!(%{on: on}))
  end

  def path, do: Path.join(TinyAxe.Ops.Journal.state_dir(), "remote.json")

  @doc "The Supabase project's address, without a trailing slash."
  def url do
    (System.get_env("TINY_AXE_SUPABASE_URL") || settings()[:url] ||
       "https://gbnizxzurmbzeelacztr.supabase.co")
    |> String.trim_trailing("/")
  end

  defp settings, do: Application.get_env(:tiny_axe, :remote, [])

  @doc "Where it stands: `%{phase:, error:}`."
  @spec status(GenServer.server()) :: %{phase: phase(), error: String.t() | nil}
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc "Connects (if it isn't already)."
  def connect(server \\ __MODULE__), do: GenServer.call(server, :connect)

  @doc "Disconnects and stays off."
  def disconnect(server \\ __MODULE__), do: GenServer.call(server, :disconnect)

  @doc """
  The calling process gets messages and status changes (see the moduledoc)
  until it exits or unsubscribes. Messages waiting are handed out again.
  """
  @spec subscribe(GenServer.server()) :: %{phase: phase(), error: String.t() | nil}
  def subscribe(server \\ __MODULE__), do: GenServer.call(server, {:subscribe, self()})

  def unsubscribe(server \\ __MODULE__), do: GenServer.call(server, {:unsubscribe, self()})

  @doc "The reply to `id` so far, as it's written (not kept)."
  def draft(server \\ __MODULE__, id, text),
    do: GenServer.cast(server, {:broadcast, "draft", %{reply_to: id, text: Redact.secrets(text)}})

  @doc "What tiny-axe is doing about `id` (\"running a command\"; not kept)."
  def progress(server \\ __MODULE__, id, text),
    do:
      GenServer.cast(server, {:broadcast, "status", %{reply_to: id, text: Redact.secrets(text)}})

  @doc """
  Saves where message `id` stands (`"working"`, `"answered"`, `"failed"`) and
  its reply, through the outbox (see the moduledoc). Returns at once.
  """
  @spec send_reply(GenServer.server(), String.t(), String.t(), String.t() | nil) :: :ok
  def send_reply(server \\ __MODULE__, id, status, body \\ nil),
    do:
      GenServer.cast(
        server,
        {:outbox, %{id: id, status: status, body: body && Redact.secrets(body)}}
      )

  @doc """
  Opens an approval on the Chat tab (`params`: `message_id`, `kind`, `body`,
  `nonce`, `salt`, `iterations`, `expires_in`). The answer comes as messages
  to the caller (see the moduledoc), tagged with `ref`.
  """
  def open_approval(server \\ __MODULE__, ref, params),
    do: GenServer.cast(server, {:open_approval, self(), ref, params})

  @doc "tiny-axe's word on an approval (`approved`, `denied`, `wrong_pin`, `expired`, `withdrawn`, `refused`)."
  def close_approval(server \\ __MODULE__, id, outcome),
    do: GenServer.cast(server, {:close_approval, id, outcome})

  @doc """
  Saves where message `id` stands and its reply now, and says how it went.
  Runs in the caller, so a slow site never holds up this process.
  """
  @spec reply(GenServer.server(), String.t(), String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, String.t()}
  def reply(server \\ __MODULE__, id, status, body \\ nil) do
    case GenServer.call(server, :session) do
      {:ok, base, session} -> Api.reply(base, session, id, status, body && Redact.secrets(body))
      :error -> {:error, "not connected to the site"}
    end
  end

  ## Server

  @impl true
  def init(opts) do
    state = %{
      url: opts[:url] || url(),
      key: opts[:key] || (&TinyAxe.Account.key/0),
      backoff: opts[:backoff] || @backoff,
      heartbeat: opts[:heartbeat] || @heartbeat,
      renew_floor: opts[:renew_floor] || 30_000,
      sweep: opts[:sweep] || @sweep,
      phase: :off,
      error: nil,
      # Bumped on every teardown: timers and tasks from before are ignored.
      gen: 0,
      socket: nil,
      session: nil,
      ref: 0,
      join_ref: nil,
      beat: nil,
      timers: %{},
      attempt: 0,
      subscribers: %{},
      seen: MapSet.new(),
      # Replies waiting to go, oldest first, and the one being sent.
      outbox: [],
      sending: nil,
      # Messages this tiny-axe has taken up or replied to: never handed out
      # again.
      claimed: MapSet.new(),
      # Approvals waiting for an answer: id => the pid that opened it.
      approvals: %{},
      approval_poll: opts[:approval_poll] || @approval_poll,
      polling: false
    }

    if Keyword.get(opts, :enabled, enabled?()),
      do: {:ok, state, {:continue, :connect}},
      else: {:ok, state}
  end

  @impl true
  def handle_continue(:connect, s), do: {:noreply, start(s)}

  @impl true
  def format_status(status),
    do: Map.update(status, :state, nil, &if(is_map(&1), do: %{&1 | session: :redacted}, else: &1))

  @impl true
  def handle_call(:status, _from, s), do: {:reply, %{phase: s.phase, error: s.error}, s}

  def handle_call(:connect, _from, %{phase: :off} = s), do: {:reply, :ok, start(s)}
  def handle_call(:connect, _from, s), do: {:reply, :ok, s}

  def handle_call(:disconnect, _from, s),
    do: {:reply, :ok, s |> teardown() |> Map.put(:attempt, 0) |> phase(:off, nil)}

  def handle_call({:subscribe, pid}, _from, s) do
    s =
      if Map.has_key?(s.subscribers, pid),
        do: s,
        else: put_in(s.subscribers[pid], Process.monitor(pid))

    s = %{s | seen: MapSet.new()}
    s = if s.phase == :online, do: catch_up(s), else: s
    {:reply, %{phase: s.phase, error: s.error}, s}
  end

  def handle_call({:unsubscribe, pid}, _from, s) do
    {ref, subscribers} = Map.pop(s.subscribers, pid)
    if ref, do: Process.demonitor(ref, [:flush])
    {:reply, :ok, %{s | subscribers: subscribers}}
  end

  def handle_call(:session, _from, s) do
    if fresh?(s.session, 30),
      do: {:reply, {:ok, s.url, s.session.token}, s},
      else: {:reply, :error, s}
  end

  @impl true
  def handle_cast({:broadcast, event, payload}, %{phase: :online} = s),
    do:
      {:noreply,
       push(s, s.session.topic, "broadcast", %{type: "broadcast", event: event, payload: payload})}

  def handle_cast({:broadcast, _event, _payload}, s), do: {:noreply, s}

  def handle_cast({:open_approval, pid, ref, params}, s) do
    me = self()

    approval_task(s, fn base, key ->
      send(
        me,
        {:approval_opened, pid, ref, Api.approval(base, key, Map.put(params, :action, "open"))}
      )
    end)

    {:noreply, s}
  end

  def handle_cast({:close_approval, id, outcome}, s) do
    approval_task(s, fn base, key ->
      case Api.approval(base, key, %{action: "close", id: id, outcome: outcome}) do
        {:ok, _} -> :ok
        {:error, reason} -> Logger.info("remote approvals: couldn't close #{id}: #{reason}")
      end
    end)

    {:noreply, %{s | approvals: Map.delete(s.approvals, id)}}
  end

  def handle_cast({:outbox, item}, s),
    do:
      {:noreply,
       flush(%{s | outbox: s.outbox ++ [item], claimed: MapSet.put(s.claimed, item.id)})}

  @impl true
  def handle_info({:token, gen, renewal?, result}, %{gen: gen} = s),
    do: {:noreply, token(s, renewal?, result)}

  def handle_info({:pending, gen, {:ok, %{"messages" => messages}}}, %{gen: gen} = s),
    do: {:noreply, Enum.reduce(messages, s, &deliver(&2, &1))}

  def handle_info({:pending, gen, {:error, reason}}, %{gen: gen} = s) do
    Logger.warning("remote chat: couldn't ask for waiting messages: #{reason}")
    {:noreply, s}
  end

  def handle_info({:reconnect, gen}, %{gen: gen} = s), do: {:noreply, start(s)}

  def handle_info({:sent, ref, result}, %{sending: ref, outbox: [item | rest]} = s) do
    case result do
      {:ok, _} ->
        {:noreply, flush(%{s | outbox: rest, sending: nil})}

      # The site will never take it (an unknown message, or one already settled).
      {:error, "ta-remote-reply: " <> code = reason}
      when binary_part(code, 0, 3) in ["404", "409"] ->
        Logger.warning("remote chat: dropped the reply to #{item.id}: #{reason}")
        {:noreply, flush(%{s | outbox: rest, sending: nil})}

      {:error, reason} ->
        Logger.warning("remote chat: couldn't send a reply yet: #{reason}")
        Process.send_after(self(), :flush, 30_000)
        {:noreply, %{s | sending: nil}}
    end
  end

  def handle_info({:sent, _stale, _result}, s), do: {:noreply, s}

  def handle_info({:taken, msg, result}, s) do
    case result do
      {:ok, _} ->
        for pid <- Map.keys(s.subscribers), do: send(pid, {:remote, {:message, msg}})
        {:noreply, %{s | claimed: MapSet.put(s.claimed, msg.id)}}

      # Another tiny-axe took it (or it's settled): leave it.
      {:error, "ta-remote-reply: 409" <> _} ->
        Logger.info("remote chat: #{msg.id} was taken by another tiny-axe")
        {:noreply, s}

      # Try again on the next sweep.
      {:error, reason} ->
        Logger.warning("remote chat: couldn't take up a message yet: #{reason}")
        {:noreply, %{s | seen: MapSet.delete(s.seen, msg.id)}}
    end
  end

  def handle_info(:flush, s), do: {:noreply, flush(s)}

  def handle_info({:approval_opened, pid, ref, result}, s) do
    case result do
      {:ok, %{"approval" => %{"id" => id} = approval}} ->
        send(pid, {:remote, {:approval_opened, ref, approval}})
        {:noreply, poll_soon(%{s | approvals: Map.put(s.approvals, id, pid)})}

      {:ok, _} ->
        send(pid, {:remote, {:approval_failed, ref, "the site's answer had no approval"}})
        {:noreply, s}

      {:error, reason} ->
        send(pid, {:remote, {:approval_failed, ref, reason}})
        {:noreply, s}
    end
  end

  def handle_info(:poll_approvals, s) do
    s = %{s | polling: false}
    Enum.each(Map.keys(s.approvals), &read_approval(s, &1))
    {:noreply, poll_soon(s)}
  end

  def handle_info({:approval_read, id, result}, s) do
    case {Map.fetch(s.approvals, id), result} do
      {{:ok, pid}, {:ok, %{"approval" => %{"status" => status} = approval}}}
      when status in ["answered", "closed"] ->
        send(pid, {:remote, {:approval_answer, id, approval}})
        {:noreply, %{s | approvals: Map.delete(s.approvals, id)}}

      # Gone from the site: nobody can answer it now.
      {{:ok, pid}, {:error, "ta-remote-approval: 404" <> _}} ->
        send(pid, {:remote, {:approval_answer, id, %{"id" => id, "status" => "closed"}}})
        {:noreply, %{s | approvals: Map.delete(s.approvals, id)}}

      _ ->
        {:noreply, s}
    end
  end

  def handle_info({:beat, gen}, %{gen: gen, beat: nil} = s) do
    {ref, s} = next_ref(s)
    s = %{s | beat: ref}
    s = send_json(s, %{topic: "phoenix", event: "heartbeat", payload: %{}, ref: ref})
    {:noreply, if(s.socket, do: timer(s, :beat, {:beat, s.gen}, s.heartbeat), else: s)}
  end

  def handle_info({:beat, gen}, %{gen: gen} = s),
    do: {:noreply, retry(s, "the site stopped answering")}

  def handle_info({:sweep, gen}, %{gen: gen} = s),
    do: {:noreply, s |> catch_up() |> timer(:sweep, {:sweep, gen}, s.sweep)}

  def handle_info({:renew, gen}, %{gen: gen} = s),
    do: {:noreply, fetch_token(s, s.session && s.session.token)}

  def handle_info({:DOWN, ref, :process, pid, _reason}, s) do
    case s.subscribers do
      %{^pid => ^ref} -> {:noreply, %{s | subscribers: Map.delete(s.subscribers, pid)}}
      _ -> {:noreply, s}
    end
  end

  # A stale timer or task (from before a teardown).
  def handle_info({tag, _gen, _}, s) when tag in [:pending], do: {:noreply, s}
  def handle_info({tag, _gen, _, _}, s) when tag in [:token], do: {:noreply, s}

  def handle_info({tag, _gen}, s) when tag in [:reconnect, :beat, :renew, :sweep],
    do: {:noreply, s}

  def handle_info(message, %{socket: socket} = s) when socket != nil do
    case Socket.stream(socket, message) do
      :unknown -> {:noreply, s}
      {:ok, socket, events} -> {:noreply, events(%{s | socket: socket}, events)}
      {:error, socket, reason} -> {:noreply, retry(%{s | socket: socket}, describe(reason))}
    end
  end

  def handle_info(_message, s), do: {:noreply, s}

  @impl true
  def terminate(_reason, s), do: Socket.close(s.socket)

  ## Connecting

  defp start(s) do
    s = s |> teardown() |> phase(:connecting, s.error)
    if fresh?(s.session, @renew_before), do: open(s), else: fetch_token(s, nil)
  end

  defp fetch_token(s, previous) do
    me = self()
    %{gen: gen, key: key, url: base} = s

    Task.Supervisor.start_child(TinyAxe.TaskSupervisor, fn ->
      result =
        case key.() do
          {:ok, key} -> Api.token(base, key, previous)
          :error -> {:error, :no_key}
        end

      send(me, {:token, gen, previous != nil, result})
    end)

    s
  end

  defp token(
         s,
         renewal?,
         {:ok, %{"access_token" => token, "expires_at" => expires, "topic" => topic} = body}
       ) do
    session = %{token: token, expires_at: expires, topic: topic, apikey: body["apikey"]}
    s = %{s | session: session}

    if renewal? do
      s
      |> push(topic, "access_token", %{access_token: token})
      |> renew_timer()
    else
      open(s)
    end
  end

  defp token(s, _renewal?, {:error, :no_key}) do
    s = s |> teardown() |> phase(:waiting, "no site account yet (/account)")
    timer(s, :retry, {:reconnect, s.gen}, @no_account)
  end

  defp token(s, true, {:error, reason}) do
    Logger.warning("remote chat: couldn't renew the session: #{reason}")

    if fresh?(s.session, 60),
      do: timer(s, :renew, {:renew, s.gen}, 30_000),
      else: retry(%{s | session: nil}, reason)
  end

  defp token(s, false, {:error, reason}), do: retry(s, reason)
  defp token(s, _renewal?, {:ok, _}), do: retry(s, "ta-remote-token: an answer without a session")

  defp open(s) do
    case Socket.connect(realtime_url(s.url, s.session.apikey)) do
      {:ok, socket} -> %{s | socket: socket}
      {:error, reason} -> retry(s, "couldn't reach Realtime: #{describe(reason)}")
    end
  end

  @doc false
  def realtime_url(base, apikey) do
    uri = URI.parse(base)
    scheme = if uri.scheme == "https", do: "wss", else: "ws"
    query = URI.encode_query(apikey: apikey || "", vsn: "1.0.0")
    "#{scheme}://#{uri.authority}/realtime/v1/websocket?#{query}"
  end

  ## What comes down the socket

  defp events(s, []), do: s
  # A retry midway closed the socket: the rest is moot.
  defp events(%{socket: nil} = s, _events), do: s
  defp events(s, [event | rest]), do: s |> event(event) |> events(rest)

  defp event(s, :open), do: join(s)

  defp event(s, {:closed, reason}),
    do: retry(s, "Realtime closed the connection (#{describe(reason)})")

  defp event(s, {:text, text}) do
    case JSON.decode(text) do
      {:ok, %{} = message} -> frame(s, message)
      _ -> s
    end
  end

  defp join(s) do
    {ref, s} = next_ref(s)
    s = %{s | join_ref: ref} |> phase(:joining, s.error)

    payload = %{
      config: %{
        broadcast: %{self: false, ack: false},
        presence: %{key: @presence_key, enabled: true},
        postgres_changes: [],
        private: true
      },
      access_token: s.session.token
    }

    send_json(s, %{
      topic: "realtime:" <> s.session.topic,
      event: "phx_join",
      payload: payload,
      ref: ref,
      join_ref: ref
    })
  end

  defp frame(%{join_ref: ref} = s, %{"event" => "phx_reply", "ref" => ref, "payload" => payload}) do
    case payload do
      %{"status" => "ok"} ->
        Logger.info("remote chat: online")

        %{s | attempt: 0}
        |> phase(:online, nil)
        |> push(s.session.topic, "presence", %{
          type: "presence",
          event: "track",
          payload: %{online_at: DateTime.utc_now() |> DateTime.to_iso8601()}
        })
        |> timer(:beat, {:beat, s.gen}, s.heartbeat)
        |> timer(:sweep, {:sweep, s.gen}, s.sweep)
        |> renew_timer()
        |> flush()
        |> catch_up()

      other ->
        reason = get_in(other, ["response", "reason"]) || "refused"
        # A refused session gets a new one next time.
        retry(%{s | session: nil}, "Realtime refused the channel: #{reason}")
    end
  end

  defp frame(%{beat: ref} = s, %{"event" => "phx_reply", "ref" => ref}), do: %{s | beat: nil}

  defp frame(s, %{
         "event" => "broadcast",
         "payload" => %{"event" => "message", "payload" => message}
       }),
       do: deliver(s, message)

  # The page answered an approval: read it back now, with the key.
  defp frame(s, %{
         "event" => "broadcast",
         "payload" => %{"event" => "approval", "payload" => %{"id" => id, "status" => "answered"}}
       }) do
    if Map.has_key?(s.approvals, id), do: read_approval(s, id)
    s
  end

  defp frame(s, %{"event" => event}) when event in ["phx_error", "phx_close"],
    do: retry(s, "the channel closed (#{event})")

  defp frame(s, %{"event" => "system", "payload" => %{"status" => "error"} = payload}) do
    message = payload["message"] || "error"
    s = if message =~ ~r/token|jwt|expired/i, do: %{s | session: nil}, else: s
    retry(s, "Realtime: #{message}")
  end

  defp frame(s, _message), do: s

  ## Messages

  defp catch_up(%{subscribers: subscribers} = s) when map_size(subscribers) == 0, do: s

  defp catch_up(s) do
    me = self()
    %{gen: gen, url: base, session: %{token: token}} = s

    Task.Supervisor.start_child(TinyAxe.TaskSupervisor, fn ->
      send(me, {:pending, gen, Api.pending(base, token)})
    end)

    s
  end

  # A message waiting, not yet taken (or being taken) by this tiny-axe: take
  # it up, then hand it out (see :taken).
  defp deliver(s, %{"role" => "user", "id" => id, "status" => "pending"} = message)
       when map_size(s.subscribers) > 0 do
    if MapSet.member?(s.claimed, id) or MapSet.member?(s.seen, id) or not fresh?(s.session, 30) do
      s
    else
      me = self()
      msg = %{id: id, body: message["body"], created_at: message["created_at"]}
      %{url: base, session: %{token: token}} = s

      Task.Supervisor.start_child(TinyAxe.TaskSupervisor, fn ->
        send(me, {:taken, msg, Api.reply(base, token, id, "working")})
      end)

      %{s | seen: MapSet.put(s.seen, id)}
    end
  end

  defp deliver(s, _message), do: s

  # Sends the oldest reply waiting, one at a time so they arrive in order.
  defp flush(%{sending: nil, outbox: [item | _]} = s) do
    if fresh?(s.session, 30) do
      me = self()
      ref = make_ref()
      %{url: base, session: %{token: token}} = s

      Task.Supervisor.start_child(TinyAxe.TaskSupervisor, fn ->
        send(me, {:sent, ref, Api.reply(base, token, item.id, item.status, item.body)})
      end)

      %{s | sending: ref}
    else
      s
    end
  end

  defp flush(s), do: s

  ## Approvals

  defp approval_task(s, fun) do
    base = s.url
    key = s.key

    Task.Supervisor.start_child(TinyAxe.TaskSupervisor, fn ->
      case key.() do
        {:ok, k} -> fun.(base, k)
        _ -> fun.(base, "")
      end
    end)
  end

  defp read_approval(s, id) do
    me = self()

    approval_task(s, fn base, key ->
      send(me, {:approval_read, id, Api.approval(base, key, %{action: "get", id: id})})
    end)
  end

  defp poll_soon(%{polling: false, approvals: approvals} = s) when map_size(approvals) > 0 do
    Process.send_after(self(), :poll_approvals, s.approval_poll)
    %{s | polling: true}
  end

  defp poll_soon(s), do: s

  ## Plumbing

  defp push(s, topic, event, payload) do
    {ref, s} = next_ref(s)

    send_json(s, %{
      topic: "realtime:" <> topic,
      event: event,
      payload: payload,
      ref: ref,
      join_ref: s.join_ref
    })
  end

  defp send_json(%{socket: nil} = s, _message), do: s

  defp send_json(s, message) do
    case Socket.send_text(s.socket, JSON.encode!(message)) do
      {:ok, socket} ->
        %{s | socket: socket}

      {:error, socket, reason} ->
        retry(%{s | socket: socket}, "couldn't send: #{describe(reason)}")
    end
  end

  defp next_ref(s), do: {Integer.to_string(s.ref + 1), %{s | ref: s.ref + 1}}

  defp retry(s, reason) do
    delay = Enum.at(s.backoff, s.attempt, List.last(s.backoff))
    Logger.info("remote chat: #{reason}; trying again in #{max(div(delay, 1000), 1)} s")
    s = s |> teardown() |> phase(:waiting, reason)
    timer(%{s | attempt: s.attempt + 1}, :retry, {:reconnect, s.gen}, delay)
  end

  defp teardown(s) do
    Socket.close(s.socket)
    for {_name, ref} <- s.timers, do: Process.cancel_timer(ref)
    %{s | socket: nil, join_ref: nil, beat: nil, timers: %{}, gen: s.gen + 1}
  end

  defp timer(s, name, message, ms),
    do: put_in(s.timers[name], Process.send_after(self(), message, ms))

  defp renew_timer(%{session: %{expires_at: expires}} = s) do
    seconds = expires - System.os_time(:second) - @renew_before
    timer(s, :renew, {:renew, s.gen}, max(seconds * 1000, s.renew_floor))
  end

  defp fresh?(%{expires_at: expires}, margin) when is_integer(expires),
    do: expires - System.os_time(:second) > margin

  defp fresh?(_session, _margin), do: false

  defp phase(%{phase: phase, error: error} = s, phase, error), do: s

  defp phase(s, phase, error) do
    for pid <- Map.keys(s.subscribers), do: send(pid, {:remote, {:status, phase}})
    %{s | phase: phase, error: error}
  end

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(%{__exception__: true} = e), do: Exception.message(e)
  defp describe(reason), do: inspect(reason)
end
