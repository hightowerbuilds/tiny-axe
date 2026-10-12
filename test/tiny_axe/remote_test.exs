defmodule TinyAxe.RemoteTest do
  use ExUnit.Case, async: true

  alias TinyAxe.{FakeRealtime, Remote}

  # Real sockets on 127.0.0.1: under the whole suite's load a handshake can
  # take longer than assert_receive's default 100 ms.
  @wait 2_000

  # Asks again until `fun` holds (or @wait runs out), rather than sleeping a
  # fixed time that a loaded machine can outrun.
  defp eventually(fun, left \\ @wait) do
    cond do
      fun.() -> true
      left <= 0 -> false
      true -> Process.sleep(20) && eventually(fun, left - 20)
    end
  end

  # The fake is linked to the test, so it stops with it.
  setup do
    %{fake: FakeRealtime.start()}
  end

  defp start(fake, opts \\ []) do
    opts =
      Keyword.merge(
        [
          name: nil,
          enabled: true,
          url: fake.url,
          key: fn -> {:ok, fake.key} end,
          backoff: [20, 40]
        ],
        opts
      )

    {:ok, pid} = GenServer.start_link(Remote, opts)
    pid
  end

  # Waits for the join, then for tiny-axe to say it's online (presence track).
  defp online(pid) do
    assert_receive {:realtime, :socket, socket, _query}, @wait
    assert_receive {:realtime, :in, %{"event" => "phx_join"}}, @wait
    assert_receive {:realtime, :in, %{"event" => "presence"}}, @wait
    assert Remote.status(pid).phase == :online
    socket
  end

  defp flush do
    receive do
      {:remote, _} -> flush()
    after
      0 -> :ok
    end
  end

  defp row(id, status \\ "pending"),
    do: %{
      "id" => id,
      "role" => "user",
      "body" => "hello #{id}",
      "status" => status,
      "reply_to" => nil,
      "created_at" => "2026-10-12T12:00:00Z"
    }

  test "dials out, joins the owner's private channel with the session, and shows as online",
       %{fake: fake} do
    pid = start(fake)

    assert_receive {:realtime, :token, nil}, @wait
    assert_receive {:realtime, :socket, _socket, query}, @wait
    assert query == %{"apikey" => "public-key", "vsn" => "1.0.0"}

    assert_receive {:realtime, :in, %{"event" => "phx_join"} = join}, @wait
    assert join["topic"] == FakeRealtime.topic()
    assert join["payload"]["access_token"] == "session-1"
    assert join["payload"]["config"]["private"] == true
    assert join["payload"]["config"]["presence"]["key"] == "tiny-axe"

    assert_receive {:realtime, :in, %{"event" => "presence", "payload" => track}}, @wait
    assert track["event"] == "track"
    assert %{phase: :online, error: nil} = Remote.status(pid)
  end

  test "no site account yet: waits, and says why", %{fake: fake} do
    pid = start(fake, key: fn -> :error end)

    assert eventually(fn -> Remote.status(pid).phase == :waiting end)
    assert %{phase: :waiting, error: "no site account yet" <> _} = Remote.status(pid)
    refute_received {:realtime, :token, _}
  end

  test "a made-up key: keeps trying, never joins", %{fake: fake} do
    # A long first wait, so it's still waiting when asked.
    pid = start(fake, key: fn -> {:ok, "not-the-key"} end, backoff: [5_000])

    assert eventually(fn -> Remote.status(pid).phase == :waiting end)
    assert %{phase: :waiting, error: "ta-remote-token: 401" <> _} = Remote.status(pid)
    refute_received {:realtime, :socket, _, _}
  end

  test "takes up each waiting message, then hands it to subscribers once: those kept and those that arrive",
       %{fake: fake} do
    FakeRealtime.set(fake, :pending, [row("a"), row("b", "working")])
    pid = start(fake)
    socket = online(pid)

    assert Remote.subscribe(pid).phase == :online
    assert_receive {:realtime, :pending, "session-1"}, @wait
    assert_receive {:realtime, :reply, "session-1", %{"id" => "a", "status" => "working"}}, @wait
    assert_receive {:remote, {:message, %{id: "a", body: "hello a"}}}, @wait

    FakeRealtime.message(socket, row("c"))
    assert_receive {:realtime, :reply, _, %{"id" => "c", "status" => "working"}}, @wait
    assert_receive {:remote, {:message, %{id: "c"}}}, @wait

    # The same message again, its update to "working", tiny-axe's own reply,
    # or one another tiny-axe is working on (or was, before it stopped): nothing.
    FakeRealtime.message(socket, row("c"))
    FakeRealtime.message(socket, row("c", "working"))
    FakeRealtime.message(socket, %{row("d") | "role" => "assistant"})
    FakeRealtime.message(socket, row("e", "working"))
    Process.sleep(300)
    refute_received {:remote, {_, _}}
    for id <- ~w(b d e), do: refute_received({:realtime, :reply, _, %{"id" => ^id}})
  end

  test "two tiny-axes online: the one that loses the race leaves the message alone",
       %{fake: fake} do
    pid = start(fake, sweep: 30)
    Remote.subscribe(pid)
    socket = online(pid)

    FakeRealtime.set(fake, :reply_status, 409)
    FakeRealtime.message(socket, row("x"))
    assert_receive {:realtime, :reply, _, %{"id" => "x", "status" => "working"}}, @wait
    refute_receive {:remote, {:message, _}}, 100

    # Taken by the other: the sweep doesn't try again either.
    FakeRealtime.set(fake, :pending, [row("x")])
    assert_receive {:realtime, :pending, _}, @wait
    refute_receive {:realtime, :reply, _, %{"id" => "x"}}, 100
  end

  test "a message it couldn't take up yet is tried again on the next sweep", %{fake: fake} do
    pid = start(fake, sweep: 30)
    Remote.subscribe(pid)
    socket = online(pid)

    FakeRealtime.set(fake, :reply_status, 500)
    FakeRealtime.message(socket, row("y"))
    assert_receive {:realtime, :reply, _, %{"id" => "y", "status" => "working"}}, @wait

    FakeRealtime.set(fake, :reply_status, 200)
    FakeRealtime.set(fake, :pending, [row("y")])
    assert_receive {:remote, {:message, %{id: "y"}}}, @wait
  end

  test "nobody subscribed: nothing is taken, and a new subscriber gets what's waiting",
       %{fake: fake} do
    FakeRealtime.set(fake, :pending, [row("a")])
    pid = start(fake)
    socket = online(pid)

    FakeRealtime.message(socket, row("b"))
    refute_receive {:realtime, :pending, _}, 50

    FakeRealtime.set(fake, :pending, [row("a"), row("b")])
    Remote.subscribe(pid)
    assert_receive {:remote, {:message, %{id: "a"}}}, @wait
    assert_receive {:remote, {:message, %{id: "b"}}}, @wait

    # A subscriber that comes back (a restarted TUI) isn't handed one this
    # tiny-axe took up already; the page shows it was being worked on.
    Remote.subscribe(pid)
    assert_receive {:realtime, :pending, _}, @wait
    refute_receive {:remote, {:message, _}}, 100
  end

  test "a message the channel missed is still picked up: it asks again while online",
       %{fake: fake} do
    pid = start(fake, sweep: 30)
    Remote.subscribe(pid)
    online(pid)
    assert_receive {:realtime, :pending, _}, @wait

    FakeRealtime.set(fake, :pending, [row("missed")])
    assert_receive {:remote, {:message, %{id: "missed"}}}, @wait
    assert_receive {:realtime, :pending, _}, @wait
    refute_receive {:remote, {:message, _}}, 100
  end

  test "streams pieces on the channel and saves the reply, redacted", %{fake: fake} do
    pid = start(fake)
    online(pid)
    token = "sk_live_" <> String.duplicate("a1", 16)

    Remote.progress(pid, "a", "running a command")
    Remote.draft(pid, "a", "the key is #{token}")

    assert_receive {:realtime, :in, %{"event" => "broadcast", "payload" => status}}, @wait
    assert status["event"] == "status"
    assert status["payload"] == %{"reply_to" => "a", "text" => "running a command"}

    assert_receive {:realtime, :in, %{"event" => "broadcast", "payload" => draft}}, @wait
    assert draft["event"] == "draft"
    assert draft["payload"]["text"] == "the key is [token removed]"

    assert {:ok, _} = Remote.reply(pid, "a", "answered", "done: #{token}")
    assert_receive {:realtime, :reply, "session-1", reply}, @wait
    assert reply == %{"id" => "a", "status" => "answered", "body" => "done: [token removed]"}
  end

  test "the outbox: replies go in order, and one written offline goes once it's back",
       %{fake: fake} do
    pid = start(fake, enabled: false)
    Remote.send_reply(pid, "a", "working")
    Remote.send_reply(pid, "a", "answered", "done")
    refute_receive {:realtime, :reply, _, _}, 50

    # One this tiny-axe is replying to isn't taken up again.
    FakeRealtime.set(fake, :pending, [row("a")])
    Remote.subscribe(pid)
    Remote.connect(pid)

    assert_receive {:realtime, :reply, "session-1", %{"id" => "a", "status" => "working"}}, @wait
    assert_receive {:realtime, :reply, "session-1", %{"id" => "a", "status" => "answered"}}, @wait
    assert_receive {:realtime, :pending, _}, @wait
    refute_receive {:remote, {:message, _}}, 100
  end

  test "the outbox drops a reply the site will never take, and keeps one it couldn't send yet",
       %{fake: fake} do
    pid = start(fake)
    online(pid)

    FakeRealtime.set(fake, :reply_status, 409)
    Remote.send_reply(pid, "a", "answered", "late")
    Remote.send_reply(pid, "b", "answered", "next")
    assert_receive {:realtime, :reply, _, %{"id" => "a"}}, @wait
    assert_receive {:realtime, :reply, _, %{"id" => "b"}}, @wait

    FakeRealtime.set(fake, :reply_status, 500)
    Remote.send_reply(pid, "c", "answered", "kept")
    assert_receive {:realtime, :reply, _, %{"id" => "c"}}, @wait
    assert [%{id: "c"}] = :sys.get_state(pid).outbox
  end

  test "not connected: nothing to reply with, and pieces are dropped", %{fake: fake} do
    pid = start(fake, enabled: false)

    assert {:error, "not connected to the site"} = Remote.reply(pid, "a", "working")
    Remote.draft(pid, "a", "x")
    assert Remote.status(pid).phase == :off
    refute_receive {:realtime, _, _}, 50
  end

  test "a refused join tries again with a new session", %{fake: fake} do
    FakeRealtime.set(fake, :refuse_join, true)
    pid = start(fake, backoff: [300])

    assert_receive {:realtime, :token, nil}, @wait
    assert_receive {:realtime, :in, %{"event" => "phx_join"}}, @wait
    FakeRealtime.set(fake, :refuse_join, false)
    assert eventually(fn -> Remote.status(pid).phase == :waiting end)

    assert %{phase: :waiting, error: "Realtime refused the channel: Unauthorized"} =
             Remote.status(pid)

    assert_receive {:realtime, :token, nil}, @wait

    assert_receive {:realtime, :in,
                    %{"event" => "phx_join", "payload" => %{"access_token" => "session-2"}}},
                   @wait

    assert_receive {:realtime, :in, %{"event" => "presence"}}, @wait
  end

  test "the socket closing reconnects, keeping the session that's still good", %{fake: fake} do
    pid = start(fake)
    Remote.subscribe(pid)
    socket = online(pid)
    assert_receive {:realtime, :token, nil}, @wait
    flush()

    FakeRealtime.close(socket)
    assert_receive {:remote, {:status, :waiting}}, @wait
    assert_receive {:remote, {:status, :online}}, @wait

    assert_receive {:realtime, :in,
                    %{"event" => "phx_join", "payload" => %{"access_token" => "session-1"}}},
                   @wait

    refute_received {:realtime, :token, _}
  end

  test "a heartbeat with no reply means the connection is dead: reconnects", %{fake: fake} do
    pid = start(fake, heartbeat: 30)
    online(pid)
    assert_receive {:realtime, :in, %{"event" => "heartbeat", "topic" => "phoenix"}}, @wait

    FakeRealtime.set(fake, :silent_heartbeat, true)
    assert_receive {:realtime, :socket, _socket, _query}, @wait
    assert_receive {:realtime, :in, %{"event" => "phx_join"}}, @wait
    FakeRealtime.set(fake, :silent_heartbeat, false)
    assert_receive {:realtime, :in, %{"event" => "presence"}}, @wait
  end

  test "renews the session before it runs out, signing the old one out", %{fake: fake} do
    FakeRealtime.set(fake, :expires_in, 300)
    pid = start(fake, renew_floor: 30)
    online(pid)

    assert_receive {:realtime, :token, "session-1"}, @wait
    assert_receive {:realtime, :in, %{"event" => "access_token", "payload" => payload}}, @wait
    assert payload == %{"access_token" => "session-2"}
    assert Remote.status(pid).phase == :online
  end

  test "disconnect: off and stays off; connect: back", %{fake: fake} do
    pid = start(fake)
    Remote.subscribe(pid)
    online(pid)

    Remote.disconnect(pid)
    assert_receive {:remote, {:status, :off}}, @wait
    refute_receive {:realtime, :socket, _, _}, 100
    flush()

    Remote.connect(pid)
    assert_receive {:remote, {:status, :online}}, @wait
  end

  test "the session never shows in the process's state" do
    {:ok, pid} = GenServer.start_link(Remote, name: nil, enabled: false)
    :sys.replace_state(pid, &%{&1 | session: %{token: "secret-session"}})
    refute inspect(:sys.get_status(pid)) =~ "secret-session"
  end

  test "realtime_url: wss for https, the key and the protocol version in the query" do
    assert Remote.realtime_url("https://abc.supabase.co", "pk") ==
             "wss://abc.supabase.co/realtime/v1/websocket?apikey=pk&vsn=1.0.0"

    assert Remote.realtime_url("http://127.0.0.1:4001", "pk") =~ "ws://127.0.0.1:4001/realtime"
  end
end
