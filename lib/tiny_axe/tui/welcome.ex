defmodule TinyAxe.TUI.Welcome do
  @moduledoc """
  A double-bit axe, modelled in 3D and turning in the unused part of a new
  chat. Each frame is ray-cast at compile time: for every cell a ray goes in
  along the view axis until it meets the axe (a signed-distance field for the
  handle and the head), the surface's normal is taken there, and the cell
  gets a character and a colour from how much light it catches. So the
  handle is round, the head is thin at the edges and thick at the eye, and
  the near side is bright while the far side falls into shadow.

  Its timer stops during conversations and other workflows, independently of
  the cursor.
  """

  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Text.{Line, Span}
  alias ExRatatui.Widgets.Paragraph
  alias TinyAxe.TUI.Transcript
  alias TinyAxe.TUI.Welcome.Render

  @green {126, 211, 115}
  @orange {245, 163, 78}

  @width Render.cols()
  @height Render.rows() + 2
  @frame_ms 70
  @frame_count Render.frame_count()

  @doc "How big the picture is, in cells, with the name under it."
  def width, do: @width
  def height, do: @height

  @frames 0..(@frame_count - 1) |> Enum.map(&Render.frame/1) |> List.to_tuple()

  def new(opts), do: %{frame: 0, timer: nil, animate?: opts[:test_mode] == nil}

  def account?(%{section: section}) when section != :chat, do: false
  def account?(%{account_flow: %{step: :welcome}, size: {w, h}}), do: w >= 100 and h >= 26
  def account?(_state), do: false

  # Keep startup notices above the welcome, and give the conversation all
  # the space as soon as there is a real turn or a running request.
  def visible?(state) do
    Map.get(state, :section, :chat) == :chat and
      state.history == [] and state.run == nil and state.streaming == nil and
      state.running_cmd == nil and state.account_flow == nil and state.card_flow == nil and
      state.pin_flow == nil and
      state.recovery == nil and state.pending_plan == nil and state.pending_commands == nil and
      state.pending_edits == [] and state.confirm_undo == nil and state.asking == nil and
      state.tool_ask == nil and state.purchase_ask == nil and
      Map.get(state, :token_dash) == nil and
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
    {r, g, b} = @green
    {r2, g2, b2} = @orange

    elem(@frames, state.welcome.frame) ++
      [
        Line.new([]),
        Line.new(
          [
            Span.new("tiny", style: %Style{fg: {:rgb, r, g, b}, modifiers: [:bold]}),
            Span.new("-axe", style: %Style{fg: {:rgb, r2, g2, b2}, modifiers: [:bold]})
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

        [{%Paragraph{text: logo(state)}, rect}]
      else
        []
      end
    else
      []
    end
  end
end
