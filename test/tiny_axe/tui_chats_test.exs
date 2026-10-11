defmodule TinyAxe.TUIChatsTest do
  use ExUnit.Case, async: true

  alias ExRatatui.Event
  alias TinyAxe.TUI
  alias TinyAxe.TUI.Chats

  @size {110, 32}

  defp draw(state) do
    {w, h} = @size
    terminal = ExRatatui.init_test_terminal(w, h)
    ExRatatui.draw(terminal, TUI.render(state, %ExRatatui.Frame{width: w, height: h}))
    ExRatatui.get_buffer_content(terminal)
  end

  defp key(state, code, mods \\ []) do
    {:noreply, state} =
      TUI.handle_event(%Event.Key{code: code, kind: "press", modifiers: mods}, state)

    state
  end

  defp type(state, text) do
    ExRatatui.textarea_set_value(state.input, text)
    key(state, "enter")
  end

  defp info(state, msg) do
    {:noreply, state} = TUI.handle_info(msg, state)
    state
  end

  # A run's process: a stand-in, so cancelling it doesn't kill the test.
  defp stand_in, do: spawn(fn -> Process.sleep(:infinity) end)

  defp running(prompt) do
    {:ok, state} = TUI.mount(test_mode: @size)
    id = make_ref()

    state = %{
      state
      | run: {id, stand_in()},
        pending_prompt: prompt,
        transcript: [{:user, prompt}],
        status: "generating…"
    }

    {state, id}
  end

  defp parked(state, n), do: state.chats.parked[Enum.at(state.chats.order, n - 1)]

  defp metas(state), do: for({:meta, text} <- state.transcript, do: text)

  defp tool_ask(extra \\ %{}) do
    ref = make_ref()

    ask =
      Map.merge(
        %{
          tool: "github__create_issue",
          server: "github",
          description: "Opens an issue in a repository.",
          args: %{"title" => "Release notes"},
          class: :outward,
          reply_to: self(),
          ref: ref
        },
        extra
      )

    {ask, ref}
  end

  test "/new starts an empty chat and shows it; the one left keeps working" do
    {state, id} = running("alpha question")
    state = type(state, "/new")

    assert Chats.count(state) == 2
    assert Chats.position(state, state.chats.active) == 2
    assert state.run == nil
    assert state.history == []
    assert metas(state) == ["new chat 2 — chat 1 is still working"]
    assert ExRatatui.textarea_get_value(state.input) == ""
    assert {^id, _pid} = parked(state, 1).run
    assert draw(state) =~ "chat 2 of 2 · chat 1 working"
  end

  test "a chat put aside gets its own run's events, through to the answer" do
    {state, id} = running("alpha question")
    state = type(state, "/new")
    shown = state.transcript

    state =
      Enum.reduce(
        [{:attempt, 1}, {:delta, "Alpha "}, {:delta, "answer."}],
        state,
        &info(&2, {:pipeline, id, &1})
      )

    assert state.transcript == shown
    assert state.streaming == nil
    assert parked(state, 1).streaming == "Alpha answer."

    state = info(state, {:pipeline, id, {:done, "Alpha answer."}})
    chat1 = parked(state, 1)

    assert chat1.run == nil
    assert [%{role: "user", content: "alpha question"}, %{role: "assistant"}] = chat1.history
    assert {:assistant, "Alpha answer."} in chat1.transcript
    assert state.history == []
    assert state.transcript == shown
    assert state.status == "chat 1 finished · /chat 1 shows it"
  end

  test "switching shows each chat's own transcript" do
    {state, _id} = running("alpha question")
    state = %{state | transcript: state.transcript ++ [{:meta, "alpha working"}]}
    state = type(state, "/new")
    state = %{state | transcript: [{:user, "beta question"}, {:assistant, "beta answer"}]}

    screen = draw(state)
    assert screen =~ "beta answer"
    refute screen =~ "alpha working"

    state = type(state, "/chat 1")
    screen = draw(state)
    assert screen =~ "alpha working"
    refute screen =~ "beta answer"
    assert screen =~ "chat 1 of 2"
    assert state.run != nil

    # The sidebar lists them, the one on screen marked.
    assert screen =~ "▸ 1 alpha question · working"
    assert screen =~ "  2 beta question · idle"

    # ctrl+o goes round to the next one.
    state = key(state, "o", ["ctrl"])
    assert Chats.position(state, state.chats.active) == 2
    assert draw(state) =~ "beta answer"
    state = key(state, "o", ["ctrl"])
    assert Chats.position(state, state.chats.active) == 1

    state = type(state, "/chat 7")
    assert List.last(metas(state)) == "no chat 7 (/chats lists them)"
  end

  test "a question from a chat put aside comes up at once, says which chat asked, and is answered there" do
    {state, id} = running("alpha question")
    state = type(state, "/new")
    {ask, ref} = tool_ask()
    state = info(state, {:pipeline, id, {:tool_approval, ask}})

    assert state.tool_ask.ref == ref
    assert state.tool_ask.from == "chat 1"
    assert draw(state) =~ "asked by chat 1"
    assert Chats.activity(state, Enum.at(state.chats.order, 0)) == "waiting for you"

    shown = state.transcript
    state = key(state, "y")

    assert_received {:tool_answer, ^ref, :once}
    assert state.tool_ask == nil
    assert state.transcript == shown
    assert {:meta, "allowed github__create_issue once"} in parked(state, 1).transcript
  end

  test "a sub-agent's question (TinyAxe.Agent.Dispatch) from another chat names both" do
    {state, id} = running("alpha question")
    state = type(state, "/new")
    {ask, ref} = tool_ask()
    sub = %{n: 2, objective: "check the second site"}
    state = info(state, {:pipeline, id, {:subagent, sub, {:tool_approval, ask}}})

    assert state.tool_ask.ref == ref
    assert state.tool_ask.from == "chat 1 · agent 2"
    assert draw(state) =~ "asked by chat 1 · agent 2"
  end

  test "an agent's question from another chat names both" do
    {state, id} = running("alpha question")
    state = type(state, "/new")
    {ask, _ref} = tool_ask(%{from: "agent 2"})
    state = info(state, {:pipeline, id, {:tool_approval, ask}})
    assert state.tool_ask.from == "chat 1 · agent 2"

    # Back in chat 1 (keys answer the question, but ctrl+o still switches),
    # it's that chat's own agent asking.
    state = key(state, "o", ["ctrl"])
    assert Chats.position(state, state.chats.active) == 1
    assert state.tool_ask.from == "agent 2"
  end

  test "esc cancels only the chat on screen" do
    {state, _id} = running("alpha question")
    {_, first} = state.run
    state = type(state, "/new")
    second = stand_in()
    state = %{state | run: {make_ref(), second}, transcript: [{:user, "beta question"}]}
    ref = Process.monitor(second)

    state = key(state, "esc")

    assert_receive {:DOWN, ^ref, :process, ^second, :killed}
    assert state.run == nil
    assert Process.alive?(first)
    assert {_, ^first} = parked(state, 1).run
  end

  test "ctrl+c quits every chat" do
    {state, _id} = running("alpha question")
    {_, first} = state.run
    state = type(state, "/new")
    second = stand_in()
    state = %{state | run: {make_ref(), second}}
    refs = Enum.map([first, second], &Process.monitor/1)

    assert {:stop, _state} =
             TUI.handle_event(%Event.Key{code: "c", kind: "press", modifiers: ["ctrl"]}, state)

    for ref <- refs, do: assert_receive({:DOWN, ^ref, :process, _, :killed})
  end

  test "a crashed run in a chat put aside fails there" do
    {state, _id} = running("alpha question")
    {_, pid} = state.run
    state = type(state, "/new")
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed} = down

    state = info(state, down)
    assert parked(state, 1).run == nil
    assert {:meta, "error: " <> _} = List.last(parked(state, 1).transcript)
    assert metas(state) == ["new chat 2 — chat 1 is still working"]
  end

  test "/chats lists each chat with its title and what it's doing" do
    {state, _id} = running("alpha question about a fairly long subject that goes on and on")
    state = type(state, "/new")
    state = type(state, "/chats")

    assert [_new, one, two] = metas(state)
    assert one == "chat 1 · alpha question about a fairly long subj… · working"
    assert two == "chat 2 · (nothing asked yet) · idle ◂ this one"
  end

  test "/chat close closes an idle chat, but not a working one or the last" do
    {state, _id} = running("alpha question")
    state = type(state, "/new")
    state = type(state, "/chat 1")
    state = type(state, "/chat close")
    assert Chats.count(state) == 2
    assert List.last(metas(state)) =~ "chat 1 is still working"

    state = type(state, "/chat 2")
    state = type(state, "/chat close")
    assert Chats.count(state) == 1
    assert state.transcript |> hd() == {:user, "alpha question"}
    assert state.status == "closed chat 2; this is chat 1"

    state = %{state | run: nil}
    state = type(state, "/chat close")
    assert Chats.count(state) == 1
    assert List.last(metas(state)) =~ "this is the only chat"
  end

  test "ctrl+l clears only the chat on screen" do
    {state, _id} = running("alpha question")
    state = type(state, "/new")
    state = %{state | transcript: [{:user, "beta"}, {:assistant, "beta answer"}]}
    state = key(state, "l", ["ctrl"])

    assert state.transcript == []
    assert parked(state, 1).transcript == [{:user, "alpha question"}]
  end
end

defmodule TinyAxe.TUIChatsSessionTest do
  # Uses the app's shared session store, so not async.
  use ExUnit.Case, async: false

  alias ExRatatui.Event
  alias TinyAxe.TUI
  alias TinyAxe.TUI.Chats

  setup do
    Agent.update(TinyAxe.Session, fn _ ->
      %{history: [], transcript: [], summary: nil, crashed: nil}
    end)
  end

  defp type(state, text) do
    ExRatatui.textarea_set_value(state.input, text)

    {:noreply, state} =
      TUI.handle_event(%Event.Key{code: "enter", kind: "press", modifiers: []}, state)

    state
  end

  test "every chat is saved and restored, with the one on screen" do
    {:ok, state} = TUI.mount(test_mode: {100, 30}, session: true)
    turn = [%{role: "user", content: "alpha"}, %{role: "assistant", content: "A"}]
    state = %{state | history: turn, transcript: [{:user, "alpha"}, {:assistant, "A"}]}
    _state = type(state, "/new")

    saved = TinyAxe.Session.restore()
    assert [%{history: ^turn}, %{history: []}] = saved.chats
    assert saved.active == 1
    assert saved.transcript == [{:meta, "new chat 2"}]

    {:ok, restored} = TUI.mount(test_mode: {100, 30}, session: true)
    assert Chats.count(restored) == 2
    assert Chats.position(restored, restored.chats.active) == 2
    assert {:meta, "new chat 2"} in restored.transcript
    [chat1] = Map.values(restored.chats.parked)
    assert chat1.history == turn
    assert chat1.transcript == [{:user, "alpha"}, {:assistant, "A"}]
    assert chat1.run == nil
  end

  test "a conversation saved the old way restores as one chat" do
    Agent.update(TinyAxe.Session, fn _ ->
      %{history: [], transcript: [{:user, "old"}], summary: nil, crashed: nil}
    end)

    {:ok, state} = TUI.mount(test_mode: {100, 30}, session: true)
    assert Chats.count(state) == 1
    assert state.transcript == [{:user, "old"}]
  end
end
