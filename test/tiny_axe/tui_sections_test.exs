defmodule TinyAxe.TUISectionsTest do
  # Memory, token totals and card entry are application-wide state.
  use ExUnit.Case, async: false

  alias ExRatatui.Event
  alias TinyAxe.{Cards, History, TUI, Usage}
  alias TinyAxe.TUI.{Chats, FeaturePanels, MainTabs, TabBar}

  @size {120, 36}
  @sections [:chat, :wallet, :search, :tokens, :remote]
  @moduletag :tmp_dir

  defp mounted do
    {:ok, state} = TUI.mount(test_mode: @size, remote: self())
    %{state | sidebar: false}
  end

  defp event(state, event) do
    case TUI.handle_event(event, state) do
      {:noreply, state} -> state
      {:noreply, state, _opts} -> state
    end
  end

  defp key(state, code, modifiers \\ []),
    do: event(state, %Event.Key{code: code, kind: "press", modifiers: modifiers})

  defp open(state, section) do
    item =
      MainTabs.layout(state, elem(state.size, 0))
      |> Enum.find(&(&1.action == {:section, section}))

    assert item, "missing main tab #{section}"
    event(state, %Event.Mouse{kind: "down", button: "left", x: item.x, y: 0})
  end

  defp draft(state, text) do
    ExRatatui.textarea_set_value(state.input, text)
    state
  end

  defp input(state), do: ExRatatui.textarea_get_value(state.input)

  defp action(state, action) do
    item = FeaturePanels.toolbar(state, elem(state.size, 0)) |> Enum.find(&(&1.action == action))
    assert item, "missing panel action #{action}"
    event(state, %Event.Mouse{kind: "down", button: "left", x: item.x, y: MainTabs.height()})
  end

  defp draw(state) do
    {width, height} = state.size
    terminal = ExRatatui.init_test_terminal(width, height)
    ExRatatui.draw(terminal, TUI.render(state, %ExRatatui.Frame{width: width, height: height}))
    ExRatatui.get_buffer_content(terminal)
  end

  defp finish(state) do
    {id, _pid} = state.run

    receive do
      {:pipeline, ^id, event} ->
        {:noreply, state} = TUI.handle_info({:pipeline, id, event}, state)
        if state.run, do: finish(state), else: state
    after
      5_000 -> flunk("local search did not finish")
    end
  end

  test "feature tabs form the first row and conversation tabs appear only inside Chat" do
    state = %{mounted() | transcript: [{:user, "Distinct conversation title"}]}
    first_row = state |> draw() |> String.split("\n") |> hd()

    for label <- ["Chat", "Wallet", "Gemma Search", "Tokens", "Remote"] do
      assert first_row =~ label
    end

    assert state.section == :chat
    assert Enum.at(String.split(draw(state), "\n"), MainTabs.height()) =~ "Distinct"

    for section <- [:wallet, :search, :tokens, :remote] do
      shown = open(state, section)
      assert shown.section == section
      refute draw(shown) =~ "Distinct conversation title"
      assert TabBar.hit(shown, 1, MainTabs.height()) == nil

      assert [%{action: {:section, ^section}}] =
               MainTabs.layout(shown, elem(shown.size, 0)) |> Enum.filter(& &1.active?)
    end
  end

  test "F1 through F5 and clicks select main sections without losing the original chat" do
    state = mounted() |> draft("ordinary unsent draft")
    original = state.chats.active

    state =
      Enum.reduce(Enum.with_index(@sections, 1), state, fn {section, number}, acc ->
        acc = key(acc, "f#{number}")
        assert acc.section == section
        acc
      end)

    state = open(state, :chat)
    assert state.chats.active == original
    assert input(state) == "ordinary unsent draft"
    assert key(state, "f2") |> key("f1") |> Map.get(:section) == :chat
    assert event(state, %Event.Key{code: "f2", kind: "release", modifiers: []}).section == :chat
  end

  test "main tabs retain the selected destination and valid click regions on narrow screens" do
    state = mounted() |> open(:remote)

    for width <- [1, 2, 5, 10, 20, 40, 80, 120] do
      resized = event(state, %Event.Resize{width: width, height: 36})
      items = MainTabs.layout(resized, width)
      assert [%{action: {:section, :remote}}] = Enum.filter(items, & &1.active?)

      for item <- items do
        assert item.width > 0
        assert item.x + item.width <= width

        for x <- item.x..(item.x + item.width - 1) do
          assert MainTabs.hit(resized, x, 0) == item.action
          assert MainTabs.hit(resized, x, 1) == nil
        end
      end

      assert is_binary(draw(resized))
    end
  end

  test "panel typing and Chat shortcuts cannot alter the hidden conversation draft" do
    state = mounted() |> draft("keep my chat draft")
    {state, _} = Chats.open_aside(state, %{})
    original = state.chats.active
    original_input = state.input

    for section <- [:wallet, :tokens, :remote] do
      panel = open(state, section)
      panel = panel |> key("x") |> event(%Event.Paste{content: "unrelated text"})
      panel = panel |> key("right", ["alt"]) |> key("2", ["alt"]) |> key("o", ["ctrl"])
      assert panel.chats.active == original
      assert panel.input == original_input
      assert input(panel) == "keep my chat draft"
      assert panel.run == nil
    end
  end

  test "Gemma Search owns a local draft that survives trips to Chat and other sections" do
    state = mounted() |> draft("ordinary draft")
    original = state.chats.active
    state = open(state, :search)
    private = state.chats.active
    refute private == original
    assert state.local_only
    assert input(state) == ""
    state = draft(state, "private recall draft")

    state = state |> open(:tokens) |> open(:chat)
    assert state.chats.active == original
    refute state.local_only
    assert input(state) == "ordinary draft"

    count = Chats.count(state)
    state = open(state, :search)
    assert state.chats.active == private
    assert state.local_only
    assert input(state) == "private recall draft"
    assert Chats.count(state) == count
    assert open(state, :search).chats.active == private
  end

  test "word search runs locally from the Search workspace without calling a model" do
    previous = Application.get_env(:tiny_axe, :memory)

    Application.put_env(
      :tiny_axe,
      :memory,
      Keyword.put(previous, :req_options, plug: {Req.Test, __MODULE__})
    )

    Req.Test.stub(__MODULE__, fn _ -> flunk("word search unexpectedly called a model") end)
    id = History.new_id()

    on_exit(fn ->
      Application.put_env(:tiny_axe, :memory, previous)
      History.sync()
      File.rm(Path.join(History.dir(), id <> ".json"))
    end)

    History.save([
      %{
        saved_as: id,
        transcript: [{:user, "nebulous marmalade search fixture C++ C:\\tmp\\source \"quoted\""}],
        history: [],
        summary: nil
      }
    ])

    History.sync()

    state = mounted() |> open(:search)
    assert state.search_mode == :words
    assert state.local_only
    state = state |> draft("\"nebulous marmalade\"") |> key("enter") |> finish()
    assert state.section == :search
    assert state.local_only
    assert Enum.any?(state.memory_results.hits, &(&1.chat_id == id))
    assert draw(state) =~ "nebulous marmalade"
    assert input(state) == ""

    state = state |> key("f7") |> draft("C++") |> key("enter") |> finish()
    assert state.search_mode == :literal
    assert state.memory_results.mode == :literal
    assert Enum.any?(state.memory_results.hits, &(&1.chat_id == id))
    assert state.memory_results.query == "C++"

    state = state |> draft("C:\\tmp\\source \"quoted\"") |> key("enter") |> finish()
    assert state.memory_results.query == "C:\\tmp\\source \"quoted\""
    assert Enum.any?(state.memory_results.hits, &(&1.chat_id == id))

    state = key(state, "f8")
    assert state.search_mode == :ask
    assert state.run == nil
    assert state.local_only
    assert draw(state) =~ "ask Gemma"
    state = key(state, "k", ["ctrl"])
    assert state.run == nil
    assert state.local_only
    assert state.compacting == nil
    assert key(state, "f6").search_mode == :words
    refute_received {:remote_out, _}
  end

  test "Wallet reads masked metadata and starts secure entry without altering the chat", %{
    tmp_dir: dir
  } do
    previous = Map.new([:purchases_config, :purchases], &{&1, Application.get_env(:tiny_axe, &1)})
    Application.put_env(:tiny_axe, :purchases_config, Path.join(dir, "purchases.json"))

    Application.put_env(:tiny_axe, :purchases,
      enabled: false,
      currency: "USD",
      per_order_max: 75,
      daily_max: 150
    )

    label = "Sections Visa #{System.unique_integer([:positive])}"

    on_exit(fn ->
      Cards.discard_entry()
      Cards.forget(label)
      for {key, value} <- previous, do: Application.put_env(:tiny_axe, key, value)
    end)

    Cards.start_entry()

    for {field, value} <- [
          number: "4111111111111111",
          exp: "12/30",
          cvc: "737",
          name: "Test User"
        ],
        char <- String.graphemes(value),
        do: Cards.entry_key(field, char)

    assert {:ok, _} =
             Cards.save(%{
               "label" => label,
               "purpose" => "books",
               "remember" => "session",
               "cvc" => "stored"
             })

    state = mounted() |> draft("chat draft")
    original = state.transcript
    state = open(state, :wallet)
    screen = draw(state)
    assert screen =~ label
    assert screen =~ "1111"
    assert screen =~ "Purchases: disabled"
    assert screen =~ "75.00 USD"
    refute screen =~ "4111111111111111"
    refute inspect(state.panels.wallet) =~ "737"
    assert Enum.all?(state.panels.wallet.cards, &(not Map.has_key?(&1, :keyring)))

    state = action(state, :add_card)
    assert state.card_flow
    assert key(state, "f1").section == :wallet
    state = Enum.reduce(String.graphemes("4111111111111111"), state, &key(&2, &1))
    refute draw(state) =~ "4111111111111111"
    assert input(state) == "chat draft"
    state = key(state, "esc")
    assert state.card_flow == nil
    assert state.section == :wallet
    assert state.transcript == original
    assert state.panels.wallet.notice =~ "cancelled"
    assert input(state) == "chat draft"
  end

  test "Tokens reads current usage, refreshes and stops its page timer when leaving" do
    state = mounted() |> open(:tokens)
    assert state.token_dash == nil
    dashboard = state.panels.tokens.dashboard
    assert is_map(dashboard.summary)
    before = dashboard.summary.session.ollama.calls
    Usage.emit(:ollama, :answer, "sections-token-fixture", %{input: 31, output: 7}, true, 4)
    state = action(state, :refresh)
    assert state.panels.tokens.dashboard.summary.session.ollama.calls == before + 1
    assert draw(state) =~ "Gemma"
    assert state.run == nil
    assert state.transcript == []

    ref = state.panels.tokens.dashboard.ref
    state = open(state, :chat)
    assert state.panels.tokens.dashboard == nil
    result = TUI.handle_info({:token_dash, ref}, state)
    assert elem(result, 1).panels.tokens.dashboard == nil
    assert elem(result, 1).section == :chat
  end

  test "Remote opens without enabling it and its explicit controls stay outside chat history" do
    state = mounted() |> draft("ordinary draft")
    transcript = state.transcript
    state = open(state, :remote)
    assert state.remote_link.phase == :off
    refute_received {:remote_out, _}
    assert draw(state) =~ "Opening this tab does not enable"

    state = action(state, :enable)
    assert_received {:remote_out, {:switch, true}}
    assert state.remote_link.phase == :connecting
    assert state.transcript == transcript
    {:noreply, state} = TUI.handle_info({:remote, {:status, :online}}, state)
    assert draw(state) =~ "Connection: online"

    state = action(state, :enable)
    assert_received {:remote_out, {:switch, true}}
    assert state.remote_link.phase == :online

    state = key(state, "d")
    assert_received {:remote_out, {:switch, false}}
    assert state.remote_link.phase == :off
    assert state.transcript == transcript
    assert input(state) == "ordinary draft"

    state = action(state, :open_chat)
    assert state.section == :remote
    assert state.panels.remote.notice =~ "first message"

    {state, id} =
      Chats.open_aside(state, %{remote_chat: true, transcript: [{:user, "Remote question"}]})

    state = key(state, "c")
    assert state.section == :chat
    assert state.chats.active == id
    assert state.remote_chat
    assert draw(state) =~ "Remote question"
  end

  test "secret entry and pending workflows cannot be escaped by main-tab clicks or function keys" do
    state = mounted()

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
      assert open(blocked, :wallet).section == :chat, "click escaped #{field}"
      assert key(blocked, "f3").section == :chat, "function key escaped #{field}"
      assert Map.fetch!(key(blocked, "f2"), field) == value
    end
  end

  test "a pending approval keeps panel buttons and hotkeys from taking action underneath it" do
    state = mounted()
    owner = state.chats.active
    run = make_ref()
    ref = make_ref()
    state = %{state | run: {run, self()}}

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
    state = open(state, :remote)
    assert state.section == :remote
    state = state |> action(:enable) |> key("o")
    assert state.tool_ask.chat == owner
    assert state.remote_link.phase == :off
    refute_received {:remote_out, {:switch, _}}
    refute_received {:tool_answer, ^ref, _}

    state = key(state, "n")
    assert_received {:tool_answer, ^ref, :deny}
    assert state.section == :remote
    assert state.tool_ask == nil
    state = action(state, :enable)
    assert_received {:remote_out, {:switch, true}}
    assert state.remote_link.phase == :connecting
  end
end
