defmodule TinyAxe.TUI.TabBar do
  @moduledoc """
  Open conversations nested under the Chat destination. Layout and hit testing
  share cell coordinates, including when the terminal cannot show every chat.
  """

  alias ExRatatui.CellSession
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Widgets.Paragraph
  alias TinyAxe.TUI.{Chats, MainTabs}

  @max_tab_width 28
  @min_tab_width 18
  @measurements {__MODULE__, :measurements}

  def height, do: 2

  @doc "Clickable regions in the first row, in terminal cells. The active chat is always visible."
  def layout(_state, width) when width <= 0, do: []

  def layout(state, width) do
    tabs = Enum.map(state.chats.order, &tab(state, &1))
    new = item(:new, "+ new", false, :control, min(width, 7))

    if Enum.sum(Enum.map(tabs, & &1.width)) + new.width <= width do
      place(tabs ++ [new], 0)
    else
      overflow(tabs, new, width)
    end
  end

  @doc "The action at a screen coordinate; the hint row and unused cells do nothing."
  def hit(%{size: {width, height}} = state, x, y)
      when height > 1 and x >= 0 and x < width do
    if Map.get(state, :section, :chat) == :chat and y == MainTabs.height() do
      state
      |> layout(width)
      |> Enum.find_value(fn tab ->
        if x >= tab.x and x < tab.x + tab.width, do: tab.action
      end)
    end
  end

  def hit(_state, _x, _y), do: nil

  @doc "Widgets for the two-row strip at the top of the screen."
  def widgets(_state, %Rect{height: height}) when height <= 0, do: []

  def widgets(state, %Rect{} = area) do
    tabs =
      for tab <- layout(state, area.width) do
        {%Paragraph{text: tab.label, style: style(tab)},
         %Rect{x: area.x + tab.x, y: area.y, width: tab.width, height: 1}}
      end

    if area.height > 1 and area.width > 0 do
      count = Chats.count(state)
      position = Chats.position(state, state.chats.active)

      hint =
        " #{position}/#{count} · click a tab · alt+←/→ switch · alt+1…9 select · /new · /chat close"

      tabs ++
        [
          {%Paragraph{text: hint, style: %Style{fg: :dark_gray}},
           %Rect{x: area.x, y: area.y + 1, width: area.width, height: 1}}
        ]
    else
      tabs
    end
  end

  defp tab(state, id) do
    chat = Chats.get(state, id)

    activity =
      case Chats.activity(state, id) do
        "waiting for you" -> :waiting
        "working" -> :working
        _ -> if chat.status == "error", do: :error, else: :idle
      end

    marker =
      case activity do
        :waiting -> "? "
        :working -> "● "
        :error -> "! "
        :idle -> ""
      end

    title =
      state
      |> Chats.title(id, 48)
      |> String.replace(~r/[\p{Cc}\x{2028}\x{2029}]/u, " ")
      |> String.graphemes()
      |> Enum.map_join(fn grapheme -> if byte_size(grapheme) > 128, do: "�", else: grapheme end)

    label = "#{Chats.position(state, id)} #{marker}#{title}"
    item({:chat, id}, label, id == state.chats.active, activity, @max_tab_width)
  end

  defp item(action, text, active?, activity, max_width) do
    {label, width} = label(text, max_width)
    %{action: action, label: label, width: width, active?: active?, activity: activity}
  end

  defp label(text, max_width) when max_width >= 3 do
    label = " " <> clip(text, max_width - 2) <> " "
    {label, cells(label)}
  end

  defp label(text, max_width) do
    label = clip(text, max_width)
    {label, cells(label)}
  end

  defp overflow([tab], _new, width) when width > 1 do
    new_width = if width >= 12, do: 7, else: 1
    new = item(:new, if(new_width > 1, do: "+ new", else: "+"), false, :control, new_width)
    place([resize(tab, width - new_width)], 0) ++ place([new], width - new_width)
  end

  # Under four columns there is no room for both directions, an active chat,
  # and the new-chat button. Keep the chat first; keyboard switching still works.
  defp overflow(tabs, _new, width) when width < 4 do
    active = Enum.find(tabs, & &1.active?) |> resize(1)

    case width do
      1 ->
        place([active], 0)

      2 ->
        place([active, item(:new, "+", false, :control, 1)], 0)

      3 ->
        place(
          [active, item(:next, "›", false, :control, 1), item(:new, "+", false, :control, 1)],
          0
        )
    end
  end

  defp overflow(tabs, _new, width) do
    control_width = if width >= 16, do: 3, else: 1
    new_width = if width >= 24, do: 7, else: 1
    budget = width - control_width * 2 - new_width
    count = length(tabs)
    slots = min(count, max(div(budget, @min_tab_width), 1))
    active = Enum.find_index(tabs, & &1.active?)
    first = (active - div(slots - 1, 2)) |> max(0) |> min(count - slots)
    tab_width = div(budget, slots)

    visible = tabs |> Enum.slice(first, slots) |> Enum.map(&resize(&1, tab_width))
    previous = item(:previous, "‹", false, :control, control_width)
    next = item(:next, "›", false, :control, control_width)
    new = item(:new, if(new_width > 1, do: "+ new", else: "+"), false, :control, new_width)

    place([previous | visible], 0) ++
      place([next, new], width - control_width - new_width)
  end

  defp resize(tab, width) do
    {label, width} = label(String.trim(tab.label), width)
    %{tab | label: label, width: width}
  end

  defp place(tabs, start) do
    {tabs, _} =
      Enum.map_reduce(tabs, start, fn tab, x ->
        {Map.put(tab, :x, x), x + tab.width}
      end)

    tabs
  end

  defp style(%{active?: true}),
    do: %Style{fg: :black, bg: {:rgb, 126, 211, 115}, modifiers: [:bold]}

  defp style(%{activity: :waiting}), do: %Style{fg: :yellow, modifiers: [:bold]}
  defp style(%{activity: :working}), do: %Style{fg: :cyan}
  defp style(%{activity: :error}), do: %Style{fg: :red}
  defp style(%{activity: :control}), do: %Style{fg: :green, modifiers: [:bold]}
  defp style(_tab), do: %Style{fg: :gray}

  # Use the renderer's Unicode width rules (including wide emoji, joiners,
  # and combining marks). Cached, bounded titles need measuring only when
  # their content or available width changes, not on every animation frame.
  defp cells(text) do
    cached = Process.get(@measurements, %{})

    case cached do
      %{^text => width} ->
        width

      _ ->
        width = measure(text)
        cached = if map_size(cached) >= 512, do: %{}, else: cached
        Process.put(@measurements, Map.put(cached, text, width))
        width
    end
  end

  defp measure(text) do
    width = byte_size(text) + 1
    session = CellSession.new(width, 1)

    try do
      :ok =
        CellSession.draw(session, [
          {%Paragraph{text: text <> "|"}, %Rect{x: 0, y: 0, width: width, height: 1}}
        ])

      session
      |> CellSession.take_cells()
      |> Map.fetch!(:cells)
      |> Enum.reverse()
      |> Enum.find(&(&1.symbol == "|"))
      |> Map.fetch!(:col)
    after
      CellSession.close(session)
    end
  end

  defp clip(_text, width) when width <= 0, do: ""

  defp clip(text, width) do
    if cells(text) <= width do
      text
    else
      graphemes = String.graphemes(text)
      length = fit(graphemes, width - cells("…"), 0, length(graphemes))
      Enum.take(graphemes, length) |> Enum.join() |> Kernel.<>("…")
    end
  end

  defp fit(_graphemes, _width, low, high) when low >= high, do: low

  defp fit(graphemes, width, low, high) do
    middle = div(low + high + 1, 2)
    prefix = graphemes |> Enum.take(middle) |> Enum.join()

    if cells(prefix) <= width,
      do: fit(graphemes, width, middle, high),
      else: fit(graphemes, width, low, middle - 1)
  end
end
