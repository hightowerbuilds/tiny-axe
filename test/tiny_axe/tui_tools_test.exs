defmodule TinyAxe.TUIToolsTest do
  use ExUnit.Case, async: false

  alias ExRatatui.Event
  alias TinyAxe.TUI

  @size {110, 32}

  defp draw(state) do
    {w, h} = @size
    terminal = ExRatatui.init_test_terminal(w, h)
    ExRatatui.draw(terminal, TUI.render(state, %ExRatatui.Frame{width: w, height: h}))
    ExRatatui.get_buffer_content(terminal)
  end

  defp key(code), do: %Event.Key{code: code, kind: "press", modifiers: []}

  defp running do
    {:ok, state} = TUI.mount(test_mode: @size)
    %{state | run: {make_ref(), self()}, transcript: [{:user, "post the release notes"}]}
  end

  defp event(%{run: {id, _}} = state, event) do
    {:noreply, state} = TUI.handle_info({:pipeline, id, event}, state)
    state
  end

  defp asking(state) do
    ref = make_ref()

    ask = %{
      tool: "github__create_issue",
      server: "github",
      description: "Opens an issue in a repository.",
      args: %{"repo" => "hightowerbuilds/tiny-axe", "title" => "Release notes for 0.2"},
      class: :outward,
      reply_to: self(),
      ref: ref
    }

    {event(state, {:tool_approval, ask}), ref}
  end

  test "an outward call shows the tool, what it does, and exactly what it would send" do
    {state, _} = asking(running())
    screen = draw(state)

    assert screen =~ "The agent wants to use github__create_issue"
    assert screen =~ "sends something off this machine"
    assert screen =~ "Release notes for 0.2"
    assert screen =~ "y allow once · a allow this tool for the session · n refuse"
  end

  test "every question says how risky it is: a banner and the border's colour" do
    for {class, banner} <- [
          read: "● ONLY READS",
          local: "▲ CHANGES SOMETHING ON THIS COMPUTER",
          outward: "■ SENDS SOMETHING OFF THIS MACHINE · CAN'T BE TAKEN BACK",
          commit: "■ SPENDS MONEY · CAN'T BE UNDONE"
        ] do
      {state, _} = asking(running())
      assert draw(%{state | tool_ask: %{state.tool_ask | class: class}}) =~ banner
    end
  end

  test "d shows everything it sends, and d again hides it; the keys stay in view" do
    {state, ref} = asking(running())
    screen = draw(state)
    assert screen =~ "title: Release notes for 0.2"
    refute screen =~ "Everything it sends:"
    assert screen =~ "n refuse · d show details"

    {:noreply, state} = TUI.handle_event(key("d"), state)
    screen = draw(state)
    assert screen =~ "Everything it sends:"
    assert screen =~ "Opens an issue in a repository."
    assert screen =~ "d hide details"
    refute_received {:tool_answer, ^ref, _}

    {:noreply, state} = TUI.handle_event(key("d"), state)
    refute draw(state) =~ "Everything it sends:"
  end

  test "the questions waiting behind it are listed, in order" do
    {state, _} = asking(running())
    {state, _} = asking(state)

    shell = %{
      tool: "shell_run",
      server: nil,
      description: "Run a shell command.",
      args: %{"command" => "npm install"},
      class: :outward,
      session_ok: false,
      shell: %{command: "npm install", dir: "~/code/web"},
      reply_to: self(),
      ref: make_ref()
    }

    state = event(state, {:tool_approval, shell})
    screen = draw(state)
    assert screen =~ "2 more questions waiting, in this order:"
    assert screen =~ "1. github__create_issue (sends something off this machine)"
    assert screen =~ "2. run $ npm install"
  end

  test "y, a and n answer the waiting call" do
    for {k, answer} <- [{"y", :once}, {"a", :session}, {"n", :deny}, {"esc", :deny}] do
      {state, ref} = asking(running())
      {:noreply, state} = TUI.handle_event(key(k), state)

      assert_received {:tool_answer, ^ref, ^answer}
      assert state.tool_ask == nil
    end
  end

  test "cancelling the request refuses a waiting call, so the gate lets it go" do
    {state, ref} = asking(running())
    {:noreply, state} = TUI.handle_event(key("esc"), %{state | tool_ask: state.tool_ask})
    assert_received {:tool_answer, ^ref, :deny}
    assert state.tool_ask == nil
  end

  test "a second question waits its turn, and the first answer brings it up" do
    {state, first} = asking(running())
    {state, second} = asking(state)

    assert state.tool_ask.ref == first
    assert [{:tool_ask, %{ref: ^second}}] = state.waiting
    assert draw(state) =~ "1 more question waiting"

    {:noreply, state} = TUI.handle_event(key("y"), state)
    assert_received {:tool_answer, ^first, :once}
    assert state.tool_ask.ref == second
    assert state.waiting == []

    {:noreply, state} = TUI.handle_event(key("n"), state)
    assert_received {:tool_answer, ^second, :deny}
    assert state.tool_ask == nil
  end

  test "cancelling refuses the run's waiting questions too, not another run's" do
    {state, first} = asking(running())
    {state, second} = asking(state)
    other = make_ref()
    elsewhere = %{tool: "x", server: "s", description: nil, args: %{}, class: :outward}
    elsewhere = Map.merge(elsewhere, %{reply_to: self(), ref: other, run: make_ref()})
    state = %{state | waiting: state.waiting ++ [{:tool_ask, elsewhere}]}

    # The run's process is killed: a stand-in, not this test.
    {id, _} = state.run
    state = TUI.Run.cancel(%{state | run: {id, spawn(fn -> Process.sleep(:infinity) end)}})

    assert_received {:tool_answer, ^first, :deny}
    assert_received {:tool_answer, ^second, :deny}
    refute_received {:tool_answer, ^other, _}
    assert state.tool_ask == nil
    assert [{:tool_ask, %{ref: ^other}}] = state.waiting
  end

  test "tool calls and refusals appear in the transcript" do
    state =
      running()
      |> event({:tool_call, %{tool: "web__search", class: :read, args: %{"q" => "elixir 1.19"}}})
      |> event(
        {:tool_result, %{tool: "web__search", decision: :ran, error: false, summary: "..."}}
      )
      |> event(
        {:tool_result,
         %{
           tool: "github__delete_repo",
           decision: :refused,
           error: true,
           summary: "tiny-axe stopped this call: tiny-axe doesn't allow this tool."
         }}
      )
      |> event({:tool_limit, %{reason: "the task reached its limit of 60 tool calls"}})

    metas = for {:meta, m} <- state.transcript, do: m

    assert ~s[🔧 web__search {"q":"elixir 1.19"} (only reads)] in metas
    assert Enum.any?(metas, &(&1 =~ "✗ github__delete_repo: tiny-axe stopped this call"))
    assert "⚠ the agent was stopped: the task reached its limit of 60 tool calls" in metas
    # A call that went through needs no line of its own.
    assert length(metas) == 3
  end

  test "an agent run says who's driving, and its answer follows its tool calls" do
    state =
      %{running() | pending_prompt: "post the release notes"}
      |> event({:agent, %{driver: "Claude haiku", servers: ["github"]}})
      |> event({:tool_call, %{tool: "github__get_release", class: :read, args: %{}}})
      |> event({:delta, "Posting…"})
      |> event({:answered_by, %{model: "Claude haiku"}})
      |> event({:done, "Posted the notes."})

    entries = Enum.drop(state.transcript, 1)

    assert [
             {:meta, "🤖 Claude haiku is working, with: github"},
             {:meta, "🔧 github__get_release (only reads)"},
             {:meta, "→ answered by Claude haiku, off this machine"},
             {:assistant, "Posted the notes."}
           ] = entries

    assert state.run == nil
  end

  test "what browser actions came to appears as short status lines" do
    state =
      running()
      |> event(
        {:outcome,
         %{
           id: "act-1",
           action: ~s(click "Post comment"),
           status: :unresolved,
           codes: ["outcome_unresolved", "response_lost"],
           by: :gate
         }}
      )
      |> event(
        {:outcome,
         %{id: "act-2", action: ~s(click "Send"), status: :succeeded, codes: [], by: :agent}}
      )
      |> event(
        {:outcome,
         %{
           id: "act-3",
           action: ~s(click "Save"),
           status: :failed,
           codes: ["error_shown"],
           by: :completion
         }}
      )
      |> event({:completion, %{outcome: :replaced, confirmed: [], unresolved: [], failed: []}})
      |> event({:completion, %{outcome: :delivered, confirmed: [], unresolved: [], failed: []}})

    metas = for {:meta, m} <- state.transcript, do: m

    assert metas == [
             ~s[? not confirmed: click "Post comment" (response_lost)],
             ~s(✓ confirmed: click "Send"),
             ~s[✗ didn't take effect: click "Save" (error_shown)],
             "⚠ tiny-axe held back the agent's reply: what it checked contradicts it"
           ]
  end

  test "the agent's command shows the command and its folder, and offers only y or n" do
    ref = make_ref()

    ask = %{
      tool: "shell_run",
      server: nil,
      description: "Run a shell command.",
      args: %{"command" => "npm install"},
      class: :outward,
      reason: "runs a command in ~/code/web that can change things",
      session_ok: false,
      shell: %{command: "npm install", dir: "~/code/web"},
      reply_to: self(),
      ref: ref
    }

    state = event(running(), {:tool_approval, ask})
    screen = draw(state)

    assert screen =~ "■ RUNS A COMMAND · CAN'T BE UNDONE WITH CTRL+Z"
    assert screen =~ "The agent wants to run a command"
    assert screen =~ "in ~/code/web"
    assert screen =~ "$ npm install"
    assert screen =~ "y run · n refuse"
    refute screen =~ "for the session"

    {:noreply, state} = TUI.handle_event(key("a"), state)
    refute_received {:tool_answer, ^ref, _}
    {:noreply, _state} = TUI.handle_event(key("y"), state)
    assert_received {:tool_answer, ^ref, :once}
  end

  describe "browser actions" do
    defp browser_ask(state, class, reason) do
      ref = make_ref()

      ask = %{
        tool: "browser__browser_click",
        server: "browser",
        description: "Click an element.",
        args: %{"ref" => "e12", "element" => "Send message"},
        class: class,
        reason: reason,
        session_ok: false,
        reply_to: self(),
        ref: ref
      }

      {event(state, {:tool_approval, ask}), ref}
    end

    test "say what the click would do, and offer only y or n" do
      {state, ref} =
        browser_ask(running(), :outward, ~s(submits the form "Contact us" to example.com (POST\)))

      screen = draw(state)

      assert screen =~ ~s(It submits the form "Contact us" to example.com (POST\).)
      assert screen =~ "y allow · n refuse"
      refute screen =~ "allow this tool for the session"

      # "a" (for the session) does nothing here.
      {:noreply, state} = TUI.handle_event(key("a"), state)
      refute_received {:tool_answer, ^ref, _}
      assert state.tool_ask != nil
    end

    test "a handoff asks the user to do it in the window" do
      {state, ref} = browser_ask(running(), :handoff, "sign in to the shop")
      screen = draw(state)

      assert screen =~ "Your turn in the browser"
      assert screen =~ "The agent needs you to: sign in to the shop."
      assert screen =~ "y done · n I won't"

      {:noreply, state} = TUI.handle_event(key("y"), state)
      assert_received {:tool_answer, ^ref, :once}
      assert List.last(state.transcript) == {:meta, "you did it in the browser"}
    end
  end

  describe "a purchase" do
    defp purchase(state) do
      ref = make_ref()

      ask = %{
        summary: %{
          "host" => "shop.example",
          "total" => 16.0,
          "total_text" => "$16.00",
          "currency" => "USD",
          "items" => ["Blue mug × 1 — $12.00"],
          "ship_to" => "Ship to:, Sam Lee, 1 High St",
          "payment" => "Paying with Visa ending in 4242"
        },
        checks: [{:ok, "within your maximum of $50.00"}, {:ok, "$16.00 of $200.00 today"}],
        reply_to: self(),
        ref: ref
      }

      {event(state, {:purchase_approval, ask}), ref}
    end

    defp type(state, keys) do
      Enum.reduce(String.graphemes(keys), state, fn k, st ->
        {:noreply, st} = TUI.handle_event(key(k), st)
        st
      end)
    end

    test "shows the order code read from the page, and the checks" do
      {state, _} = purchase(running())
      screen = draw(state)

      assert screen =~ "■ SPENDS MONEY · CAN'T BE UNDONE"
      assert screen =~ "Shop: shop.example"
      assert screen =~ "Total: $16.00 USD"
      assert screen =~ "Blue mug × 1 — $12.00"
      assert screen =~ "Paying with Visa ending in 4242"
      assert screen =~ "✓ within your maximum of $50.00"
      assert screen =~ "Type 16.00 and press enter to buy"
    end

    test "only the exact total, typed, buys; y doesn't" do
      {state, ref} = purchase(running())

      state = type(state, "y")
      {:noreply, state} = TUI.handle_event(key("enter"), state)
      refute_received {:purchase_answer, ^ref, _}
      assert state.purchase_ask.hint =~ "type 16.00 exactly"

      state = type(state, "16.0")
      {:noreply, state} = TUI.handle_event(key("enter"), state)
      refute_received {:purchase_answer, ^ref, _}

      state = type(state, "0")
      {:noreply, state} = TUI.handle_event(key("enter"), state)
      assert_received {:purchase_answer, ^ref, :confirm}
      assert state.purchase_ask == nil
    end

    test "esc refuses, and so does cancelling the request" do
      {state, ref} = purchase(running())
      {:noreply, _} = TUI.handle_event(key("esc"), state)
      assert_received {:purchase_answer, ^ref, :deny}

      # ctrl+c kills the request's process: give it one of its own.
      worker = spawn(fn -> Process.sleep(:infinity) end)
      {state, ref} = purchase(%{running() | run: {make_ref(), worker}})

      {:stop, _} =
        TUI.handle_event(%Event.Key{code: "c", kind: "press", modifiers: ["ctrl"]}, state)

      assert_received {:purchase_answer, ^ref, :deny}
    end

    test "what happened appears in the transcript" do
      state =
        running()
        |> event(
          {:purchase_refused,
           %{
             summary: %{"host" => "shop.example", "total_text" => "$16.00"},
             failed: ["over your maximum"]
           }}
        )
        |> event(
          {:purchased,
           %{host: "shop.example", total_text: "$16.00", order: "TA-1001", dir: "/tmp/x"}}
        )

      metas = for {:meta, m} <- state.transcript, do: m
      assert "✗ tiny-axe won't buy at shop.example ($16.00): over your maximum" in metas
      assert Enum.any?(metas, &(&1 =~ "🧾 bought at shop.example for $16.00 · order TA-1001"))
    end
  end

  describe "/leash" do
    defp status_bar(state), do: draw(state) |> String.split("\n") |> Enum.find(&(&1 =~ "ctx"))

    defp typed(state, text) do
      ExRatatui.textarea_set_value(state.input, text)
      {:noreply, state} = TUI.handle_event(key("enter"), state)
      state
    end

    test "on, off and how it stands; the status bar shows it; a leashed order says so" do
      on_exit(fn -> TinyAxe.Leash.set(false) end)
      {:ok, state} = TUI.mount(test_mode: @size)

      state = typed(state, "/leash on")
      assert TinyAxe.Leash.on?()
      assert {:meta, "🔓 leash on for this session" <> _} = List.last(state.transcript)
      assert status_bar(state) =~ ~r/🔓\s+leash/

      state = %{state | run: {make_ref(), self()}}

      state =
        event(
          state,
          {:purchase_leashed,
           %{summary: %{"host" => "shop.example", "total_text" => "$16.00"}, mode: :order}}
        )

      assert List.last(state.transcript) ==
               {:meta,
                "🔓 on the leash, every check passed: placing the order at shop.example for $16.00"}

      state = typed(%{state | run: nil}, "/leash off")
      refute TinyAxe.Leash.on?()
      refute status_bar(state) =~ ~r/🔓\s+leash/
    end
  end
end
