defmodule TinyAxe.TUI.Panel do
  @moduledoc """
  The panel: one popup over the chat with a tab each for Remote, Token,
  Wallet and Search (`docs/plan-panels.md`). Each slash command opens it on
  its own tab (`/remote`, `/token`, `/wallet` or `/credit-card`,
  `/search`). `tab` / `shift+tab` and `←` / `→` switch tabs; `esc` closes
  it. While it's open, keys go to it, not the prompt. Questions (a tool call,
  a purchase) still come first, on top of it.

    * **Remote** — the site's remote chat (`TinyAxe.TUI.RemoteChat`): how it
      stands, and `enter` turns it on or off.
    * **Token** — token use (`TinyAxe.TUI.TokenDash`), refreshed every
      second while the panel is open.
    * **Wallet** — the cards (`TinyAxe.Cards`), masked: `a` adds one (the
      card flow), `f` then `y` forgets the one chosen.
    * **Search** — the kept chats (`search/1`): type, `enter` searches,
      `↑`/`↓` choose, `enter` opens the chosen chat.

  Nothing in it goes to a model.
  """

  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Text.{Line, Span}
  alias ExRatatui.Widgets.{Block, Clear, Paragraph, Tabs}
  alias TinyAxe.TUI.{ChatHistory, RemoteChat, TokenDash}
  import TinyAxe.TUI.Presentation, only: [styled: 1, styled: 2, styled: 3]

  @tabs [remote: "Remote", token: "Token", wallet: "Wallet", search: "Search"]
  @results 20

  @doc "The tabs, in order."
  def tabs, do: Keyword.keys(@tabs)

  @doc "Opens the panel on `tab` (or switches to it); `arg` is a search for the Search tab."
  def open(state, tab, arg \\ "") do
    panel =
      (state.panel ||
         %{tab: tab, token: nil, cards: [], card: 0, forgetting: nil} |> blank_search())
      |> Map.put(:tab, tab)
      |> enter(tab)

    panel = if tab == :search and arg != "", do: run_search(%{panel | query: arg}), else: panel
    %{state | panel: panel}
  end

  defp blank_search(panel), do: Map.merge(panel, %{query: "", searched: nil, results: [], hit: 0})

  # What a tab needs when it comes up: the token counts started, the cards read.
  defp enter(%{tab: :token, token: nil} = panel, :token), do: %{panel | token: TokenDash.open()}
  defp enter(panel, :wallet), do: refresh_cards(panel)
  defp enter(panel, _tab), do: panel

  @doc "Closes it."
  def close(state), do: %{state | panel: nil}

  @doc "The wallet read again (after a card is added)."
  def refresh(%{panel: nil} = state), do: state
  def refresh(state), do: %{state | panel: refresh_cards(state.panel)}

  defp refresh_cards(panel) do
    cards = cards()
    %{panel | cards: cards, card: min(panel.card, max(length(cards) - 1, 0))}
  end

  defp cards do
    TinyAxe.Cards.list()
  catch
    :exit, _ -> []
  end

  @doc "A token refresh, if it's this panel's."
  def token_tick(%{panel: %{token: dash} = panel} = state, ref) when dash != nil,
    do: %{state | panel: %{panel | token: TokenDash.refresh(dash, ref)}}

  def token_tick(state, _ref), do: state

  @doc """
  The chats that have every word of `query`, newest first. The local chat
  memory (`docs/plan-local-memory.md`) can answer here instead.
  """
  def search(query), do: TinyAxe.History.list(query: query, limit: @results)

  ## Keys

  @doc "A key while the panel is open: `{:noreply, state}`."
  def key(state, code, mods \\ [])

  def key(%{panel: %{forgetting: label}} = state, code, _mods) when label != nil do
    panel = state.panel

    case code do
      "y" ->
        said =
          case TinyAxe.Cards.forget(label) do
            :ok -> "💳 forgot #{label}: wiped from tiny-axe and your keyring"
            {:error, _} -> "couldn't forget #{label}"
          end

        state = %{state | panel: refresh_cards(%{panel | forgetting: nil})}
        {:noreply, TinyAxe.TUI.Conversation.add_meta(state, said)}

      c when c in ["n", "esc"] ->
        {:noreply, %{state | panel: %{panel | forgetting: nil}}}

      _ ->
        {:noreply, state, render?: false}
    end
  end

  def key(state, "esc", _mods), do: {:noreply, close(state)}
  def key(state, code, _mods) when code in ["tab", "right"], do: {:noreply, step(state, 1)}
  def key(state, code, _mods) when code in ["back_tab", "left"], do: {:noreply, step(state, -1)}
  def key(state, code, mods), do: tab_key(state, state.panel.tab, code, mods)

  defp step(state, by) do
    tabs = tabs()
    i = Enum.find_index(tabs, &(&1 == state.panel.tab))
    open(state, Enum.at(tabs, rem(i + by + length(tabs), length(tabs))))
  end

  defp tab_key(state, :remote, "enter", _mods) do
    on = state.remote_link.phase == :off
    {:noreply, RemoteChat.command(state, if(on, do: "on", else: "off"))}
  end

  defp tab_key(%{panel: panel} = state, :wallet, code, _mods) do
    case code do
      "up" ->
        {:noreply, %{state | panel: %{panel | card: max(panel.card - 1, 0)}}}

      "down" ->
        {:noreply,
         %{state | panel: %{panel | card: min(panel.card + 1, max(length(panel.cards) - 1, 0))}}}

      "a" ->
        {:noreply, %{state | card_flow: TinyAxe.TUI.CardFlow.new(), status: "adding a card…"}}

      "f" ->
        case Enum.at(panel.cards, panel.card) do
          nil -> {:noreply, state, render?: false}
          card -> {:noreply, %{state | panel: %{panel | forgetting: card.label}}}
        end

      _ ->
        {:noreply, state, render?: false}
    end
  end

  defp tab_key(%{panel: panel} = state, :search, code, mods) do
    cond do
      code == "enter" and panel.query != panel.searched ->
        {:noreply, %{state | panel: run_search(panel)}}

      code == "enter" ->
        case Enum.at(panel.results, panel.hit) do
          nil -> {:noreply, state, render?: false}
          chat -> {:noreply, state |> close() |> ChatHistory.open(chat.id)}
        end

      code == "up" ->
        {:noreply, %{state | panel: %{panel | hit: max(panel.hit - 1, 0)}}}

      code == "down" ->
        {:noreply,
         %{state | panel: %{panel | hit: min(panel.hit + 1, max(length(panel.results) - 1, 0))}}}

      code == "backspace" ->
        {:noreply, %{state | panel: %{panel | query: String.slice(panel.query, 0..-2//1)}}}

      String.length(code) == 1 and mods in [[], ["shift"]] ->
        {:noreply, %{state | panel: %{panel | query: panel.query <> code}}}

      true ->
        {:noreply, state, render?: false}
    end
  end

  defp tab_key(state, _tab, _code, _mods), do: {:noreply, state, render?: false}

  @doc "Pasted text: into the search."
  def paste(%{panel: %{tab: :search} = panel} = state, text),
    do: %{state | panel: %{panel | query: panel.query <> String.replace(text, ~r/\s+/, " ")}}

  def paste(state, _text), do: state

  defp run_search(panel) do
    query = String.trim(panel.query)
    results = if query == "", do: [], else: search(query)
    %{panel | query: query, searched: query, results: results, hit: 0}
  end

  ## Drawing

  @doc "The panel's widgets, over the chat; none while it's closed."
  def render(%{panel: nil}, _area), do: []

  # As tall as what it shows (at least a comfortable size), within the screen.
  def render(%{panel: panel} = state, area) do
    body = body(state, panel)
    # Within the chat's frame, so the status bar and the prompt stay in view.
    room = area.height - TinyAxe.TUI.View.input_height() - 1
    width = max(min(area.width - 4, 96), 1)
    height = max(min(room - 2, max(20, length(body) + 6)), 1)

    box = %Rect{
      x: area.x + div(area.width - width, 2),
      y: area.y + max(div(room - height, 2), 1),
      width: width,
      height: height
    }

    inner = %Rect{
      x: box.x + 2,
      y: box.y + 1,
      width: max(width - 4, 1),
      height: max(height - 2, 1)
    }

    tabs_at = %{inner | height: 1}
    footer_at = %{inner | y: inner.y + inner.height - 1, height: 1}
    body_at = %{inner | y: inner.y + 2, height: max(inner.height - 4, 1)}

    frame = %Paragraph{
      text: "",
      block: %Block{
        title: " tiny-axe ",
        borders: [:all],
        border_type: :rounded,
        border_style: %Style{fg: :cyan}
      }
    }

    tabs = %Tabs{
      titles: Keyword.values(@tabs),
      selected: Enum.find_index(tabs(), &(&1 == panel.tab)),
      style: %Style{fg: :dark_gray},
      highlight_style: %Style{fg: :cyan, modifiers: [:bold, :reversed]},
      divider: "│"
    }

    footer = %Paragraph{text: [styled(footer(panel) <> " · tab next · esc close", :dark_gray)]}

    [
      {%Clear{}, box},
      {frame, box},
      {tabs, tabs_at},
      {%Paragraph{text: body, wrap: panel.tab != :token}, body_at},
      {footer, footer_at}
    ]
  end

  defp footer(%{tab: :remote}), do: "enter turn on or off"
  defp footer(%{tab: :token}), do: "updates as calls finish"
  defp footer(%{tab: :wallet, forgetting: nil}), do: "↑↓ choose · a add a card · f forget"
  defp footer(%{tab: :wallet}), do: "y forget · n keep"
  defp footer(%{tab: :search}), do: "type to search · enter search or open · ↑↓ choose"

  defp body(state, %{tab: :remote}) do
    link = state.remote_link
    on? = link.phase != :off

    [
      Line.new([
        Span.new("🌐 Remote chat: ", style: %Style{modifiers: [:bold]}),
        Span.new(RemoteChat.describe(link), style: %Style{fg: if(on?, do: :green, else: :yellow)})
      ]),
      styled(""),
      styled(
        "Messages typed at #{site()}/remote come to a 🌐 chat here and are answered as if " <>
          "you'd asked them. Anything that needs your yes is refused for now, since nobody's " <>
          "asked at the machine."
      ),
      styled(""),
      styled(
        if(on?,
          do: "It stays on when tiny-axe starts again, until you turn it off.",
          else: "Off: the site can't reach this tiny-axe."
        ),
        :dark_gray
      )
    ]
  end

  defp body(_state, %{tab: :token, token: dash}), do: TokenDash.lines(dash)

  defp body(_state, %{tab: :wallet, cards: []}) do
    [
      styled("No cards yet."),
      styled(""),
      styled(
        "Press a to add one. Its number is typed straight into tiny-axe's card vault; " <>
          "no model ever sees it.",
        :dark_gray
      )
    ]
  end

  defp body(_state, %{tab: :wallet} = panel) do
    rows =
      panel.cards
      |> Enum.with_index()
      |> Enum.map(fn {card, i} ->
        chosen = i == panel.card
        mark = if chosen, do: "▸ ", else: "  "
        styled(mark <> card_line(card), if(chosen, do: :cyan), if(chosen, do: [:bold], else: []))
      end)

    forgetting =
      if panel.forgetting,
        do: [
          styled(""),
          styled(
            "Forget #{panel.forgetting}? It's wiped from tiny-axe and your keyring.",
            :red,
            [:bold]
          )
        ],
        else: []

    rows ++ forgetting
  end

  defp body(state, %{tab: :search} = panel) do
    input =
      Line.new([
        Span.new("Search: ", style: %Style{modifiers: [:bold]}),
        Span.new(panel.query),
        Span.new("▏", style: %Style{fg: :cyan})
      ])

    results =
      cond do
        panel.searched == nil or panel.query != panel.searched ->
          [styled("Type words and press enter: chats that have all of them.", :dark_gray)]

        panel.results == [] ->
          [styled("No kept chat has “#{panel.searched}”.", :yellow)]

        true ->
          count = length(panel.results)

          [styled("#{count} chat#{if count == 1, do: "", else: "s"}, newest first", :dark_gray)] ++
            (panel.results
             |> Enum.with_index()
             |> Enum.map(fn {chat, i} ->
               chosen = i == panel.hit
               mark = if chosen, do: "▸ ", else: "  "
               open = if TinyAxe.TUI.Chats.kept_as(state, chat.id), do: " ◂ open", else: ""

               styled(
                 mark <> ChatHistory.describe(chat) <> open,
                 if(chosen, do: :cyan),
                 if(chosen, do: [:bold], else: [])
               )
             end))
      end

    [input, styled("") | results]
  end

  @doc "One card, masked: its name, brand, last 4, and how long it's kept."
  def card_line(c) do
    until =
      cond do
        c[:remember] == "session" or c[:keyring] == nil -> "this session only"
        c[:expires_at] -> "until #{String.slice(c.expires_at, 0, 10)}"
        true -> "until you remove it"
      end

    "💳 #{c.label} (#{c[:brand]} ••#{c[:last4]}) · #{until}" <>
      if(c[:purpose], do: " · for #{c.purpose}", else: "") <>
      if(c[:pin], do: " · PIN", else: "")
  end

  defp site do
    TinyAxe.Account.site_url()
  catch
    _, _ -> "the site"
  end
end
