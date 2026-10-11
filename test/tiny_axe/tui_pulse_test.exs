defmodule TinyAxe.TUIPulseTest do
  use ExUnit.Case, async: true

  alias ExRatatui.Layout.Rect
  alias ExRatatui.Widgets.Block
  alias TinyAxe.TUI
  alias TinyAxe.TUI.Pulse

  @size {80, 24}

  defp mounted(text \\ "") do
    {:ok, state} = TUI.mount(test_mode: @size)
    # Typed in, so the cursor ends up after the text.
    ExRatatui.textarea_insert_str(state.input, text)
    state
  end

  defp frame(state, n), do: put_in(state.pulse.frame, n)

  # The prompt box: the bottom 6 rows, full width.
  defp box, do: %Rect{x: 0, y: 18, width: 80, height: 6}

  test "word wrapping: where each visual row starts" do
    assert Pulse.wrap_starts("", 10) == [0]
    assert Pulse.wrap_starts("short", 10) == [0]
    assert Pulse.wrap_starts("hello there world", 10) == [0, 6, 12]
    # A word longer than a row breaks every `width`.
    assert Pulse.wrap_starts("abcdefghijklmnopqrstuvwxy", 10) == [0, 10, 20]
    assert Pulse.wrap_starts("hi abcdefghijklmnop", 10) == [0, 3, 13]
  end

  test "the cursor's place on screen follows wrapped and earlier lines" do
    assert Pulse.position(["hello"], {0, 5}, 20) == {0, 5}
    assert Pulse.position(["hello there world"], {0, 14}, 10) == {2, 2}
    assert Pulse.position(["hello there world", "next"], {1, 2}, 10) == {3, 2}
  end

  test "the ring is a band at its radius, wider than tall, leaving the cursor alone" do
    inner = %Rect{x: 0, y: 0, width: 40, height: 9}

    cells =
      for {{x, y, len}, _color} <- Pulse.ring(inner, {20, 4}, 3.0),
          i <- 0..(len - 1),
          do: {x + i, y}

    refute {20, 4} in cells
    # Three rows up or down, six columns across (cells are twice as tall as wide).
    assert {20, 1} in cells and {20, 7} in cells
    assert {26, 4} in cells and {14, 4} in cells
    refute {21, 4} in cells
    # Only inside the box.
    assert Enum.all?(cells, fn {x, y} -> x in 0..39 and y in 0..8 end)
  end

  test "the leading edge is brighter than the trail behind it" do
    inner = %Rect{x: 0, y: 0, width: 40, height: 1}

    colors =
      Map.new(
        for {{x, _y, len}, c} <- Pulse.ring(inner, {20, 0}, 3.0),
            i <- 0..(len - 1),
            do: {x + i, c}
      )

    {r_edge, _, _} = colors[26]
    {r_trail, _, _} = colors[24]
    assert r_edge > r_trail
  end

  test "rings tint the prompt box while waiting for input, and stop during a request" do
    state = mounted("hello") |> frame(3)
    widgets = Pulse.widgets(state, box())

    assert widgets != []

    for {%Block{borders: [], style: style}, rect} <- widgets do
      assert {:rgb, _, _, _} = style.bg
      # Inside the box's border.
      assert rect.y in 19..22 and rect.x >= 1 and rect.x + rect.width <= 79
    end

    assert Pulse.widgets(frame(state, 0), box()) == []
    assert Pulse.widgets(%{state | run: {make_ref(), self()}}, box()) == []
  end

  test "the cursor flares as a ring leaves, then settles" do
    state = mounted()
    {:rgb, _, bright, _} = Pulse.cursor_style(frame(state, 0)).bg
    {:rgb, _, settled, _} = Pulse.cursor_style(frame(state, 12)).bg
    assert bright > settled
  end

  test ":pulse advances the frame and keeps the cursor's row in view" do
    state = mounted(Enum.join(1..8, "\n"))
    {:noreply, state} = TUI.handle_info(:pulse, state)

    assert state.pulse.frame == 1
    # The cursor is on the 8th line; the box shows 4, so the first shown is the 5th.
    assert state.pulse.top == 4

    {:noreply, state} = TUI.handle_info(:pulse, frame(state, 15))
    assert state.pulse.frame == 0
  end

  test "the screen still draws with a ring on it" do
    state = mounted("draw me") |> frame(4)
    {w, h} = @size
    terminal = ExRatatui.init_test_terminal(w, h)
    ExRatatui.draw(terminal, TUI.render(state, %ExRatatui.Frame{width: w, height: h}))
    assert ExRatatui.get_buffer_content(terminal) =~ "draw me"
  end
end
