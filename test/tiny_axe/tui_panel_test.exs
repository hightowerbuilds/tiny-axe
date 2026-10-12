defmodule TinyAxe.TUIPanelTest do
  @moduledoc """
  The panel (`TinyAxe.TUI.Panel`): its tabs, opened by their commands, and
  what each does; and `/route`.
  """

  use ExUnit.Case, async: false

  alias ExRatatui.Event
  alias TinyAxe.{History, TUI}
  alias TinyAxe.TUI.Prefs

  @size {100, 40}

  setup do
    File.rm_rf!(History.dir())
    File.rm(Prefs.path())

    on_exit(fn ->
      File.rm_rf!(History.dir())
      File.rm(Prefs.path())
    end)
  end

  defp mounted(opts \\ []) do
    {:ok, state} = TUI.mount([test_mode: @size, remote: self()] ++ opts)
    state
  end

  defp draw(state) do
    {w, h} = @size
    terminal = ExRatatui.init_test_terminal(w, h)
    ExRatatui.draw(terminal, TUI.render(state, %ExRatatui.Frame{width: w, height: h}))
    ExRatatui.get_buffer_content(terminal)
  end

  defp key(state, code, mods \\ []) do
    case TUI.handle_event(%Event.Key{code: code, kind: "press", modifiers: mods}, state) do
      {:noreply, state} -> state
      {:noreply, state, _opts} -> state
    end
  end

  defp type(state, text) do
    ExRatatui.textarea_set_value(state.input, text)
    key(state, "enter")
  end

  defp typed(state, text), do: text |> String.graphemes() |> Enum.reduce(state, &key(&2, &1))

  defp kept(id, title, words) do
    File.mkdir_p!(History.dir())

    File.write!(
      Path.join(History.dir(), id <> ".json"),
      JSON.encode!(%{
        version: 1,
        id: id,
        session: "20261012-090000-0000",
        started: "2026-10-12T09:00:00Z",
        updated: "2026-10-12T09:05:00Z",
        title: title,
        folder: "~",
        entries: [%{kind: "user", text: words}, %{kind: "assistant", text: "done"}],
        context: %{history: [], summary: nil}
      })
    )
  end

  describe "the tabs" do
    test "each command opens its tab; tab, shift+tab and the arrows move; esc closes" do
      for {command, tab} <- [
            {"/remote", :remote},
            {"/token", :token},
            {"/wallet", :wallet},
            {"/credit-card", :wallet},
            {"/search", :search}
          ] do
        state = type(mounted(), command)
        assert state.panel.tab == tab, command
        assert state.run == nil
        assert ExRatatui.textarea_get_value(state.input) == ""
      end

      state = type(mounted(), "/remote")
      assert draw(state) =~ "Remote │ Token │ Wallet │ Search"
      assert key(state, "tab").panel.tab == :token
      assert key(state, "right").panel.tab == :token
      assert key(state, "back_tab").panel.tab == :search
      assert key(state, "left").panel.tab == :search

      state = state |> key("tab") |> key("tab") |> key("tab") |> key("tab")
      assert state.panel.tab == :remote

      # Keys go to the panel, not the prompt; esc closes it.
      state = key(state, "x")
      assert ExRatatui.textarea_get_value(state.input) == ""
      state = key(state, "esc")
      assert state.panel == nil
      refute draw(state) =~ "Remote │ Token"
    end

    test "a question comes up on top of it and takes the keys" do
      state = type(mounted(), "/wallet")

      ask = %{
        tool: "create_issue",
        server: "github",
        class: :outward,
        args: %{},
        description: nil,
        reply_to: self(),
        ref: make_ref()
      }

      state = key(%{state | tool_ask: ask}, "n")
      assert_received {:tool_answer, _, :deny}
      assert state.panel.tab == :wallet
    end
  end

  describe "Wallet" do
    test "no cards yet says how to add one; a starts the card flow, esc goes back" do
      state = type(mounted(), "/wallet")
      assert draw(state) =~ "No cards yet."

      state = key(state, "a")
      assert state.card_flow
      state = key(state, "esc")
      assert state.card_flow == nil
      assert state.panel.tab == :wallet
    end

    test "f with no card chosen does nothing" do
      state = type(mounted(), "/wallet") |> key("f")
      assert state.panel.forgetting == nil
    end

    test "/credit-card list still lists in the chat" do
      state = type(mounted(), "/credit-card list")
      assert state.panel == nil
      assert List.last(state.transcript) == {:meta, "no cards yet; add one with a in /wallet"}
    end
  end

  describe "Search" do
    test "type, enter searches, ↑↓ choose, enter opens the chat" do
      kept("20261012-090000-aaaa", "printer drivers", "my printer won't print")
      kept("20261012-091000-bbbb", "port 4000", "what's using port 4000?")

      state = type(mounted(), "/search") |> typed("printer")
      assert draw(state) =~ "Search: printer"
      assert state.panel.results == []

      state = key(state, "enter")
      assert [%{id: "20261012-090000-aaaa"}] = state.panel.results
      assert draw(state) =~ "printer drivers"

      state = key(state, "enter")
      assert state.panel == nil
      assert {:meta, "reopened “printer drivers”" <> _} = List.last(state.transcript)
    end

    test "/search WORDS searches at once; backspace edits; nothing found says so" do
      kept("20261012-091000-bbbb", "port 4000", "what's using port 4000?")

      state = type(mounted(), "/search port")
      assert [%{title: "port 4000"}] = state.panel.results

      state =
        state |> key("backspace") |> key("backspace") |> key("backspace") |> key("backspace")

      state = state |> typed("nothing") |> key("enter")
      assert state.panel.results == []
      assert draw(state) =~ "No kept chat has “nothing”."
    end
  end

  describe "/route" do
    defp routed(state) do
      id = make_ref()
      route = %{kind: %{choice: :code, probabilities: %{code: 0.97}, confidence: 0.9}}
      state = %{state | run: {id, self()}}
      {:noreply, state} = TUI.handle_info({:pipeline, id, {:route, route}}, state)
      state
    end

    test "hidden by default; /route on shows it and is remembered; /route off hides it" do
      state = routed(mounted())
      refute Enum.any?(state.transcript, &match?({:meta, "route → " <> _}, &1))
      assert state.status == "generating (code)…"

      state = type(%{mounted() | run: nil}, "/route on")
      assert state.route_line
      assert Prefs.get("route_line") == true
      assert mounted().route_line

      state = routed(state)
      assert {:meta, "route → code (97%" <> _} = List.last(state.transcript)

      state = type(%{state | run: nil}, "/route off")
      refute state.route_line
      refute mounted().route_line
    end
  end
end
