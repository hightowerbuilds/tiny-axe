defmodule TinyAxe.TUI.Transcript do
  @moduledoc """
  Formats transcript entries and measures their rendered Markdown height.
  The process-local cache belongs to the TUI process and can be cleared explicitly.
  """

  alias ExRatatui.Layout.Rect
  alias ExRatatui.Widgets.Markdown

  @cache_key {__MODULE__, :entries}

  # One Markdown string per transcript entry; the transcript is these joined
  # by blank lines, which renders exactly as tall as the entries plus one line
  # between each.
  @spec entries_markdown(map()) :: [String.t()]
  def entries_markdown(state) do
    completed = Enum.map(cached_entries(state.transcript), & &1.markdown)
    completed ++ Enum.map(live_entries(state), &entry_markdown/1)
  end

  defp entry_markdown({:user, text}), do: "#### ▍you\n\n" <> keep_indent(text)
  defp entry_markdown({:assistant, text}), do: "#### ▍tiny-axe\n\n" <> keep_indent(text)
  defp entry_markdown({:meta, text}), do: "*· " <> text <> "*"

  defp entry_markdown({:output, command, output, status}) do
    lines = String.split(output, "\n")
    shown = Enum.take(lines, -40)
    cut = if length(lines) > 40, do: "… (#{length(lines) - 40} earlier lines)\n", else: ""

    status =
      case status do
        :running -> "*running…*"
        0 -> "*✓ exit 0*"
        n when is_integer(n) -> "*✗ exit #{n}*"
        other -> "*✗ #{other}*"
      end

    keep_indent("```console\n$ #{command}\n#{cut}#{Enum.join(shown, "\n")}\n```") <>
      "\n" <> status
  end

  # What's still arriving: the answer being streamed and the command running.
  defp live_entries(state) do
    streaming = if state.streaming, do: [{:assistant, state.streaming <> " ▌"}], else: []

    running =
      case state.running_cmd do
        %{command: c, output: o} -> [{:output, c, String.trim_trailing(o), :running}]
        nil -> []
      end

    streaming ++ running
  end

  # The Markdown widget wraps with trimming, which strips the indentation from
  # code blocks. Non-breaking spaces survive trimming, so leading spaces in
  # code blocks (including one still streaming) become those.
  defp keep_indent(text) do
    Regex.replace(~r/```.*?(```|\z)/s, text, fn block, _ ->
      Regex.replace(~r/^[ \t]+/m, block, fn indent ->
        indent |> String.replace("\t", "  ") |> String.replace(" ", "\u00A0")
      end)
    end)
  end

  # The rendered height of the transcript at `width`. The Markdown widget can't
  # report it and an estimate drifts (25 lines over 800), so entries are
  # rendered off-screen and measured. Formatting and heights are cached by the
  # exact entry, not a lossy hash. Only the current transcript is retained, so
  # replacing attempts or clearing a conversation releases obsolete entries.
  @spec height(map(), pos_integer()) :: non_neg_integer()
  def height(state, width) do
    heights = Enum.map(cached_entries(state.transcript, width), & &1.height)
    streaming = Enum.map(live_entries(state), &measure(entry_markdown(&1), width))

    heights = heights ++ streaming
    Enum.sum(heights) + max(length(heights) - 1, 0)
  end

  # Keep one width per entry: resizing remeasures without reformatting. Live
  # output is never cached, so a streaming answer cannot grow the cache.
  defp cached_entries(entries, width \\ nil) do
    previous = Process.get(@cache_key, %{})

    {formatted, current} =
      Enum.map_reduce(entries, %{}, fn entry, current ->
        cached =
          Map.get(current, entry) || Map.get(previous, entry) ||
            %{markdown: entry_markdown(entry), width: nil, height: nil}

        cached =
          if width != nil and cached.width != width,
            do: %{cached | width: width, height: measure(cached.markdown, width)},
            else: cached

        {cached, Map.put(current, entry, cached)}
      end)

    Process.put(@cache_key, current)
    formatted
  end

  @max_rows 60_000

  defp measure(md, width, rows \\ nil) do
    rows =
      rows ||
        min(2 * (length(String.split(md, "\n")) + div(String.length(md), width)) + 8, @max_rows)

    terminal = ExRatatui.init_test_terminal(width, rows)

    ExRatatui.draw(terminal, [
      {%Markdown{content: md}, %Rect{x: 0, y: 0, width: width, height: rows}}
    ])

    lines = terminal |> ExRatatui.get_buffer_content() |> String.split("\n")
    blank_tail = lines |> Enum.reverse() |> Enum.take_while(&(String.trim(&1) == "")) |> length()
    used = length(lines) - blank_tail

    # Filled to the last row: it may not have fit, so measure again with room to spare.
    if used >= rows and rows < @max_rows,
      do: measure(md, width, min(rows * 2, @max_rows)),
      else: used
  end

  @doc "Drops formatted entries and measurements when the transcript is cleared."
  def clear_cache, do: Process.delete(@cache_key)
end
