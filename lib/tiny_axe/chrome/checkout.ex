defmodule TinyAxe.Chrome.Checkout do
  @moduledoc """
  A checkout summary from a page's text, for purchases in the user's Chrome
  (`TinyAxe.Chrome`): the same rules as tiny-axe's own browser
  (`checkout()` in `priv/browser/server.mjs`), read in code from what
  `get_page_text` returned, never from what a model said about the page.

  The summary has the keys `TinyAxe.Purchases.checks/3` and the purchase
  popup use: `host`, `url`, `title`, `total`, `total_text`, `currency`,
  `items`, `ship_to`, `payment`, `card_fields` (always 0: tiny-axe never
  fills cards in Chrome).
  """

  alias TinyAxe.Tools.Redact

  @money ~r/([$£€])\s?(\d{1,3}(?:,\d{3})*(?:\.\d{2})?|\d+(?:\.\d{2})?)|(\d+(?:\.\d{2})?)\s?(USD|EUR|GBP)\b/
  @symbols %{"$" => "USD", "£" => "GBP", "€" => "EUR"}

  @not_item ~r/total|tax|vat|shipping|delivery|postage|discount|subtotal|you save|balance|items?:/i
  @offer ~r/upon approval|apply now|sign up|no annual fee|open offer|card ?member/i
  @noise ~r/^(\d[\d,.]*[k+]* bought|in stock|only \d+ left|ships from|shipped by|sold by|fulfilled by|qty|quantity|change|edit|remove|delete|save for later|arriving|arrives|get it|free returns|returnable|eligible|gift options|add (a )?gift|see (all )?details|condition|colou?r:|size:|style:|pattern:|paying with|ending (in )?\d{4}|deliver|ship to)/i
  @card ~r/(visa|master ?card|amex|american express|discover|debit card|credit card)\b[^\n]*?\b\d{4}\b/i
  @card_each ~r/(?:visa|master ?card|amex|american express|discover|debit card|credit card)\b[^\n]*?\b\d{4}\b/i
  @order ~r/(?i:order|confirmation)\s*(?i:number|no\.?|#|id)?\s*[:#]?\s*([A-Z0-9][A-Z0-9-]{3,})/

  @doc """
  The summary of a checkout page's text, at `url`. `chosen` is the card the
  agent picked on this page by clicking its name, if it did: the page's text
  doesn't say which of several cards is selected. With several and none
  picked, `payment` is nil and `cards` lists them.
  """
  @spec summary(String.t(), String.t() | nil, String.t() | nil) :: map()
  def summary(text, url, chosen \\ nil) do
    {title, body} = split(text)

    lines =
      body
      |> Redact.text()
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    priced = Enum.filter(lines, &(amounts(&1) != []))

    total =
      priced
      |> Enum.filter(&(&1 =~ ~r/total|amount due|to pay/i and not (&1 =~ ~r/sub-?total/i)))
      |> List.last()
      |> then(&(&1 && List.last(amounts(&1))))

    %{
      "host" => url && URI.parse(url).host,
      "url" => url,
      "title" => title,
      "total" => total && total.value,
      "total_text" => total && total.text,
      "currency" => total && total.currency,
      "items" => items(lines, total),
      "ship_to" => ship_to(lines),
      "payment" => payment(cards(lines), lines, chosen),
      "cards" => cards(lines),
      "card_fields" => 0,
      "card_fields_empty" => false
    }
  end

  @doc "A Chrome result's text (a list of text parts, or text)."
  def text(parts) when is_list(parts),
    do:
      Enum.map_join(parts, "\n", fn p -> if is_map(p), do: p["text"] || "", else: to_string(p) end)

  def text(text) when is_binary(text), do: text
  def text(_other), do: ""

  @doc "The order number on a confirmation page, if it shows one."
  @spec order_number(String.t()) :: String.t() | nil
  def order_number(text) do
    case Regex.run(@order, text) do
      [_, order] -> order
      nil -> nil
    end
  end

  # get_page_text: "Title: …\nURL: …\nSource element: …\n---\n<the page>".
  defp split(text) do
    title =
      case Regex.run(~r/^Title: (.*)$/m, text) do
        [_, t] -> String.trim(t)
        _ -> ""
      end

    body =
      case String.split(text, "\n---\n", parts: 2) do
        [_head, body] -> body
        [all] -> all
      end

    # The Tab Context Claude in Chrome adds isn't the page.
    {title, body |> String.split("\n\nTab Context:", parts: 2) |> hd()}
  end

  defp amounts(line) do
    for [match | groups] <- Regex.scan(@money, line) do
      [sym, num, num2, code] = groups ++ List.duplicate("", 4 - length(groups))
      value = if(num != "", do: num, else: num2) |> String.replace(",", "") |> to_number()

      %{
        value: value,
        currency: if(sym != "", do: @symbols[sym], else: code),
        text: String.trim(match)
      }
    end
  end

  defp to_number(s) do
    case Float.parse(s) do
      {f, _} -> f
      :error -> 0.0
    end
  end

  defp items(lines, total) do
    in_order? = fn l ->
      total == nil or Enum.any?(amounts(l), &(&1.value <= total.value + 0.005))
    end

    title? = fn l ->
      amounts(l) == [] and not (l =~ @not_item) and not (l =~ @offer) and not (l =~ @noise) and
        length(String.split(l)) >= 3
    end

    lines
    |> Enum.with_index()
    |> Enum.flat_map(fn {l, i} ->
      cond do
        amounts(l) == [] or l =~ @not_item or l =~ @offer or not in_order?.(l) ->
          []

        not price_only?(l) ->
          [l]

        true ->
          # A price on a line of its own belongs to the nearest title above it.
          lines
          |> Enum.slice(max(0, i - 6), min(i, 6))
          |> Enum.reverse()
          |> Enum.find(title?)
          |> case do
            nil -> []
            title -> ["#{title} — #{l}"]
          end
      end
    end)
    |> Enum.uniq()
    |> Enum.take(15)
  end

  defp price_only?(l),
    do: l |> String.replace(@money, "") |> String.replace(~r/[^\p{L}]/u, "") == ""

  defp ship_to(lines) do
    case Enum.find_index(
           lines,
           &(&1 =~ ~r/ship(ping)? to|deliver(y|ing)? to|shipping address|delivery address/i)
         ) do
      nil -> nil
      at -> lines |> Enum.slice(at, 3) |> Enum.join(", ")
    end
  end

  @doc "Whether a label names a payment card (\"Mastercard ending in 5555\")."
  def card?(label) when is_binary(label), do: label =~ @card
  def card?(_label), do: false

  # The cards the page shows, each once.
  defp cards(lines) do
    lines
    |> Enum.flat_map(&Regex.scan(@card_each, &1))
    |> Enum.map(&String.trim(hd(&1)))
    |> Enum.reject(&(&1 =~ ~r/total|order/i))
    |> Enum.uniq()
  end

  defp payment([], lines, _chosen),
    do: Enum.find(lines, &(&1 =~ @card and not (&1 =~ ~r/total|order/i)))

  defp payment([one], _lines, _chosen), do: one

  # Several: only the one the agent picked, and only if it's among them.
  defp payment(several, _lines, chosen) when is_binary(chosen) do
    Enum.find(several, &same_card?(&1, chosen))
  end

  defp payment(_several, _lines, _chosen), do: nil

  defp same_card?(a, b) do
    norm = fn s -> s |> String.downcase() |> String.replace(~r/\s+/, " ") |> String.trim() end
    String.contains?(norm.(a), norm.(b)) or String.contains?(norm.(b), norm.(a))
  end
end
