defmodule TinyAxe.TUI.Welcome do
  @moduledoc """
  A small ASCII axe that turns in the unused part of a new chat.
  Its timer stops during conversations and other workflows, independently of the cursor.
  """

  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Text.{Line, Span}
  alias ExRatatui.Widgets.Paragraph
  alias TinyAxe.TUI.Transcript

  @green {:rgb, 126, 211, 115}
  @orange {:rgb, 245, 163, 78}
  @width 21
  @height 12
  @frame_ms 120
  @frame_count 16

  # Rasterize the blade and handle once, at compile time. Terminal cells are
  # about twice as tall as they are wide, so rotate in physical coordinates.
  @frames (for frame <- 0..(@frame_count - 1) do
             angle = frame * 2 * :math.pi() / @frame_count
             cos = :math.cos(angle)
             sin = :math.sin(angle)

             for y <- -4..4 do
               cells =
                 for col <- -10..10 do
                   x = col / 2
                   u = x * cos + y * sin
                   v = -x * sin + y * cos

                   cond do
                     u >= -0.5 and u <= 2.65 and
                       v >= -2.65 - max(u - 0.3, 0) * 0.4 and
                         v <= -1.5 + max(u - 0.3, 0) * 0.3 ->
                       {"x", @green}

                     abs(u) <= 0.48 and v >= -2.6 and v <= 3.2 ->
                       char =
                         cond do
                           abs(cos) > 0.85 -> "|"
                           abs(sin) > 0.85 -> "="
                           sin * cos > 0 -> "/"
                           true -> "\\"
                         end

                       {char, @orange}

                     true ->
                       {" ", nil}
                   end
                 end

               cells
               |> Enum.chunk_by(&elem(&1, 1))
               |> Enum.map(fn [{_, color} | _] = run ->
                 Span.new(Enum.map_join(run, &elem(&1, 0)),
                   style: %Style{fg: color, modifiers: [:bold]}
                 )
               end)
               |> Line.new()
             end
           end)
          |> List.to_tuple()

  def new(opts), do: %{frame: 0, timer: nil, animate?: opts[:test_mode] == nil}

  def account?(%{account_flow: %{step: :welcome}, size: {w, h}}), do: w >= 80 and h >= 24
  def account?(_state), do: false

  # Keep startup notices above the welcome, and give the conversation all
  # the space as soon as there is a real turn or a running request.
  def visible?(state) do
    state.history == [] and state.run == nil and state.streaming == nil and
      state.running_cmd == nil and state.account_flow == nil and state.card_flow == nil and
      state.recovery == nil and state.pending_plan == nil and state.pending_commands == nil and
      state.pending_edits == [] and state.confirm_undo == nil and state.asking == nil and
      state.tool_ask == nil and state.purchase_ask == nil and
      Enum.all?(state.transcript, &match?({:meta, _}, &1))
  end

  def sync(%{welcome: welcome} = state) do
    active? = visible?(state) or account?(state)

    cond do
      active? and welcome.animate? and welcome.timer == nil ->
        put_in(state.welcome.timer, :erlang.start_timer(@frame_ms, self(), :welcome))

      not active? and welcome.timer != nil ->
        Process.cancel_timer(welcome.timer)
        put_in(state.welcome.timer, nil)

      true ->
        state
    end
  end

  def step(%{welcome: welcome} = state) do
    %{state | welcome: %{welcome | frame: rem(welcome.frame + 1, @frame_count), timer: nil}}
  end

  def logo(state) do
    elem(@frames, state.welcome.frame) ++
      [
        Line.new([]),
        Line.new(
          [
            Span.new("tiny", style: %Style{fg: @green, modifiers: [:bold]}),
            Span.new("-axe", style: %Style{fg: @orange, modifiers: [:bold]})
          ],
          alignment: :center
        )
      ]
  end

  def widgets(state, %Rect{} = area) do
    if visible?(state) do
      notices = Transcript.height(state, max(area.width - 2, 1))
      available = area.height - 2 - if(notices > 0, do: notices + 1, else: 0)

      if area.width >= @width + 2 and available >= @height do
        rect = %Rect{
          x: area.x + div(area.width - @width, 2),
          y: area.y + area.height - 1 - available + div(available - @height, 2),
          width: @width,
          height: @height
        }

        lines =
          logo(state) ++
            [
              Line.new([Span.new("What shall we build?", style: %Style{fg: :dark_gray})],
                alignment: :center
              )
            ]

        [{%Paragraph{text: lines}, rect}]
      else
        []
      end
    else
      []
    end
  end
end
