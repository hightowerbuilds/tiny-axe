defmodule TinyAxe.TUITabsTest do
  use ExUnit.Case, async: true

  alias ExRatatui.{CellSession, Event}
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Widgets.Paragraph
  alias TinyAxe.TUI
  alias TinyAxe.TUI.{Chats, MainTabs, MemoryChat, TabBar, View}

  @size {100, 32}

  defp mounted do
    {:ok, state} = TUI.mount(test_mode: @size)
    %{state | sidebar: false}
  end

  defp event(state, event) do
    case TUI.handle_event(event, state) do
      {:noreply, state} -> state
      {:noreply, state, _opts} -> state
    end
  end

  defp key(state, code, modifiers \\ []) do
    event(state, %Event.Key{code: code, kind: "press", modifiers: modifiers})
  end

  defp type(state, text) do
    ExRatatui.textarea_set_value(state.input, text)
    key(state, "enter")
  end

  defp draft(state, text) do
    ExRatatui.textarea_set_value(state.input, text)
    state
  end

  defp input(state), do: ExRatatui.textarea_get_value(state.input)

  defp tabs(state), do: TabBar.layout(state, elem(state.size, 0))

  defp tab(state, action), do: Enum.find(tabs(state), &(&1.action == action))

  defp click(state, action) do
    target = tab(state, action)
    assert target, "missing tab action #{inspect(action)}"
    event(state, %Event.Mouse{kind: "down", button: "left", x: target.x, y: MainTabs.height()})
  end

  defp with_chats(n) do
    state = %{mounted() | transcript: [{:user, "Topic 1"}]}

    Enum.reduce(2..n, state, fn number, acc ->
      {acc, _id} = Chats.open_aside(acc, %{transcript: [{:user, "Topic #{number}"}]})
      acc
    end)
  end

  defp draw(state) do
    {width, height} = state.size
    terminal = ExRatatui.init_test_terminal(width, height)
    ExRatatui.draw(terminal, TUI.render(state, %ExRatatui.Frame{width: width, height: height}))
    ExRatatui.get_buffer_content(terminal)
  end

  defp strip(state),
    do: state |> draw() |> String.split("\n") |> Enum.slice(MainTabs.height(), TabBar.height())

  defp cells(state) do
    {width, height} = state.size
    session = CellSession.new(width, height)

    try do
      :ok =
        CellSession.draw(
          session,
          TUI.render(state, %ExRatatui.Frame{width: width, height: height})
        )

      %{cells: cells} = CellSession.take_cells(session)
      cells
    after
      CellSession.close(session)
    end
  end

  defp native_width(text) do
    width = max(byte_size(text) * 2, 1)
    session = CellSession.new(width, 1)

    try do
      :ok =
        CellSession.draw(session, [
          {%Paragraph{text: text <> "|"}, %Rect{x: 0, y: 0, width: width, height: 1}}
        ])

      %{cells: cells} = CellSession.take_cells(session)
      Enum.find(cells, &(&1.symbol == "|")).col
    after
      CellSession.close(session)
    end
  end

  test "the tab strip remains visible with one chat and with the sidebar hidden" do
    state = %{mounted() | transcript: [{:user, "Alpha"}]}
    active = tab(state, {:chat, state.chats.active})

    assert active.active?
    assert Enum.join(strip(state)) =~ "Alpha"
    assert tab(state, :new)

    state = state |> click(:new) |> Map.put(:transcript, [{:user, "Beta"}])
    row = Enum.join(strip(state))
    assert row =~ "Alpha"
    assert row =~ "Beta"
    refute state.sidebar
    assert Enum.count(tabs(state), & &1.active?) == 1
  end

  test "Unicode labels fit actual terminal cells and clicks agree with displayed geometry" do
    state = %{mounted() | transcript: [{:user, "日本語 e\u0301 👩‍💻"}]}

    {state, _} =
      Chats.open_aside(state, %{local_only: true, transcript: [{:user, "Memory"}]})

    row = Enum.join(strip(state))
    first_row = cells(state) |> Enum.filter(&(&1.row == MainTabs.height()))
    japanese = for cell <- first_row, cell.symbol in ["日", "本", "語"], do: cell
    assert Enum.map(japanese, & &1.symbol) == ["日", "本", "語"]

    assert Enum.map(japanese, & &1.col) ==
             Enum.to_list(hd(japanese).col..(hd(japanese).col + 4)//2)

    assert row =~ "e\u0301"
    assert row =~ "Memory"
    assert row =~ "🔒"

    for item <- tabs(state) do
      assert native_width(item.label) <= item.width

      for x <- item.x..(item.x + item.width - 1) do
        assert TabBar.hit(state, x, MainTabs.height()) == item.action
      end
    end

    assert TabBar.hit(state, -1, MainTabs.height()) == nil
    assert TabBar.hit(state, elem(state.size, 0), MainTabs.height()) == nil
    assert TabBar.hit(state, 0, 0) == nil
    assert TabBar.hit(state, 0, MainTabs.height() + TabBar.height()) == nil
  end

  test "the native strip distinguishes the selected tab, work, approvals, errors and private chats" do
    state = %{mounted() | transcript: [{:user, "Active"}], size: {200, 32}}
    active = state.chats.active

    {state, working} =
      Chats.open_aside(state, %{transcript: [{:user, "Worker"}], run: {make_ref(), self()}})

    {state, waiting} =
      Chats.open_aside(state, %{transcript: [{:user, "Approval"}], pending_commands: %{}})

    {state, failed} = Chats.open_aside(state, %{transcript: [{:user, "Failed"}], status: "error"})
    {state, local} = Chats.open_aside(state, %{transcript: [{:user, "Memory"}], local_only: true})

    {state, remote} =
      Chats.open_aside(state, %{transcript: [{:user, "Remote"}], remote_chat: true})

    {state, idle} = Chats.open_aside(state, %{transcript: [{:user, "Idle"}]})
    rendered = cells(state)

    first_cell = fn id ->
      item = tab(state, {:chat, id})
      Enum.find(rendered, &(&1.row == MainTabs.height() and &1.col == item.x))
    end

    assert :bold in first_cell.(active).modifiers
    assert first_cell.(active).bg != first_cell.(idle).bg

    for {id, glyph, color} <- [
          {working, "●", :cyan},
          {waiting, "?", :yellow},
          {failed, "!", :red}
        ] do
      item = tab(state, {:chat, id})
      assert item.label =~ glyph
      assert first_cell.(id).fg == color

      assert Enum.any?(
               rendered,
               &(&1.row == MainTabs.height() and &1.col >= item.x and &1.col < item.x + item.width and
                   &1.symbol == glyph)
             )
    end

    assert first_cell.(idle).fg == :gray
    assert tab(state, {:chat, local}).label =~ "🔒"
    assert tab(state, {:chat, remote}).label =~ "🌐"
    assert Enum.any?(rendered, &(&1.row == MainTabs.height() and &1.symbol == "🔒"))
    assert Enum.any?(rendered, &(&1.row == MainTabs.height() and &1.symbol == "🌐"))

    state = click(state, {:chat, working})
    assert tab(state, {:chat, working}).active?
    refute tab(state, {:chat, active}).active?
  end

  test "overflow retains the active tab at every width and recalculates after resize" do
    state = with_chats(12) |> key("9", ["alt"])
    assert Chats.position(state, state.chats.active) == 9
    active = state.chats.active

    for width <- [1, 2, 4, 8, 16, 25, 40, 80, 160] do
      resized = event(state, %Event.Resize{width: width, height: 32})
      assert resized.size == {width, 32}
      items = tabs(resized)
      assert [%{action: {:chat, ^active}}] = Enum.filter(items, & &1.active?)
      assert Enum.all?(items, &(&1.x >= 0 and &1.width > 0 and &1.x + &1.width <= width))

      for [left, right] <- Enum.chunk_every(items, 2, 1, :discard) do
        assert left.x + left.width <= right.x
      end

      if width >= 8 and width <= 40 do
        assert tab(resized, :previous)
        assert tab(resized, :next)
        assert tab(resized, :new)
      end

      assert is_binary(draw(resized))
    end

    assert TabBar.layout(state, 0) == []
  end

  test "overflow buttons and keyboard navigation switch chats without dropping drafts" do
    state = with_chats(12) |> event(%Event.Resize{width: 40, height: 32})
    state = state |> key("9", ["alt"]) |> draft("draft for nine")
    state = click(state, :next)
    assert Chats.position(state, state.chats.active) == 10
    assert input(state) == ""

    state = state |> draft("draft for ten") |> click(:previous)
    assert Chats.position(state, state.chats.active) == 9
    assert input(state) == "draft for nine"

    state = key(state, "right", ["alt"])
    assert input(state) == "draft for ten"
    state = key(state, "1", ["alt"])
    assert Chats.position(state, state.chats.active) == 1
    state = key(state, "left", ["alt"])
    assert Chats.position(state, state.chats.active) == 12
    state = key(state, "o", ["ctrl"])
    assert Chats.position(state, state.chats.active) == 1

    state = key(state, "9", ["alt"])
    assert input(state) == "draft for nine"
    assert event(state, %Event.Key{code: "right", kind: "release", modifiers: ["alt"]}) == state
  end

  test "mouse selection preserves each textarea's unsent text and cursor" do
    state = mounted() |> draft("alpha\nbeta")
    original = state.chats.active
    ExRatatui.textarea_handle_key(state.input, "left", [])
    cursor = ExRatatui.textarea_cursor(state.input)
    first_input = state.input

    state = click(state, :new)
    second = state.chats.active
    assert input(state) == ""
    refute state.input == first_input
    state = state |> draft("second draft") |> click({:chat, original})
    assert input(state) == "alpha\nbeta"
    assert ExRatatui.textarea_cursor(state.input) == cursor
    assert state.input == first_input

    state = click(state, {:chat, second})
    assert input(state) == "second draft"
    state = type(state, "/chat close")
    assert state.chats.active == original
    assert input(state) == "alpha\nbeta"
    assert Chats.count(state) == 1
  end

  test "a private memory draft cannot follow the user into an ordinary tab" do
    state = mounted() |> draft("ordinary draft")
    ordinary = state.chats.active
    state = state |> MemoryChat.ensure_local() |> draft("private memory question")
    private = state.chats.active
    assert state.local_only

    state = click(state, :new)
    refute state.local_only
    assert input(state) == ""
    refute Enum.any?(state.transcript, &match?({:user, _}, &1))

    state = click(state, {:chat, private})
    assert state.local_only
    assert input(state) == "private memory question"
    state = click(state, {:chat, ordinary})
    refute state.local_only
    assert input(state) == "ordinary draft"
  end

  test "background completion updates its tab while leaving the foreground draft untouched" do
    state = %{mounted() | transcript: [{:user, "Background task"}]}
    run = make_ref()
    state = %{state | run: {run, self()}, pending_prompt: "Background task"}
    owner = state.chats.active
    state = state |> click(:new) |> draft("foreground draft")
    front = state.chats.active
    foreground_input = state.input

    {:noreply, state} = TUI.handle_info({:pipeline, run, {:delta, "Result"}}, state)
    assert state.chats.active == front
    assert state.input == foreground_input
    assert input(state) == "foreground draft"
    assert Chats.activity(state, owner) == "working"
    assert Enum.join(strip(state)) =~ "●"

    {:noreply, state} = TUI.handle_info({:pipeline, run, {:done, "Result"}}, state)
    assert input(state) == "foreground draft"
    assert Chats.activity(state, owner) == "idle"
    assert {:assistant, "Result"} in Chats.get(state, owner).transcript
    refute Enum.join(strip(state)) =~ "●"

    state = click(state, {:chat, owner})
    assert state.run == nil
    assert input(state) == ""
    assert draw(state) =~ "Result"
  end

  test "tab navigation leaves background approval ownership and answers intact" do
    state = with_chats(2)
    owner = state.chats.active
    run = make_ref()
    state = %{state | run: {run, self()}, pending_prompt: "Topic 1"}
    state = key(state, "2", ["alt"])
    front = state.chats.active
    ref = make_ref()

    ask = %{
      tool: "github__create_issue",
      server: "github",
      description: "Opens an issue.",
      args: %{},
      class: :outward,
      reply_to: self(),
      ref: ref
    }

    {:noreply, state} = TUI.handle_info({:pipeline, run, {:tool_approval, ask}}, state)
    assert state.tool_ask.chat == owner
    assert Chats.activity(state, owner) == "waiting for you"
    assert Enum.join(strip(state)) =~ "?"
    state = click(state, {:chat, owner})
    assert state.chats.active == owner
    state = key(state, "2", ["alt"])
    assert state.chats.active == front
    assert state.tool_ask.chat == owner
    refute_received {:tool_answer, ^ref, _}

    state = key(state, "y")
    assert_received {:tool_answer, ^ref, :once}
    assert state.chats.active == front
    assert state.tool_ask == nil
    assert {:meta, "allowed github__create_issue once"} in Chats.get(state, owner).transcript
  end

  test "clicks cannot switch or create chats behind a modal workflow" do
    state = with_chats(2)
    target = List.last(state.chats.order)

    for {field, value} <- [
          account_flow: %{},
          card_flow: %{},
          recovery: %{},
          confirm_undo: %{},
          pending_edits: [%{}],
          pending_plan: %{},
          pending_commands: %{},
          token_dash: %{}
        ] do
      blocked = Map.put(state, field, value)
      switched = click(blocked, {:chat, target})
      assert switched.chats.active == state.chats.active, "click escaped #{field}"
      created = click(blocked, :new)
      assert Chats.count(created) == 2, "new chat escaped #{field}"
      assert Map.fetch!(created, field) == value
      assert key(blocked, "2", ["alt"]).chats.active == state.chats.active
      assert key(blocked, "o", ["ctrl"]).chats.active == state.chats.active
    end
  end

  test "Alt-number navigation never types a digit into a purchase approval" do
    state = with_chats(2)
    owner = state.chats.active
    run = make_ref()
    ref = make_ref()
    state = %{state | run: {run, self()}}
    ask = %{summary: %{"host" => "shop.example", "total" => 16.0}, reply_to: self(), ref: ref}
    {:noreply, state} = TUI.handle_info({:pipeline, run, {:purchase_approval, ask}}, state)

    state = key(state, "1")
    assert state.purchase_ask.typed == "1"
    state = key(state, "2", ["alt"])
    assert Chats.position(state, state.chats.active) == 2
    assert state.purchase_ask.chat == owner
    assert state.purchase_ask.typed == "1"
    state = key(state, "1", ["alt"])
    assert state.chats.active == owner
    assert state.purchase_ask.typed == "1"
    refute_received {:purchase_answer, ^ref, _}
  end

  test "right clicks, releases and transcript clicks do not activate tabs" do
    state = with_chats(2)
    target = tab(state, {:chat, List.last(state.chats.order)})

    for event <- [
          %Event.Mouse{kind: "down", button: "right", x: target.x, y: MainTabs.height()},
          %Event.Mouse{kind: "up", button: "left", x: target.x, y: MainTabs.height()},
          %Event.Mouse{
            kind: "down",
            button: "left",
            x: target.x,
            y: MainTabs.height() + TabBar.height()
          }
        ] do
      assert event(state, event).chats.active == state.chats.active
    end
  end

  test "transcript scrolling uses the reduced viewport below the tab strip" do
    state = mounted()
    transcript = for n <- 1..60, do: {:meta, "TRANSCRIPT ROW #{n}"}
    state = %{state | transcript: transcript}
    rows = String.split(draw(state), "\n")
    {_width, height} = state.size
    last_transcript_row = height - View.input_height() - 3
    assert Enum.at(rows, last_transcript_row) =~ "TRANSCRIPT ROW 60"

    state = key(state, "home")

    assert Enum.at(String.split(draw(state), "\n"), MainTabs.height() + TabBar.height() + 1) =~
             "TRANSCRIPT ROW 1"

    assert Enum.join(strip(state)) == Enum.join(strip(%{state | scroll: :bottom}))
    assert key(state, "page_down").scroll != state.scroll
    assert key(state, "end").scroll == :bottom
  end

  test "mouse wheel scrolls the transcript without editing an unsent draft" do
    state = mounted() |> draft("leave this draft alone")
    state = %{state | transcript: for(n <- 1..60, do: {:meta, "ROW #{n}"})}
    state = event(state, %Event.Mouse{kind: "scroll_up", x: 10, y: 10})
    refute state.scroll == :bottom
    assert input(state) == "leave this draft alone"
    state = event(state, %Event.Mouse{kind: "scroll_down", x: 10, y: 10})
    assert state.scroll == :bottom
    assert input(state) == "leave this draft alone"
  end
end

defmodule TinyAxe.TUITabsSessionTest do
  use ExUnit.Case, async: false

  alias ExRatatui.Event
  alias TinyAxe.{Session, TUI}
  alias TinyAxe.TUI.Chats

  test "switching tabs persists selection while unsent drafts remain ephemeral" do
    saved = Session.restore()
    on_exit(fn -> Agent.update(Session, fn _ -> saved end) end)

    {:ok, state} = TUI.mount(test_mode: {100, 32})
    {state, second} = Chats.open_aside(state, %{local_only: true})
    ExRatatui.textarea_set_value(state.input, "unsent ordinary draft")
    before = state

    {:noreply, state} =
      TUI.handle_event(%Event.Key{code: "2", kind: "press", modifiers: ["alt"]}, state)

    assert state.chats.active == second
    ExRatatui.textarea_set_value(state.input, "unsent private draft")
    Chats.persist(state, before)

    saved = Session.restore()
    assert saved.active == 1
    assert length(saved.chats) == 2
    refute inspect(saved) =~ "unsent"
    assert Enum.all?(saved.chats, &(not Map.has_key?(&1, :input)))

    {:ok, restored} = TUI.mount(test_mode: {100, 32}, session: true)
    assert Chats.position(restored, restored.chats.active) == 2
    assert restored.local_only
    assert ExRatatui.textarea_get_value(restored.input) == ""

    restored = Chats.switch(restored, hd(restored.chats.order))
    refute restored.local_only
    assert ExRatatui.textarea_get_value(restored.input) == ""
  end
end
