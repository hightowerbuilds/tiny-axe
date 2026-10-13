defmodule TinyAxe.TUI.SearchWorkspace do
  @moduledoc "On-machine archive search and Gemma answers, with their own local conversation."

  alias ExRatatui.{Event, Layout, Style}
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Widgets.Paragraph
  alias TinyAxe.TUI.{ChatHistory, Chats, MainTabs, MemoryChat, View, Workspace}

  @modes [{:words, "Words/phrase F6"}, {:literal, "Literal F7"}, {:ask, "Ask Gemma F8"}]
  @commands [
    {:status, "Status F9", "/memory status"},
    {:review, "Review on F10", "/memory review on"},
    {:pause, "Pause F11", "/memory review off"},
    {:next, "Next F12", "/memory next"}
  ]

  def height, do: 3

  def title(_state), do: " Gemma Search · local only "
  def placeholder(%{search_mode: :ask}), do: "Ask Gemma about your saved chats…"

  def placeholder(%{search_mode: :literal}),
    do: "Find exact characters, including case and punctuation…"

  def placeholder(_state), do: "Search words or a consecutive phrase in \"quotes\"…"

  def widgets(state, body) do
    [toolbar, conversation] = Layout.split(body, :vertical, [{:length, height()}, {:fill, 1}])

    buttons =
      for item <- layout(state, toolbar.width), item.y < toolbar.height do
        selected = item.action == {:mode, state.search_mode}

        style =
          if selected,
            do: %Style{fg: :black, bg: :green, modifiers: [:bold]},
            else: %Style{fg: :cyan}

        {%Paragraph{text: item.label, style: style},
         %Rect{x: toolbar.x + item.x, y: toolbar.y + item.y, width: item.width, height: 1}}
      end

    hint =
      if toolbar.height >= 3 do
        [
          {%Paragraph{
             text: " Local archive · /memory open N · /memory review retry · /memory rebuild",
             style: %Style{fg: :dark_gray}
           }, %Rect{x: toolbar.x, y: toolbar.y + 2, width: toolbar.width, height: 1}}
        ]
      else
        []
      end

    buttons ++ hint ++ View.conversation_widgets(state, conversation)
  end

  @doc "Toolbar regions relative to the body under the main navigation."
  def layout(_state, width) when width <= 0, do: []

  def layout(_state, width) do
    modes = Enum.map(@modes, fn {mode, label} -> {{:mode, mode}, label} end)
    commands = Enum.map(@commands, fn {id, label, _command} -> {{:command, id}, label} end)
    row(modes, width, 0) ++ row(commands, width, 1)
  end

  defp row(items, width, y) do
    count = min(length(items), width)
    budget = max(div(width, count), 1)

    {items, _} =
      items
      |> Enum.take(count)
      |> Enum.map_reduce(0, fn {action, text}, x ->
        label = " " <> text <> " "

        label =
          if String.length(label) > budget,
            do: String.slice(label, 0, max(budget - 1, 0)) <> "…",
            else: label

        size = String.length(label)
        {%{action: action, label: label, x: x, y: y, width: size}, x + size}
      end)

    items
  end

  def hit(%{size: {width, height}} = state, x, y) when x >= 0 and y < height do
    row = y - MainTabs.height()

    Enum.find_value(layout(state, width), fn item ->
      if item.y == row and x >= item.x and x < item.x + item.width, do: item.action
    end)
  end

  def hit(_state, _x, _y), do: nil

  # nil leaves ordinary textarea editing and transcript scrolling to TUI.
  def event(%Event.Key{kind: "release"}, _state), do: nil
  def event(%Event.Key{code: "enter", modifiers: []}, state), do: submit(state)

  def event(%Event.Key{code: code, modifiers: []}, state) do
    action =
      case code do
        "f6" -> {:mode, :words}
        "f7" -> {:mode, :literal}
        "f8" -> {:mode, :ask}
        "f9" -> {:command, :status}
        "f10" -> {:command, :review}
        "f11" -> {:command, :pause}
        "f12" -> {:command, :next}
        _ -> nil
      end

    if action, do: {:noreply, act(state, action)}
  end

  def event(%Event.Mouse{kind: "down", button: "left", x: x, y: y}, state) do
    if action = hit(state, x, y), do: {:noreply, act(state, action)}
  end

  def event(_event, _state), do: nil

  defp act(state, {:mode, mode}), do: %{state | search_mode: mode}
  defp act(%{run: run} = state, {:command, _}) when run != nil, do: state

  defp act(state, {:command, id}) do
    {_id, _label, command} = Enum.find(@commands, &(elem(&1, 0) == id))
    MemoryChat.command(state, command)
  end

  defp submit(state) do
    prompt = state.input |> ExRatatui.textarea_get_value() |> String.trim()

    cond do
      prompt == "" ->
        {:noreply, state}

      prompt in ["/new", "/chats"] or prompt =~ ~r/\A\/chat(?:\s|\z)/u ->
        {:noreply, opened} = Chats.submit(state)
        {:noreply, Workspace.open_chat(opened, opened.chats.active)}

      state.run != nil ->
        {:noreply, state}

      prompt =~ ~r/\A\/history(?:\s|\z)/u ->
        {:noreply, opened} = ChatHistory.submit(state)
        {:noreply, Workspace.open_chat(opened, opened.chats.active)}

      prompt =~ ~r/\A\/memory(?:\s|\z)/u ->
        MemoryChat.submit(state)

      true ->
        ExRatatui.textarea_set_value(state.input, "")

        state =
          case state.search_mode do
            :ask -> MemoryChat.ask(state, prompt)
            :literal -> MemoryChat.command(state, "/memory search --literal \"" <> prompt <> "\"")
            :words -> MemoryChat.command(state, "/memory search " <> prompt)
          end

        {:noreply, state}
    end
  end
end
