defmodule TinyAxe.TUIExplainedTest do
  use ExUnit.Case, async: true

  alias ExRatatui.Event
  alias TinyAxe.TUI
  alias TinyAxe.TUI.{Explained, MainTabs}

  @size {100, 32}

  defp mounted do
    {:ok, state} = TUI.mount(test_mode: @size)
    state
  end

  defp event(state, event) do
    case TUI.handle_event(event, state) do
      {:noreply, state} -> state
      {:noreply, state, _opts} -> state
    end
  end

  defp key(state, code), do: event(state, %Event.Key{code: code, kind: "press", modifiers: []})

  defp type(state, text) do
    ExRatatui.textarea_set_value(state.input, text)
    key(state, "enter")
  end

  defp draw(state) do
    {w, h} = state.size
    terminal = ExRatatui.init_test_terminal(w, h)
    ExRatatui.draw(terminal, TUI.render(state, %ExRatatui.Frame{width: w, height: h}))
    ExRatatui.get_buffer_content(terminal)
  end

  test "/help and /explained open the Explained tab, without a model" do
    state = type(mounted(), "/help")
    assert state.section == :explained
    assert state.run == nil
    screen = draw(state)
    assert screen =~ "Explained"
    assert screen =~ "What tiny-axe can do"
    assert screen =~ "Getting around"

    state = state |> key("f1") |> type("/explained")
    assert state.section == :explained
  end

  test "it's a tab along the top: clicking it opens it" do
    state = mounted()
    tab = Enum.find(MainTabs.layout(state, 100), &(&1.action == {:section, :explained}))
    assert tab.label == " Explained "

    state = event(state, %Event.Mouse{kind: "down", button: "left", x: tab.x, y: 0})
    assert state.section == :explained
  end

  test "it scrolls to the slash commands at the end; typing goes nowhere" do
    state = type(mounted(), "/help")
    refute draw(state) =~ "Slash commands"

    state = Enum.reduce(1..200, state, fn _, s -> key(s, "down") end)
    assert draw(state) =~ "/remote pin"

    state = key(state, "x")
    assert ExRatatui.textarea_get_value(state.input) == ""
  end

  test "every line fits the width it's wrapped to" do
    for width <- [40, 80, 120] do
      for line <- Explained.lines(width) do
        text = Enum.map_join(line.spans, & &1.content)
        assert String.length(text) <= width, "#{inspect(text)} is wider than #{width}"
      end
    end
  end
end
