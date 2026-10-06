defmodule TinyAxe.TUI.View do
  @moduledoc """
  Builds the main terminal layout and maps scroll positions to rendered rows.
  Workflow state remains owned by TinyAxe.TUI.
  """

  alias ExRatatui.Layout
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Text.{Line, Span}
  alias ExRatatui.Widgets.{Block, Markdown, Paragraph, Textarea, Throbber}
  alias TinyAxe.Context
  alias TinyAxe.TUI.{Overlays, Transcript}
  import TinyAxe.TUI.Presentation, only: [styled: 1, styled: 2, review_label: 1]
  import TinyAxe.TUI.Conversation, only: [context_tokens: 1]

  @input_height 6
  @sidebar_width 44

  def render(state, frame) do
    area = %Rect{x: 0, y: 0, width: frame.width, height: frame.height}
    [transcript_area, status_area, input_area] = split(area)
    {transcript_area, sidebar} = split_sidebar(state, transcript_area)

    size = {frame.width, frame.height}
    bottom = max_top(state, size)
    top = scroll_top(state.scroll, bottom)

    transcript = %Markdown{
      content: Enum.join(Transcript.entries_markdown(state), "\n\n"),
      scroll: {top, 0},
      block: %Block{
        title: title(state, bottom - top),
        borders: [:all],
        border_type: :rounded,
        border_style: %Style{fg: :dark_gray}
      }
    }

    input = %Textarea{
      state: state.input,
      placeholder: "Ask for code or text…  (enter to send, alt+enter for newline)",
      placeholder_style: %Style{fg: :dark_gray},
      wrap_mode: :word,
      block: %Block{
        title: " prompt ",
        borders: [:all],
        border_type: :rounded,
        border_style: %Style{fg: if(state.run, do: :dark_gray, else: :cyan)}
      }
    }

    [{transcript, transcript_area}, {status_widget(state), status_area}, {input, input_area}] ++
      sidebar ++ Overlays.render(state, area)
  end

  ## Sidebar: the context meter and the compacted summary

  defp split_sidebar(state, area) do
    if sidebar?(state, area.width) do
      [main, side] = Layout.split(area, :horizontal, [{:fill, 1}, {:length, @sidebar_width}])
      {main, sidebar_widgets(state, side)}
    else
      {area, []}
    end
  end

  # Shown automatically on wide screens once there's something worth seeing.
  def sidebar?(state, width) do
    case state.sidebar do
      nil ->
        width >= 110 and
          (state.summary != nil or state.compacting != nil or
             Context.fraction(context_tokens(state)) >= 0.25)

      shown ->
        shown and width >= @sidebar_width + 30
    end
  end

  defp sidebar_widgets(state, area) do
    [meter_area, summary_area] = Layout.split(area, :vertical, [{:length, 6}, {:fill, 1}])
    tokens = context_tokens(state)
    fraction = Context.fraction(tokens)

    color =
      cond do
        fraction < 0.5 -> :green
        fraction < 0.8 -> :yellow
        true -> :red
      end

    cells = 22
    filled = round(fraction * cells)

    last =
      case state.usage do
        %{prompt_tokens: p, output_tokens: o} ->
          "last request #{Context.short(p + o)}, incl. web/files"

        nil ->
          "no request measured yet"
      end

    compact_at = round(Application.get_env(:tiny_axe, :compact_at, 0.5) * 100)

    meter = %Paragraph{
      text: [
        Line.new([
          Span.new(String.duplicate("▰", filled), style: %Style{fg: color}),
          Span.new(String.duplicate("▱", cells - filled), style: %Style{fg: :dark_gray}),
          Span.new(" #{round(fraction * 100)}%", style: %Style{fg: color, modifiers: [:bold]})
        ]),
        styled("#{Context.short(tokens)} of #{Context.short(Context.window())} tokens"),
        styled(last, :dark_gray),
        styled("compacts at #{compact_at}% · ctrl+k now · ctrl+t hide", :dark_gray)
      ],
      block: %Block{
        title: " context ",
        borders: [:all],
        border_type: :rounded,
        border_style: %Style{fg: :dark_gray}
      }
    }

    {title, content} =
      cond do
        state.compacting != nil ->
          {" compacting… ", state.compacting <> " ▌"}

        state.summary != nil ->
          s = state.summary

          # The title stays short enough for the sidebar; the details lead the text.
          saved =
            if s[:before],
              do: "#{Context.short(s.before)} → #{Context.short(s.after)} tokens · ",
              else: ""

          {" compacted · #{s.turns} #{if s.turns == 1, do: "turn", else: "turns"} ",
           "*#{saved}#{s.check |> review_label() |> elem(0)}*\n\n" <> s.text}

        true ->
          {" compacted ",
           "*Nothing yet. When the conversation fills #{compact_at}% of the window, older turns are condensed into a summary here, and the newest two stay word for word.*"}
      end

    summary = %Markdown{
      content: content,
      block: %Block{
        title: title,
        borders: [:all],
        border_type: :rounded,
        border_style: %Style{fg: :cyan}
      }
    }

    [{meter, meter_area}, {summary, summary_area}]
  end

  # Calls that left the machine this session, and Claude's usage once known.
  defp remote_label do
    case TinyAxe.Escalation.stats() do
      %{remote_calls: 0} ->
        ""

      %{remote_calls: n, quota: quota} ->
        claude =
          case quota[:claude] do
            %{five_hour: five} when is_number(five) -> ", Claude #{round(five * 100)}% of 5h"
            _ -> ""
          end

        "  ·  ↗ #{n} off-machine#{claude}"
    end
  end

  defp ctx_label(state), do: "ctx #{round(Context.fraction(context_tokens(state)) * 100)}%"

  defp split(area) do
    Layout.split(area, :vertical, [{:fill, 1}, {:length, 1}, {:length, @input_height}])
  end

  # When scrolled up, how far is shown first, so a long title can't cut it off.
  defp title(state, lines_below) do
    scroll =
      if state.scroll == :bottom,
        do: "",
        else: " ↓#{lines_below} lines below · end to follow ·"

    # Never on without it showing: first, so a long folder can't push it out of view.
    buying = if TinyAxe.Purchases.enabled?(), do: " 💳 purchases on ·", else: ""

    "#{buying}#{scroll} tiny-axe · 📍 #{TinyAxe.Ops.show(TinyAxe.Location.current())} · #{model()} · decider: #{decider_name()} "
  end

  defp status_widget(%{run: nil} = state) do
    %Paragraph{
      text:
        " #{state.status}  ·  #{ctx_label(state)}#{remote_label()}  ·  pgup/pgdn/↑/↓ scroll · ctrl+y copy · ctrl+z undo · ctrl+k compact · ctrl+t sidebar · ctrl+c quit",
      style: %Style{fg: :dark_gray}
    }
  end

  defp status_widget(state) do
    %Throbber{
      label: " #{state.status}  ·  #{ctx_label(state)}#{remote_label()}",
      step: state.tick,
      throbber_style: %Style{fg: :cyan}
    }
  end

  ## Scrolling

  # The first transcript line in view.
  defp view_top(state, size) do
    scroll_top(state.scroll, max_top(state, size))
  end

  defp scroll_top(:bottom, bottom), do: bottom
  defp scroll_top(top, bottom), do: min(top, bottom)

  defp max_top(state, {w, h}) do
    width = if sidebar?(state, w), do: w - @sidebar_width, else: w
    inner_h = max(h - 1 - @input_height - 2, 1)
    max(Transcript.height(state, max(width - 2, 1)) - inner_h, 0)
  end

  # Scrolling to the end resumes following new output.
  def scroll_to(state, top) do
    top = max(top, 0)

    if top >= max_top(state, state.size),
      do: %{state | scroll: :bottom},
      else: %{state | scroll: top}
  end

  def scroll_by(state, lines), do: scroll_to(state, view_top(state, state.size) + lines)

  @doc "The number of transcript rows to move for page up/down."
  def page(%{size: {_w, h}}), do: max(h - @input_height - 4, 1)

  defp model, do: Application.get_env(:tiny_axe, :model)

  defp decider_name do
    TinyAxe.Decider.impl() |> Module.split() |> List.last() |> String.downcase()
  end

  def scroll_plan(code, state) do
    case code do
      c when c in ["down", "j"] -> %{state | plan_scroll: state.plan_scroll + 1}
      c when c in ["up", "k"] -> %{state | plan_scroll: max(state.plan_scroll - 1, 0)}
      "page_down" -> %{state | plan_scroll: state.plan_scroll + page(state)}
      "page_up" -> %{state | plan_scroll: max(state.plan_scroll - page(state), 0)}
      _ -> state
    end
  end
end
