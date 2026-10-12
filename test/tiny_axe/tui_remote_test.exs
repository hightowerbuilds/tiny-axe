defmodule TinyAxe.TUIRemoteTest do
  use ExUnit.Case, async: true

  alias ExRatatui.Event
  alias TinyAxe.TUI
  alias TinyAxe.TUI.Chats

  @size {110, 32}

  # The test stands in for TinyAxe.Remote: what the TUI sends the site comes
  # here as {:remote_out, message}.
  defp mount do
    {:ok, state} = TUI.mount(test_mode: @size, remote: self())
    state
  end

  defp info(state, msg) do
    case TUI.handle_info(msg, state) do
      {:noreply, state} -> state
      {:noreply, state, _opts} -> state
    end
  end

  defp key(state, code) do
    {:noreply, state} =
      TUI.handle_event(%Event.Key{code: code, kind: "press", modifiers: []}, state)

    state
  end

  defp type(state, text) do
    ExRatatui.textarea_set_value(state.input, text)
    key(state, "enter")
  end

  defp status_bar(state), do: draw(state) |> String.split("\n") |> Enum.find(&(&1 =~ "ctx"))

  defp draw(state) do
    {w, h} = @size
    terminal = ExRatatui.init_test_terminal(w, h)
    ExRatatui.draw(terminal, TUI.render(state, %ExRatatui.Frame{width: w, height: h}))
    ExRatatui.get_buffer_content(terminal)
  end

  defp message(id, body \\ nil), do: %{id: id, body: body || "question #{id}", created_at: "now"}

  defp remote_id(state), do: Enum.find(state.chats.order, &Chats.get(state, &1).remote_chat)
  defp remote(state), do: Chats.get(state, remote_id(state))

  # The 🌐 chat's run is a real pipeline task; the test plays its events
  # instead, so the task is stopped and its id kept.
  defp take_run(state) do
    {id, pid} = remote(state).run
    Process.exit(pid, :kill)
    id
  end

  defp events(state, id, events), do: Enum.reduce(events, state, &info(&2, {:pipeline, id, &1}))

  defp metas(chat), do: for({:meta, text} <- chat.transcript, do: text)

  defp ask(extra) do
    ref = make_ref()
    {Map.merge(%{reply_to: self(), ref: ref}, extra), ref}
  end

  test "a message from the site is asked in a 🌐 chat of its own, aside; the chat on screen stays" do
    state = mount()
    shown = state.transcript
    state = info(state, {:remote, {:message, message("m1", "what's in this folder?")}})

    assert Chats.count(state) == 2
    assert Chats.position(state, state.chats.active) == 1
    assert state.transcript == shown
    assert state.run == nil

    chat = remote(state)
    assert {:user, "what's in this folder?"} in chat.transcript
    assert "🌐 from the site" in metas(chat)
    assert {_id, _pid} = chat.run
    assert Chats.title(state, remote_id(state), 30) =~ "🌐 what's in this folder?"
    # TinyAxe.Remote took it up before handing it over: no "working" from here.
    refute_received {:remote_out, {:reply, "m1", _, _}}
    take_run(state)
  end

  test "what it's doing and the reply so far go to the page; the answer is saved as the reply" do
    state = info(mount(), {:remote, {:message, message("m1")}})
    id = take_run(state)

    state = events(state, id, [{:attempt, 1}, {:stage, "generating…"}, {:delta, "Hel"}])
    assert_received {:remote_out, {:progress, "m1", "generating…"}}
    assert_received {:remote_out, {:draft, "m1", "Hel"}}

    # Pieces within 250 ms of the last wait for the next.
    state = events(state, id, [{:delta, "lo"}])
    refute_received {:remote_out, {:draft, "m1", _}}

    state = events(state, id, [{:done, "Hello."}])
    assert_received {:remote_out, {:reply, "m1", "answered", "Hello."}}
    assert state.remote_link.current == nil
    assert remote(state).run == nil
  end

  test "one at a time: the next waits, then goes in the same 🌐 chat" do
    state = info(mount(), {:remote, {:message, message("m1")}})
    id = take_run(state)
    state = info(state, {:remote, {:message, message("m2")}})
    # Handed out again (a resubscribe): still queued once.
    state = info(state, {:remote, {:message, message("m2")}})

    assert [%{id: "m2"}] = state.remote_link.queue
    assert {:user, "question m2"} not in remote(state).transcript

    state = events(state, id, [{:done, "First."}])
    assert_received {:remote_out, {:reply, "m1", "answered", "First."}}
    assert Chats.count(state) == 2
    assert {:user, "question m2"} in remote(state).transcript
    assert state.remote_link.queue == []
    take_run(state)
  end

  test "nobody at the machine: a tool call, a purchase and Claude are refused, and the reply says so" do
    state = info(mount(), {:remote, {:message, message("m1")}})
    id = take_run(state)

    {tool, tool_ref} =
      ask(%{tool: "github__create_issue", class: :outward, args: %{}, description: "x"})

    {buy, buy_ref} = ask(%{summary: %{"host" => "shop.example"}})
    {claude, claude_ref} = ask(%{to: "Claude Haiku"})

    state =
      events(state, id, [
        {:tool_approval, tool},
        {:purchase_approval, buy},
        {:ask_remote, claude}
      ])

    assert_received {:tool_answer, ^tool_ref, :deny}
    assert_received {:purchase_answer, ^buy_ref, :deny}
    assert_received {:remote_answer, ^claude_ref, false}
    assert state.tool_ask == nil and state.purchase_ask == nil and state.asking == nil
    assert state.waiting == []
    # Claude stays undecided for the chats at the machine.
    assert state.remote == nil

    state = events(state, id, [{:done, "Couldn't do it."}])
    assert_received {:remote_out, {:reply, "m1", "answered", body}}
    assert body =~ "Couldn't do it."
    assert body =~ "didn't use github__create_issue: it needs a yes at the machine"
    assert body =~ "didn't buy at shop.example"
    assert body =~ "sending it to Claude Haiku needs a yes at the machine"
  end

  test "a question from a chat at the machine is left for you" do
    run_id = make_ref()
    state = %{mount() | run: {run_id, spawn(fn -> Process.sleep(:infinity) end)}}
    state = info(state, {:remote, {:message, message("m1")}})
    take_run(state)

    {tool, tool_ref} = ask(%{tool: "fs__write", class: :local, args: %{}, description: "x"})
    state = info(state, {:pipeline, run_id, {:tool_approval, tool}})
    assert state.tool_ask.ref == tool_ref
    refute_received {:tool_answer, ^tool_ref, _}
  end

  test "commands that change things aren't run; the reply says which" do
    state = info(mount(), {:remote, {:message, message("m1")}})
    id = take_run(state)

    plan = %{commands: [%{command: "rm -r build"}], read_only: false, dir: "/tmp", check: nil}
    state = events(state, id, [{:command_plan, plan}, {:done, "Here's the plan."}])

    assert remote(state).pending_commands == nil
    assert "commands cancelled; nothing ran" in metas(remote(state))
    assert_received {:remote_out, {:reply, "m1", "answered", body}}
    assert body =~ "didn't run `rm -r build`"
  end

  test "a run that fails is a failed reply; the next message still goes" do
    state = info(mount(), {:remote, {:message, message("m1")}})
    id = take_run(state)
    state = info(state, {:remote, {:message, message("m2")}})

    state = events(state, id, [{:error, :timeout}])
    assert_received {:remote_out, {:reply, "m1", "failed", ":timeout"}}
    assert {:user, "question m2"} in remote(state).transcript
    take_run(state)
  end

  test "a card number in a message never reaches the model" do
    state = info(mount(), {:remote, {:message, message("m1", "pay with 4242 4242 4242 4242")}})
    assert {:user, "pay with [card number removed]"} in remote(state).transcript
    take_run(state)
  end

  test "/remote on, off, and how it stands; the status bar shows 🌐" do
    state = type(mount(), "/remote")
    assert List.last(state.transcript) == {:meta, "🌐 remote chat: off (/remote on)"}
    refute status_bar(state) =~ "🌐"

    state = type(state, "/remote on")
    assert_received {:remote_out, {:switch, true}}
    assert {:meta, "🌐 remote chat on: " <> _} = List.last(state.transcript)

    state = info(state, {:remote, {:status, :online}})
    assert state.status == "🌐 the site can reach this tiny-axe"
    assert status_bar(state) =~ "🌐"
    state = type(state, "/remote")
    assert List.last(state.transcript) == {:meta, "🌐 remote chat: on, online"}

    state = type(state, "/remote off")
    assert_received {:remote_out, {:switch, false}}
    assert {:meta, "🌐 remote chat off" <> _} = List.last(state.transcript)
  end
end
