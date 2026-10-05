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

  @spec settings() :: keyword()
  def settings, do: Application.get_env(:tiny_axe, :purchases, [])

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
  @spec checks(map() | nil, map()) :: [{:ok | :fail, String.t()}]
  def checks(intent, summary) do
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
      items_check(intent, summary)
    ]
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
