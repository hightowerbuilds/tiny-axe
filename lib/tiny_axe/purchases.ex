defmodule TinyAxe.Purchases do
  @moduledoc """
  The one way an agent can spend money. Off unless `config :tiny_axe,
  :purchases, enabled: true`.

    1. **Intent** — before the agent starts, tiny-axe records what the user
       asked to buy, from their own words: the request and a maximum price
       ("under $50", "no more than £30"). Nothing on a page can change it. No
       maximum, no purchase: the agent is told to ask the user for one.
    2. **The summary** — when the gate stops a commit (a "Place order" click),
       code reads the checkout page (`browser_checkout_summary`): the shop
       from the address, the items, the total, where it ships, the card as
       shown.
    3. **Checks**, in code — the total is within the user's maximum, the
       per-order cap and what's left of the daily cap; the currency is the
       expected one; the shop is allowed; and Jev agrees the items are what
       was asked for (no answer is a failed check). A failed check can't be
       approved.
    4. **The user** types the exact total to buy (`{:purchase_approval, ...}`,
       answered with `{:purchase_answer, ref, :confirm | :deny}`).
    5. **Recheck, then click** — code reads the page again; the shop, the total
       and the button must be the same, or it goes back to the user. Then code
       clicks the button the summary was made for.
    6. **Receipt** — the confirmation page's text, order number and a
       screenshot go to `<state>/purchases/<id>/`.

  Each purchase has a write-ahead journal there (`intent`, `summary`,
  `confirmed`, `clicking`, `clicked`, `receipt`), synced to disk as written. A
  purchase that reached `clicking` without a `receipt` may have gone through:
  the next start says so, and tiny-axe never clicks it again.
  """

  require Logger

  alias TinyAxe.{Decider, MCP}

  @symbols %{"$" => "USD", "£" => "GBP", "€" => "EUR"}
  @words %{
    "usd" => "USD",
    "dollar" => "USD",
    "dollars" => "USD",
    "eur" => "EUR",
    "euro" => "EUR",
    "euros" => "EUR",
    "gbp" => "GBP",
    "pound" => "GBP",
    "pounds" => "GBP"
  }

  @doc """
  The purchase settings: `config :tiny_axe, :purchases`, overridden by
  `~/.config/tiny-axe/purchases.json` (`mix tiny_axe.purchases`), so they can be
  changed without touching code, in an installed copy too.
  """
  @spec settings() :: keyword()
  def settings, do: Keyword.merge(Application.get_env(:tiny_axe, :purchases, []), file_settings())

  @spec config_path() :: String.t()
  def config_path do
    Application.get_env(:tiny_axe, :purchases_config) ||
      Path.join(
        System.get_env("XDG_CONFIG_HOME") || Path.expand("~/.config"),
        "tiny-axe/purchases.json"
      )
  end

  defp file_settings do
    with {:ok, raw} <- File.read(config_path()),
         {:ok, %{} = json} <- JSON.decode(raw) do
      [
        enabled: json["enabled"],
        per_order_max: json["per_order_max"],
        daily_max: json["daily_max"],
        currency: json["currency"],
        merchants:
          case json["shops"] do
            "any" -> :any
            list when is_list(list) -> list
            _ -> nil
          end,
        cards: json["cards"] && Enum.map(json["cards"], &card_from_json/1)
      ]
      |> Enum.reject(fn {_k, v} -> v == nil end)
    else
      _ -> []
    end
  end

  # A card's description in purchases.json (`TinyAxe.Cards`); never its details.
  defp card_from_json(c) do
    %{
      id: c["id"],
      label: c["label"],
      brand: c["brand"] || "Card",
      last4: c["last4"],
      purpose: c["purpose"],
      keyring: c["keyring"],
      merchants: if(c["shops"] in [nil, "any"], do: :any, else: c["shops"]),
      per_purchase_max: c["per_purchase_max"],
      monthly_max: c["monthly_max"],
      cvc: c["cvc"] || "stored",
      pin: c["pin"] == true,
      remember: c["remember"],
      expires_at: c["expires_at"]
    }
  end

  @doc "Changes `purchases.json` (keeping what it doesn't change); readable only by the user."
  @spec update_file((map() -> map())) :: :ok
  def update_file(fun) do
    path = config_path()

    current =
      case File.read(path) do
        {:ok, raw} -> JSON.decode!(raw)
        {:error, _} -> %{}
      end

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, current |> fun.() |> pretty_json())
    File.chmod!(path, 0o600)
  end

  @doc false
  # Indented JSON for a file people read; Elixir's nil becomes null (Erlang's
  # :json.format would write it as the string "nil").
  def pretty_json(term), do: term |> nulls() |> :json.format() |> IO.iodata_to_binary()

  defp nulls(nil), do: :null
  defp nulls(%{} = map), do: Map.new(map, fn {k, v} -> {k, nulls(v)} end)
  defp nulls(list) when is_list(list), do: Enum.map(list, &nulls/1)
  defp nulls(other), do: other

  @spec enabled?() :: boolean()
  def enabled?, do: settings()[:enabled] == true

  ## Intent

  @doc """
  What the user asked to buy, from their request: `%{request:, max:, currency:}`
  (`max` is nil when they gave none), or nil when they didn't ask to buy
  anything (Jev decides; no answer is "no").
  """
  @spec intent(String.t(), String.t()) :: map() | nil
  def intent(request, context \\ "") do
    question = %{
      buy: %{
        type: :noul,
        instructions: "Does the user want something bought, ordered or paid for?"
      }
    }

    if enabled?() and
         Decider.yes?(
           Decider.decide(%{request: request, conversation: context}, question),
           :buy,
           0.5
         ) do
      {max, currency} = max_price(request)
      %{request: request, max: max, currency: currency || currency()}
    end
  end

  @doc "The most the user said to spend: `{amount, currency}`, or `{nil, nil}`."
  @spec max_price(String.t()) :: {float() | nil, String.t() | nil}
  def max_price(text) do
    pattern =
      ~r/(?:under|below|less than|at most|no more than|max(?:imum)?|up to|budget(?: of)?|not over|capped at|limit(?: of)?)\s*(?:of\s*)?([$£€])?\s?(\d+(?:[.,]\d{1,2})?)\s*(usd|dollars?|eur|euros?|gbp|pounds?)?/iu

    case Regex.run(pattern, text) do
      [_, symbol, amount | rest] ->
        word = List.first(rest)
        currency = @symbols[symbol] || @words[word && String.downcase(word)]
        {amount |> String.replace(",", ".") |> parse_amount(), currency}

      nil ->
        {nil, nil}
    end
  end

  defp parse_amount(s) do
    case Float.parse(s) do
      {f, _} -> Float.round(f, 2)
      :error -> nil
    end
  end

  defp currency, do: settings()[:currency] || "USD"

  ## The checkout summary and its checks

  @doc "Reads the checkout page the browser is on."
  @spec summary(String.t()) :: {:ok, map()} | {:error, String.t()}
  def summary(server) do
    with {:ok, %{"content" => [%{"text" => json} | _]} = result} <-
           MCP.call(server, "browser_checkout_summary", %{}, 20_000),
         false <- result["isError"] == true,
         {:ok, summary} <- JSON.decode(json) do
      {:ok, summary}
    else
      _ -> {:error, "tiny-axe couldn't read the checkout page"}
    end
  end

  @doc """
  The checks on a summary against the intent and the limits: a list of
  `{:ok | :fail, text}`. Any `:fail` means the purchase can't be approved.
  """
  @spec checks(map() | nil, map(), map() | nil) :: [{:ok | :fail, String.t()}]
  def checks(intent, summary, card \\ nil) do
    s = settings()
    total = summary["total"]
    currency = summary["currency"] || currency()
    today = spent_today(currency)

    [
      cond do
        intent == nil ->
          {:fail, "you didn't ask to buy anything in this request"}

        intent.max == nil ->
          {:fail, "you didn't say the most to spend (e.g. \"under $50\")"}

        not is_number(total) ->
          {:fail, "tiny-axe couldn't read the total on the page"}

        total > intent.max ->
          {:fail,
           "#{money(total, currency)} is over your maximum of #{money(intent.max, intent.currency)}"}

        true ->
          {:ok, "within your maximum of #{money(intent.max, intent.currency)}"}
      end,
      cond do
        intent && currency != intent.currency ->
          {:fail, "the page is in #{currency}, you asked in #{intent.currency}"}

        currency != currency() ->
          {:fail, "the page is in #{currency}; purchases are limited to #{currency()}"}

        true ->
          {:ok, "in #{currency}"}
      end,
      if(is_number(total) and total > (s[:per_order_max] || 100),
        do: {:fail, "over the #{money(s[:per_order_max] || 100, currency)} limit per order"},
        else: {:ok, "within the #{money(s[:per_order_max] || 100, currency)} limit per order"}
      ),
      if(is_number(total) and today + total > (s[:daily_max] || 200),
        do:
          {:fail,
           "#{money(today, currency)} already today; this would pass the #{money(s[:daily_max] || 200, currency)} daily limit"},
        else:
          {:ok,
           "#{money(today + (total || 0), currency)} of #{money(s[:daily_max] || 200, currency)} today"}
      ),
      merchant_check(summary["host"]),
      items_check(intent, summary),
      payment_check(summary)
    ] ++ card_checks(card || paying_card(summary), intent, summary)
  end

  @doc """
  How an order would be paid, from what the checkout page shows:

    * `{:saved, text}` — a card saved at the shop, as the page shows it
      (the chosen one, if there are several)
    * `{:entered, text}` — card fields the user filled in themselves (a handoff)
    * `{:virtual, card}` — empty card fields, and a virtual card in the
      keyring for this shop: tiny-axe fills it in after the user confirms
    * `{:none, why}` — no way tiny-axe will pay
  """
  @spec payment(map()) ::
          {:saved | :entered, String.t()} | {:virtual, map()} | {:none, String.t()}
  def payment(summary) do
    fields = summary["card_fields"] || 0

    cond do
      fields > 0 and summary["card_fields_empty"] == true ->
        case card_for(summary["host"]) do
          nil ->
            {:none,
             "the page needs card details, which tiny-axe never types: use a card saved at " <>
               "the shop, hand off to type it yourself, or add a virtual card"}

          card ->
            {:virtual, card}
        end

      fields > 0 ->
        {:entered, "the card details you entered"}

      is_binary(summary["payment"]) ->
        {:saved, summary["payment"]}

      true ->
        {:none, "tiny-axe can't see how this would be paid"}
    end
  end

  defp paying_card(summary) do
    case payment(summary) do
      {:virtual, card} -> card
      _ -> nil
    end
  end

  @doc "In words, for the user: how the order would be paid."
  @spec paying_with(map()) :: String.t()
  def paying_with(summary) do
    case payment(summary) do
      {:saved, text} -> text
      {:entered, text} -> text
      {:virtual, card} -> "#{card.label} (a virtual card; tiny-axe fills it in after you confirm)"
      {:none, _} -> "(not shown)"
    end
  end

  defp payment_check(summary) do
    case payment(summary) do
      {:none, why} -> {:fail, why}
      _ -> {:ok, "paying with #{paying_with(summary)}"}
    end
  end

  @doc """
  The card tiny-axe would pay with at this shop: the first card the user gave
  it (`/credit-card`, `TinyAxe.Cards`: this session's, then remembered ones;
  or from config) that's allowed here, hasn't expired, and is still available.
  Only its description: the details stay in the vault until the purchase
  (`TinyAxe.Cards.details/2`).
  """
  @spec card_for(String.t() | nil) :: map() | nil
  def card_for(host) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    TinyAxe.Cards.list()
    |> Enum.find(fn card ->
      merchants = card[:merchants] || :any

      (merchants == :any or host in List.wrap(merchants)) and
        (card[:expires_at] == nil or card[:expires_at] > now) and
        TinyAxe.Cards.available?(card)
    end)
    |> case do
      nil -> nil
      card -> Map.put_new(card, :label, "virtual card")
    end
  end

  # The card's own rules, when tiny-axe pays with one of the user's cards:
  # what it's for (Jev judges; no answer fails), and its limits.
  defp card_checks(nil, _intent, _summary), do: []

  defp card_checks(card, intent, summary) do
    total = summary["total"]
    currency = summary["currency"] || currency()
    label = card[:label] || "the card"

    per_purchase =
      case card[:per_purchase_max] do
        max when is_number(max) and is_number(total) and total > max ->
          {:fail, "over #{label}'s limit of #{money(max, currency)} a purchase"}

        max when is_number(max) ->
          {:ok, "within #{label}'s #{money(max, currency)} a purchase"}

        _ ->
          nil
      end

    monthly =
      case card[:monthly_max] do
        max when is_number(max) ->
          spent = spent_this_month(card, currency)

          if is_number(total) and spent + total > max,
            do:
              {:fail,
               "#{money(spent, currency)} already on #{label} this month; this would pass its #{money(max, currency)} monthly limit"},
            else:
              {:ok,
               "#{money(spent + (total || 0), currency)} of #{label}'s #{money(max, currency)} this month"}

        _ ->
          nil
      end

    purpose =
      case card[:purpose] do
        p when p in [nil, ""] ->
          nil

        purpose ->
          question = %{
            fits: %{type: :noul, instructions: "Does this purchase fit what the card is for?"}
          }

          state = %{
            card_is_for: purpose,
            user_request: intent && intent.request,
            order_items: Enum.join(summary["items"] || [], "\n")
          }

          case Decider.p(Decider.decide(state, question), :fits) do
            nil -> {:fail, "tiny-axe couldn't check this purchase fits #{label}'s purpose"}
            p when p >= 0.5 -> {:ok, "fits what #{label} is for (#{purpose})"}
            _ -> {:fail, "this doesn't look like what #{label} is for (#{purpose})"}
          end
      end

    Enum.filter([per_purchase, monthly, purpose], & &1)
  end

  @doc "What was spent this month (UTC) with one card: purchases it was filled in for, that were clicked."
  @spec spent_this_month(map(), String.t()) :: float()
  def spent_this_month(card, currency) do
    month = Date.utc_today() |> Date.to_iso8601() |> String.slice(0, 7)

    for id <- all(),
        events = events(id),
        Enum.any?(
          events,
          &(&1["t"] == "card_filled" and &1["card_id"] == card[:id] and card[:id] != nil)
        ),
        Enum.any?(events, &(&1["t"] in ["clicking", "clicked"])),
        %{"t" => "summary", "summary" => s, "at" => at} <- events,
        String.starts_with?(at, month),
        s["currency"] == currency,
        is_number(s["total"]),
        reduce: 0.0 do
      acc -> acc + s["total"]
    end
  end

  defp merchant_check(host) do
    case settings()[:merchants] || :any do
      :any ->
        {:ok, "from #{host}"}

      list ->
        if host in list,
          do: {:ok, "#{host} is on your list of shops"},
          else: {:fail, "#{host} isn't on your list of shops"}
    end
  end

  # Jev: are these items what the user asked for? No answer fails.
  defp items_check(nil, _summary), do: {:fail, "nothing to compare the items with"}

  defp items_check(intent, summary) do
    question = %{
      matches: %{
        type: :noul,
        instructions: "Are the items in this order what the user asked to buy, and nothing else?"
      }
    }

    state = %{
      user_request: intent.request,
      order_items: Enum.join(summary["items"] || [], "\n"),
      total: summary["total_text"]
    }

    case Decider.p(Decider.decide(state, question), :matches) do
      nil -> {:fail, "tiny-axe couldn't check the items against your request"}
      p when p >= 0.5 -> {:ok, "the items match what you asked for"}
      _ -> {:fail, "the items don't look like what you asked for"}
    end
  end

  @spec money(number(), String.t()) :: String.t()
  def money(amount, currency) do
    symbol = Enum.find_value(@symbols, fn {s, c} -> c == currency && s end)
    formatted = :erlang.float_to_binary(amount * 1.0, decimals: 2)
    if symbol, do: symbol <> formatted, else: "#{formatted} #{currency}"
  end

  ## The journal

  def dir, do: Path.join(TinyAxe.Ops.Journal.state_dir(), "purchases")
  def dir(id), do: Path.join(dir(), id)

  @spec start(map() | nil) :: String.t()
  def start(intent) do
    id =
      "#{Calendar.strftime(DateTime.utc_now(), "%Y%m%d-%H%M%S")}-#{System.unique_integer([:positive])}"

    File.mkdir_p!(dir(id))
    event(id, %{t: "intent", intent: intent})
    id
  end

  @doc "Appends an event to a purchase's journal, synced to disk."
  @spec event(String.t(), map()) :: :ok
  def event(id, event) do
    line = event |> Map.put(:at, DateTime.utc_now() |> DateTime.to_iso8601()) |> JSON.encode!()
    {:ok, io} = :file.open(Path.join(dir(id), "journal.jsonl"), [:append, :binary, :raw])

    try do
      :ok = :file.write(io, line <> "\n")
      :ok = :file.sync(io)
    after
      :file.close(io)
    end
  end

  @spec events(String.t()) :: [map()]
  def events(id) do
    case File.read(Path.join(dir(id), "journal.jsonl")) do
      {:ok, raw} ->
        for line <- String.split(raw, "\n", trim: true), {:ok, e} <- [JSON.decode(line)], do: e

      {:error, _} ->
        []
    end
  end

  defp all,
    do:
      (case File.ls(dir()) do
         {:ok, ids} -> Enum.sort(ids)
         _ -> []
       end)

  @doc "What was spent today (UTC), in a currency, by purchases that were clicked."
  @spec spent_today(String.t()) :: float()
  def spent_today(currency) do
    today = Date.utc_today() |> Date.to_iso8601()

    for id <- all(),
        events = events(id),
        Enum.any?(events, &(&1["t"] in ["clicking", "clicked"])),
        %{"t" => "summary", "summary" => s, "at" => at} <- events,
        String.starts_with?(at, today),
        s["currency"] == currency,
        is_number(s["total"]),
        reduce: 0.0 do
      acc -> acc + s["total"]
    end
  end

  @doc """
  Purchases that may have gone through without tiny-axe seeing the
  confirmation: they reached `clicking`, with no `receipt` or `unconfirmed`
  note yet. Each is reported once (`noted`).
  """
  @spec uncertain() :: [String.t()]
  def uncertain do
    for id <- all(),
        events = events(id),
        Enum.any?(events, &(&1["t"] == "clicking")),
        not Enum.any?(events, &(&1["t"] in ["receipt", "noted"])) do
      summary = Enum.find_value(events, fn e -> e["t"] == "summary" && e["summary"] end) || %{}
      event(id, %{t: "noted"})

      "⚠ an order may have been placed at #{summary["host"] || "a shop"} for #{summary["total_text"] || "an unknown amount"} " <>
        "(#{id}), but tiny-axe stopped before it saw the confirmation. Check your orders or email; it won't be placed again."
    end
  end
end
