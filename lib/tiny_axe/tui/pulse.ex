defmodule TinyAxe.TUI.Pulse do
  @moduledoc """
  The prompt cursor's pulse: every couple of seconds the cursor warms from
  orange to green and a soft green ring spreads from it across the prompt
  box, with a dimmer ring trailing. Tiny-axe's colours, kept quiet.

  Rings only tint the background of the cells they cross (a borderless Block
  with a style), so the text underneath stays as typed. They run while
  tiny-axe is waiting for input, not during a request.
  `config :tiny_axe, cursor_pulse: false` turns it off.
  """

  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Widgets.Block

  @frame_ms 70
  # Frames per pulse; the ring travels for the first @ring_frames of them.
  @frames 28
  @ring_frames 10
  # Rows the ring grows per frame; a cell is twice as tall as it is wide, so
  # it grows twice as many columns.
  @speed 1.0

  # The ring: tiny-axe's green, never at full strength, over a dark ember.
  @hot {96, 160, 88}
  @cool {40, 28, 14}
  # The cursor: its orange, warming to green as each ring leaves.
  @orange {190, 120, 50}
  @green {126, 211, 115}

  @doc "Whether the pulse is on."
  def enabled?, do: Application.get_env(:tiny_axe, :cursor_pulse, true)

  def schedule, do: Process.send_after(self(), :pulse, @frame_ms)

  def new, do: %{frame: 0, top: 0}

  @doc """
  Advances one frame, and follows the textarea's scrolling: like the textarea,
  the visible rows move only as far as needed to keep the cursor in view.
  """
  def step(%{pulse: pulse, size: {width, _}} = state) do
    {row, _col} = cursor(state, width)
    top = follow(pulse.top, row, inner_height())
    %{state | pulse: %{frame: rem(pulse.frame + 1, @frames), top: top}}
  end

  @doc "The cursor's own style: a flare as each ring leaves, settling to a steady glow."
  def cursor_style(%{run: nil, pulse: %{frame: frame}}) do
    glow = max(0.0, 1.0 - frame / @ring_frames)
    %Style{fg: :black, bg: rgb(mix(@orange, @green, glow))}
  end

  def cursor_style(_state), do: %Style{fg: :black, bg: :dark_gray}

  @doc "The ring's cells around the cursor in the prompt box `area` (its border included)."
  def widgets(%{run: nil, pulse: %{frame: frame} = pulse} = state, %Rect{} = area)
      when frame in 1..@ring_frames do
    inner = %Rect{x: area.x + 1, y: area.y + 1, width: area.width - 2, height: area.height - 2}
    {row, col} = cursor(state, area.width)
    center = {inner.x + min(col, inner.width - 1), inner.y + row - pulse.top}

    inner
    |> ring(center, frame * @speed)
    |> Enum.map(fn {{x, y, len}, color} ->
      {%Block{borders: [], style: %Style{bg: rgb(color)}},
       %Rect{x: x, y: y, width: len, height: 1}}
    end)
  end

  def widgets(_state, _area), do: []

  @doc """
  Cells within the ring of `radius` around `center`, clipped to `inner`, as
  runs of same-colored cells on a row: `[{{x, y, length}, {r, g, b}}]`. The
  center itself is left to the cursor.
  """
  def ring(%Rect{} = inner, {cx, cy}, radius) do
    fade = max(0.0, 1.0 - radius / (@ring_frames * @speed + 1))

    for y <- inner.y..(inner.y + inner.height - 1)//1,
        x <- inner.x..(inner.x + inner.width - 1)//1,
        {x, y} != {cx, cy},
        level = level(radius - :math.sqrt(:math.pow((x - cx) / 2, 2) + :math.pow(y - cy, 2))),
        level > 0 do
      {x, y, mix(@cool, @hot, 0.8 * fade * level)}
    end
    |> Enum.chunk_while(nil, &run/2, &close/1)
  end

  # The ring's leading edge is full strength; just behind it, a dimmer trail.
  defp level(behind) when behind >= 0 and behind < 0.75, do: 1.0
  defp level(behind) when behind >= 0.75 and behind < 1.75, do: 0.35
  defp level(_), do: 0

  defp run({x, y, color}, {{x0, y, len}, color}) when x == x0 + len,
    do: {:cont, {{x0, y, len + 1}, color}}

  defp run({x, y, color}, nil), do: {:cont, {{x, y, 1}, color}}
  defp run({x, y, color}, acc), do: {:cont, acc, {{x, y, 1}, color}}

  defp close(nil), do: {:cont, nil}
  defp close(acc), do: {:cont, acc, nil}

  ## Where the cursor is on screen

  # The cursor's visual {row, col} in a prompt box `box_width` wide.
  defp cursor(state, box_width) do
    lines = state.input |> ExRatatui.textarea_get_value() |> String.split("\n")
    position(lines, ExRatatui.textarea_cursor(state.input), box_width - 2)
  end

  @doc """
  Where the cursor at `{row, col}` of `lines` lands once the lines are word
  wrapped to `width`: `{visual_row, visual_col}`. Close to the textarea's own
  wrapping; a small difference only moves where the ring starts.
  """
  def position(lines, {row, col}, width) do
    before = lines |> Enum.take(row) |> Enum.map(&length(wrap_starts(&1, width))) |> Enum.sum()
    starts = wrap_starts(Enum.at(lines, row, ""), width)
    index = Enum.count(starts, &(&1 <= col)) - 1
    {before + index, col - Enum.at(starts, index)}
  end

  @doc "Where each visual row of `line` starts, word wrapped to `width`."
  def wrap_starts(_line, width) when width < 1, do: [0]

  def wrap_starts(line, width) do
    line
    |> String.graphemes()
    |> Enum.with_index()
    |> Enum.chunk_by(fn {g, _} -> g == " " end)
    |> Enum.reduce({[0], 0}, fn [{g, start} | _] = token, {starts, row_start} ->
      len = length(token)

      cond do
        start + len - row_start <= width -> {starts, row_start}
        # Spaces hang off the end of a row rather than starting the next.
        g == " " -> {starts, row_start}
        len <= width -> {[start | starts], start}
        true -> long_word(start, len, width, starts, row_start)
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  # A word longer than a row starts its own row and breaks every `width`.
  defp long_word(start, len, width, starts, row_start) do
    breaks = start..(start + len - 1)//width |> Enum.reject(&(&1 == row_start))
    {Enum.reverse(breaks) ++ starts, List.last([row_start | breaks])}
  end

  defp follow(top, row, height) do
    cond do
      row < top -> row
      row >= top + height -> row - height + 1
      true -> top
    end
  end

  defp inner_height, do: TinyAxe.TUI.View.input_height() - 2

  defp mix({r1, g1, b1}, {r2, g2, b2}, t),
    do: {round(r1 + (r2 - r1) * t), round(g1 + (g2 - g1) * t), round(b1 + (b2 - b1) * t)}

  defp rgb({r, g, b}), do: {:rgb, r, g, b}
end
