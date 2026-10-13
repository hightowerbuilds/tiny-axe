defmodule TinyAxe.TUI.FeaturePanels do
  @moduledoc "The Wallet, Tokens, Remote and Explained workspaces. Their notices never enter a chat."

  alias ExRatatui.{Event, Style}
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Widgets.{Block, Paragraph}
  alias TinyAxe.{Account, Cards, Purchases, Remote}
  alias TinyAxe.TUI.{CardFlow, Chats, MainTabs, RemoteChat, TokenDash}

  @card_fields ~w(label brand last4 purpose merchants per_purchase_max monthly_max cvc pin remember expires_at)a

  def new do
    %{
      wallet: %{cards: [], settings: [], notice: nil, scroll: 0, horizontal: 0},
      tokens: %{dashboard: nil, notice: nil, scroll: 0, horizontal: 0},
      remote: %{account: nil, notice: nil, scroll: 0, horizontal: 0},
      explained: %{notice: nil, scroll: 0, horizontal: 0}
    }
  end

  @doc "Reads the selected panel's data; opening a panel never enables a service."
  def enter(state, :wallet) do
    settings =
      Purchases.settings()
      |> Keyword.take([:enabled, :per_order_max, :daily_max, :currency, :merchants])

    cards = Cards.list() |> Enum.map(&Map.take(&1, @card_fields))
    put_panel(state, :wallet, cards: cards, settings: settings)
  catch
    :exit, _ -> notice(state, :wallet, "The card vault is unavailable. Press r to refresh.")
  end

  def enter(state, :tokens), do: put_panel(state, :tokens, dashboard: TokenDash.open())

  def enter(state, :remote) do
    state
    |> refresh_remote()
    |> put_panel(:remote, account: account_metadata())
  end

  def enter(state, _section), do: state

  def leave(state, :tokens), do: put_panel(state, :tokens, dashboard: nil)
  def leave(state, _section), do: state

  def refresh_tokens(%{section: :tokens, panels: %{tokens: %{dashboard: dash}}} = state, ref)
      when dash != nil,
      do: put_panel(state, :tokens, dashboard: TokenDash.refresh(dash, ref))

  def refresh_tokens(state, _ref), do: state

  def notice(state, section, text), do: put_panel(state, section, notice: text)

  @doc "Toolbar actions and their exact cell regions, relative to the body."
  def toolbar(state, width) do
    actions =
      case state.section do
        :wallet ->
          [{:add_card, "a Add card"}, {:refresh, "r Refresh"}]

        :tokens ->
          [{:refresh, "r Refresh"}]

        :remote ->
          [
            {:enable, "o Enable"},
            {:disable, "d Disable"},
            {:open_chat, "c Open chat"},
            {:refresh, "r Refresh"}
          ]

        :explained ->
          []
      end

    {items, _} =
      Enum.map_reduce(actions, 0, fn {action, label}, x ->
        label = "[" <> label <> "] "
        item_width = min(String.length(label), max(width - x, 0))
        {%{action: action, label: label, x: x, width: item_width}, x + item_width}
      end)

    Enum.reject(items, &(&1.width == 0))
  end

  def widgets(_state, %Rect{width: width, height: height}) when width < 1 or height < 1, do: []

  def widgets(state, %Rect{} = area) do
    toolbar =
      for item <- toolbar(state, area.width) do
        {%Paragraph{text: item.label, style: %Style{fg: :cyan, modifiers: [:bold]}},
         %Rect{x: area.x + item.x, y: area.y, width: item.width, height: 1}}
      end

    panel = state.panels[state.section]

    content = %Paragraph{
      text: lines(state),
      scroll: {panel.scroll, panel.horizontal},
      block: %Block{
        title: " #{title(state.section)} · ↑/↓ scroll · ←/→ pan ",
        borders: [:all],
        border_type: :rounded,
        border_style: %Style{fg: :dark_gray}
      }
    }

    body = %Rect{area | y: area.y + 1, height: max(area.height - 1, 0)}
    toolbar ++ if(body.height > 0, do: [{content, body}], else: [])
  end

  def event(%Event.Key{kind: "release"}, state), do: {:noreply, state}

  def event(%Event.Mouse{kind: "down", button: "left", x: x, y: y}, state) do
    {width, _} = state.size

    action =
      if y == MainTabs.height() do
        state
        |> toolbar(width)
        |> Enum.find_value(fn item ->
          if x >= item.x and x < item.x + item.width, do: item.action
        end)
      end

    act(state, action)
  end

  def event(%Event.Mouse{kind: "scroll_up"}, state), do: {:noreply, scroll(state, -3)}
  def event(%Event.Mouse{kind: "scroll_down"}, state), do: {:noreply, scroll(state, 3)}

  def event(%Event.Key{code: code, modifiers: []}, state) do
    case {state.section, code} do
      {_, "r"} -> act(state, :refresh)
      {:wallet, "a"} -> act(state, :add_card)
      {:remote, "o"} -> act(state, :enable)
      {:remote, "d"} -> act(state, :disable)
      {:remote, "c"} -> act(state, :open_chat)
      {_, "up"} -> {:noreply, scroll(state, -1)}
      {_, "down"} -> {:noreply, scroll(state, 1)}
      {_, "page_up"} -> {:noreply, scroll(state, -page(state))}
      {_, "page_down"} -> {:noreply, scroll(state, page(state))}
      {_, "home"} -> {:noreply, put_panel(state, state.section, scroll: 0, horizontal: 0)}
      {_, "end"} -> {:noreply, put_panel(state, state.section, scroll: bottom(state))}
      {_, "left"} -> {:noreply, pan(state, -8)}
      {_, "right"} -> {:noreply, pan(state, 8)}
      _ -> {:noreply, state}
    end
  end

  # Typed/pasted panel input cannot reach a hidden Chat prompt.
  def event(_event, state), do: {:noreply, state}

  defp act(state, nil), do: {:noreply, state}

  defp act(state, :refresh),
    do: {:noreply, state |> notice(state.section, nil) |> enter(state.section)}

  defp act(%{section: :wallet} = state, :add_card) do
    {:noreply, %{state | card_flow: CardFlow.new()} |> notice(:wallet, nil)}
  end

  defp act(%{section: :remote} = state, action) when action in [:enable, :disable] do
    case RemoteChat.set_enabled(state, action == :enable) do
      {:ok, state} ->
        message =
          if action == :enable,
            do: "Remote enabled. Waiting for the connection status.",
            else: "Remote disabled. Any running chat continues until you cancel it in Chat."

        {:noreply, notice(state, :remote, message)}

      {:error, message, state} ->
        {:noreply, notice(state, :remote, message)}
    end
  end

  defp act(%{section: :remote} = state, :open_chat) do
    case Enum.find(state.chats.order, &Chats.get(state, &1).remote_chat) do
      nil ->
        {:noreply,
         notice(state, :remote, "A Remote conversation appears after the first message arrives.")}

      id ->
        {:open_chat, id, state}
    end
  end

  defp put_panel(state, section, changes),
    do: put_in(state.panels[section], Map.merge(state.panels[section], Map.new(changes)))

  defp lines(state) do
    notice = state.panels[state.section].notice

    if notice,
      do: [styled(notice, :yellow), styled("")] ++ body_lines(state),
      else: body_lines(state)
  end

  defp body_lines(%{section: :wallet, panels: %{wallet: panel}}) do
    settings = panel.settings
    currency = settings[:currency] || "USD"

    [
      styled("Cards and purchase limits", :cyan, [:bold]),
      styled("Purchases: #{if settings[:enabled] == true, do: "enabled", else: "disabled"}"),
      styled(
        "Per order: #{money(settings[:per_order_max] || 100, currency)} · Per day: #{money(settings[:daily_max] || 200, currency)}"
      ),
      styled("Allowed shops: #{shops(settings[:merchants])}"),
      styled("Adding a card does not enable purchases or place an order.", :dark_gray),
      styled("")
    ] ++
      if panel.cards == [] do
        [
          styled("No saved cards yet."),
          styled("Choose Add card to enter one securely.", :dark_gray)
        ]
      else
        Enum.flat_map(panel.cards, fn card ->
          [
            styled(
              "#{card[:label] || "Card"} · #{card[:brand] || "Card"} •••• #{safe_last4(card[:last4])}",
              :cyan,
              [:bold]
            ),
            styled("  Purpose: #{card[:purpose] || "not specified"}"),
            styled("  Shops: #{shops(card[:merchants])}"),
            styled(
              "  Per purchase: #{limit(card[:per_purchase_max], currency)} · Per month: #{limit(card[:monthly_max], currency)}"
            ),
            styled(
              "  Remember: #{remember(card)} · PIN: #{if card[:pin], do: "required", else: "none"} · CVC: #{if card[:cvc] == "ask", do: "ask each time", else: "stored"}"
            ),
            styled("")
          ]
        end)
      end
  end

  # Wrapped to fit inside the panel's border.
  defp body_lines(%{section: :explained, size: {width, _}}),
    do: TinyAxe.TUI.Explained.lines(width - 4)

  defp body_lines(%{section: :tokens, panels: %{tokens: %{dashboard: dash}}}),
    do: TokenDash.lines(dash || %{summary: nil}, page: true)

  defp body_lines(%{section: :remote} = state) do
    link = state.remote_link
    account = state.panels.remote.account

    current =
      if link.current, do: "answering message #{link.current.id}", else: "no message running"

    [
      styled("Remote access", :cyan, [:bold]),
      styled("Connection: #{phase(link.phase)}"),
      styled(
        "Account: #{if account, do: account.username <> " (configured)", else: "not configured"}"
      ),
      styled("Web chat: #{Account.site_url()}/remote"),
      styled("Queue: #{length(link.queue)} waiting · #{current}"),
      styled("")
    ] ++
      if(link.error,
        do: [styled("Connection issue: #{link.error}", :yellow), styled("")],
        else: []
      ) ++
      [
        styled("Enable connects this machine to the site's remote chat."),
        styled("Messages and replies travel through the hosted service."),
        styled("Opening this tab does not enable or connect Remote.", :dark_gray),
        styled("Remote requests use their own conversation in Chat.", :dark_gray),
        styled(
          "Approvals from the Chat tab: #{TinyAxe.Remote.Approvals.describe(TinyAxe.Remote.Approvals.status())}",
          :dark_gray
        )
      ]
  end

  defp refresh_remote(%{remote_link: %{to: to}} = state) when is_pid(to), do: state

  defp refresh_remote(state) do
    status = Remote.status(state.remote_link.to)
    %{state | remote_link: Map.merge(state.remote_link, Map.take(status, [:phase, :error]))}
  catch
    :exit, _ -> notice(state, :remote, "The Remote service is unavailable. Press r to refresh.")
  end

  # Account display needs only configuration metadata, never a keyring read.
  defp account_metadata do
    with {:ok, raw} <- File.read(Account.path()),
         {:ok, %{"username" => name}} when is_binary(name) <- JSON.decode(raw) do
      %{username: name}
    else
      _ -> nil
    end
  end

  defp scroll(state, delta) do
    offset = state.panels[state.section].scroll

    put_panel(state, state.section,
      scroll: offset |> Kernel.+(delta) |> max(0) |> min(bottom(state))
    )
  end

  defp pan(state, delta) do
    {width, _} = state.size

    max_width =
      lines(state)
      |> Enum.map(fn line -> Enum.map_join(line.spans, & &1.content) |> String.length() end)
      |> Enum.max(fn -> 0 end)

    offset = state.panels[state.section].horizontal

    put_panel(state, state.section,
      horizontal: min(max(offset + delta, 0), max(max_width - width + 2, 0))
    )
  end

  defp page(%{size: {_, height}}), do: max(height - MainTabs.height() - 3, 1)
  defp bottom(state), do: max(length(lines(state)) - page(state), 0)
  defp title(:wallet), do: "Wallet"
  defp title(:tokens), do: "Tokens"
  defp title(:remote), do: "Remote"
  defp title(:explained), do: "Explained"
  defp phase(:off), do: "off"
  defp phase(:online), do: "online"
  defp phase(:waiting), do: "waiting to reconnect"
  defp phase(_), do: "connecting"
  defp safe_last4(last4) when is_binary(last4), do: String.slice(last4, -4, 4)
  defp safe_last4(_), do: "????"

  defp money(value, currency) when is_number(value),
    do: :erlang.float_to_binary(value * 1.0, decimals: 2) <> " " <> currency

  defp money(_, currency), do: "not set (#{currency})"
  defp limit(nil, _currency), do: "no extra card limit"
  defp limit(value, currency), do: money(value, currency)
  defp shops(value) when value in [nil, :any, "any"], do: "any shop"
  defp shops(value) when is_list(value), do: Enum.join(value, ", ")
  defp shops(value), do: to_string(value)
  defp remember(%{remember: "session"}), do: "this session"

  defp remember(%{expires_at: until}) when is_binary(until),
    do: "until #{String.slice(until, 0, 10)}"

  defp remember(_), do: "until removed"

  # User-provided labels and server errors are single display lines, even if
  # edited configuration or an error response contains terminal controls.
  defp styled(text, color \\ nil, modifiers \\ []) do
    clean = String.replace(text, ~r/[\x00-\x1F\x7F]/u, " ")
    TinyAxe.TUI.Presentation.styled(clean, color, modifiers)
  end
end
