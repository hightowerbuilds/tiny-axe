defmodule TinyAxe.TUI.MainTabs do
  @moduledoc "The application's primary destinations, above the conversation tabs."

  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Widgets.Paragraph

  @sections [
    {:chat, "Chat", "Chat"},
    {:wallet, "Wallet", "Wallet"},
    {:search, "Gemma Search", "Search"},
    {:tokens, "Tokens", "Tokens"},
    {:remote, "Remote", "Remote"},
    {:explained, "Explained", "Help"}
  ]

  def height, do: 1

  @doc "Primary tab click regions, with the current section retained at any positive width."
  def layout(_state, width) when width <= 0, do: []

  def layout(state, width) do
    active = Map.get(state, :section, :chat)

    full =
      @sections
      |> Enum.with_index(1)
      |> Enum.map(fn {{section, name, _short}, index} ->
        # F1–F5 for the first five; Explained is clicked or /help.
        item(section, if(index <= 5, do: " F#{index} #{name} ", else: " #{name} "), active)
      end)

    compact =
      Enum.map(@sections, fn {section, _name, short} -> item(section, " #{short} ", active) end)

    tabs =
      cond do
        total(full) <= width -> full
        total(compact) <= width -> compact
        true -> narrow(active, width)
      end

    {tabs, _} =
      Enum.map_reduce(tabs, 0, fn tab, x -> {Map.put(tab, :x, x), x + tab.width} end)

    tabs
  end

  @doc "Only the primary row is clickable; omitted tabs remain available through F1–F5 and /help."
  def hit(%{size: {width, height}} = state, x, 0)
      when height > 0 and x >= 0 and x < width do
    state
    |> layout(width)
    |> Enum.find_value(fn tab ->
      if x >= tab.x and x < tab.x + tab.width, do: tab.action
    end)
  end

  def hit(_state, _x, _y), do: nil

  def widgets(_state, %Rect{height: height}) when height <= 0, do: []

  def widgets(state, %Rect{} = area) do
    for tab <- layout(state, area.width) do
      style =
        if tab.active?,
          do: %Style{fg: :black, bg: {:rgb, 245, 163, 78}, modifiers: [:bold]},
          else: %Style{fg: :gray, modifiers: [:bold]}

      {%Paragraph{text: tab.label, style: style},
       %Rect{x: area.x + tab.x, y: area.y, width: tab.width, height: 1}}
    end
  end

  defp item(section, label, active) do
    %{
      action: {:section, section},
      label: label,
      width: String.length(label),
      active?: section == active
    }
  end

  defp total(tabs), do: Enum.sum(Enum.map(tabs, & &1.width))

  defp narrow(active, width) do
    slots = min(width, length(@sections))
    index = Enum.find_index(@sections, fn {section, _, _} -> section == active end) || 0
    first = (index - div(slots - 1, 2)) |> max(0) |> min(length(@sections) - slots)
    tab_width = div(width, slots)

    @sections
    |> Enum.slice(first, slots)
    |> Enum.map(fn {section, _name, short} ->
      label =
        if tab_width >= 4,
          do: " " <> clip(short, tab_width - 2) <> " ",
          else: clip(short, tab_width)

      item(section, label, active)
    end)
  end

  # Destination names are fixed ASCII; only the one-cell ellipsis is added.
  defp clip(label, width) do
    cond do
      String.length(label) <= width -> label
      width <= 2 -> String.slice(label, 0, width)
      true -> String.slice(label, 0, width - 1) <> "…"
    end
  end
end
