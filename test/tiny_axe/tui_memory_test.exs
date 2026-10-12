defmodule TinyAxe.TUIMemoryTest do
  use ExUnit.Case, async: false
  alias ExRatatui.Event
  alias TinyAxe.{History, TUI}
  alias TinyAxe.TUI.{Chats, MemoryChat}

  setup do
    History.sync()
    File.rm_rf!(History.dir())

    on_exit(fn ->
      History.sync()
      File.rm_rf!(History.dir())
    end)

    :ok
  end

  defp key(state, key, mods \\ []) do
    {:noreply, state} =
      TUI.handle_event(%Event.Key{code: key, kind: "press", modifiers: mods}, state)

    state
  end

  defp type(state, text) do
    ExRatatui.textarea_set_value(state.input, text)
    key(state, "enter")
  end

  defp finish(state) do
    {id, _} = state.run

    receive do
      {:pipeline, ^id, event} ->
        {:noreply, state} = TUI.handle_info({:pipeline, id, event}, state)
        state
    after
      5000 -> flunk("memory job did not finish")
    end
  end

  test "search, source view, pagination, parked jobs and reopening remain local" do
    id = History.new_id()

    History.save([
      %{saved_as: id, transcript: [{:user, "violet submarine"}], history: [], summary: nil}
    ])

    History.sync()
    {:ok, state} = TUI.mount(test_mode: {110, 32})
    original = state.saved_as
    state = state |> type("/memory search \"violet submarine\"") |> finish()
    assert state.local_only
    refute state.saved_as == original

    assert state.memory_results.total == 1,
           inspect(%{
             result: state.memory_results,
             history: History.dir(),
             indexed_history: :sys.get_state(TinyAxe.Memory).history,
             saved_source: History.document(id)
           })

    terminal = ExRatatui.init_test_terminal(110, 32)
    ExRatatui.draw(terminal, TUI.render(state, %ExRatatui.Frame{width: 110, height: 32}))
    assert ExRatatui.get_buffer_content(terminal) =~ "violet"
    assert [%{chat_id: ^id}] = state.memory_results.hits
    state = type(state, "/memory open 1")

    assert Enum.any?(state.transcript, fn {_, text} ->
             text =~ "Entry 1 · user\nviolet submarine"
           end)

    state = type(state, "/memory next")
    assert List.last(state.transcript) == {:meta, "end of results"}

    state = type(state, "/memory status")
    {job, _} = state.run
    owner = state.chats.active
    state = type(state, "/new")
    refute state.local_only

    receive do
      {:pipeline, ^job, event} ->
        {:noreply, state} = TUI.handle_info({:pipeline, job, event}, state)
        refute state.local_only
        assert Chats.get(state, owner).local_only
        assert Chats.get(state, owner).run == nil
    after
      5000 -> flunk("parked status did not finish")
    end
  end

  test "local marker survives history, session restore and switching; remote builtins and compaction stay disabled" do
    {:ok, before} = TUI.mount(test_mode: {110, 32})
    local = MemoryChat.ensure_local(before)
    local = %{local | transcript: [{:user, "private memory question"}]}
    Chats.persist(local, before)
    History.sync()
    assert {:ok, %{local_only: true} = saved} = History.load(local.saved_as)
    state = Chats.reopen(before, saved)
    assert state.local_only
    assert type(state, "/site").run == nil
    assert type(state, "/remote on").remote_link.phase == :off
    assert key(state, "k", ["ctrl"]).run == nil
    assert key(state, "l", ["ctrl"]).local_only

    session = TinyAxe.Session.restore()
    assert session.local_only
    restored = Chats.restore(session)
    assert Enum.all?(restored.parked, fn {_id, chat} -> is_boolean(chat.local_only) end)
  end

  test "review controls persist on/off and report separate generated coverage" do
    {:ok, state} = TUI.mount(test_mode: {110, 32})

    on_exit(fn ->
      TinyAxe.Memory.review(false)
      TinyAxe.Memory.Review.pause()
    end)

    state = state |> type("/memory review on") |> finish()
    assert state.local_only
    assert Enum.any?(state.transcript, fn {_, text} -> text =~ "Gemma review on" end)
    state = state |> type("/memory review off") |> finish()
    assert Enum.any?(state.transcript, fn {_, text} -> text =~ "Gemma review off" end)
    assert {:ok, %{review: %{enabled: false}}} = TinyAxe.Memory.status()
  end
end
