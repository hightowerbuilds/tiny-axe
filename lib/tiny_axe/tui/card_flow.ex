defmodule TinyAxe.TUI.CardFlow do
  @moduledoc """
  `/credit-card`: giving tiny-axe a card, one question at a time, in a popup.

  The card's number, expiry, CVC, name and PIN are typed straight into the
  card vault (`TinyAxe.Cards`), a keystroke at a time; this flow (and so the
  TUI's state) only ever holds what's safe to show: `•••• •••• •••• 1111`.
  Everything else asked (a name for the card, what it's for, which shops,
  how long to remember it, its limits) is ordinary text.

  `key/2` takes a key and returns `{:cont, flow}`, `{:done, message}` or
  `{:cancel, message}`.
  """

  alias TinyAxe.Cards

  @remember [
    {"1", "session", "this session only (never written to disk)"},
    {"2", "1d", "1 day"},
    {"3", "7d", "7 days"},
    {"4", "30d", "30 days"},
    {"5", "forever", "until I remove it"}
  ]

  # {step, kind, question}; kinds: :secret (typed into the vault, masked),
  # :text, :choice.
  @steps [
    {:number, :secret, "Card number"},
    {:exp, :secret, "Expiry (MM/YY)"},
    {:cvc_policy, :choice, "Should tiny-axe keep the CVC, or ask you for it at each purchase?"},
    {:cvc, :secret, "CVC (3 or 4 digits)"},
    {:name, :secret, "Name on the card"},
    {:label, :text, "A name for this card (enter for the brand and last 4)"},
    {:purpose, :text,
     "What is this card for? (e.g. \"books and household things\"; each purchase is checked against it)"},
    {:shops, :text,
     "Which shops may it be used at? (enter for any, or e.g. amazon.com, bookshop.org)"},
    {:remember, :choice, "How long should tiny-axe remember it?"},
    {:per_purchase, :text,
     "The most it may spend in one purchase (a number; enter for your overall limit)"},
    {:per_month, :text,
     "The most it may spend in a month (a number; enter for no monthly limit)"},
    {:pin, :secret,
     "Lock it with a PIN you type at each purchase? (4–12 digits; enter for no PIN)"},
    {:pin_again, :secret, "Type the PIN again"},
    {:confirm, :choice, "Save this card?"}
  ]

  @doc "A new flow: the vault's draft is cleared."
  def new do
    Cards.start_entry()
    %{step: 0, display: "", buffer: "", answers: %{}, error: nil}
  end

  def step(flow), do: Enum.at(@steps, flow.step)

  @doc "The choices for a choice step."
  def choices(:cvc_policy),
    do: [
      {"s", "stored", "keep it with the card"},
      {"a", "ask", "ask me each time (safer: never saved)"}
    ]

  def choices(:remember), do: @remember
  def choices(:confirm), do: [{"y", "save", "save it"}, {"n", "discard", "discard it"}]

  @spec key(map(), String.t()) :: {:cont, map()} | {:done, String.t()} | {:cancel, String.t()}
  def key(_flow, "esc") do
    Cards.discard_entry()
    {:cancel, "card entry cancelled; nothing was saved"}
  end

  def key(flow, key) do
    {name, kind, _q} = step(flow)
    flow = %{flow | error: nil}

    case {kind, key} do
      {:secret, "enter"} ->
        secret_done(flow, name)

      {:secret, k} ->
        {:cont, %{flow | display: Cards.entry_key(name, k)}}

      {:text, "enter"} ->
        text_done(flow, name, String.trim(flow.buffer))

      {:text, "backspace"} ->
        {:cont, %{flow | buffer: String.slice(flow.buffer, 0..-2//1)}}

      {:text, k} ->
        {:cont, if(String.length(k) == 1, do: %{flow | buffer: flow.buffer <> k}, else: flow)}

      {:choice, k} ->
        choose(flow, name, k)
    end
  end

  @doc "Pasted text: into the vault for a secret step, into the answer otherwise."
  def paste(flow, text) do
    case step(flow) do
      {name, :secret, _} ->
        display =
          text
          |> String.graphemes()
          |> Enum.reduce(flow.display, fn ch, _ -> Cards.entry_key(name, ch) end)

        %{flow | display: display}

      {_name, :text, _} ->
        %{flow | buffer: flow.buffer <> String.replace(text, "\n", " ")}

      _ ->
        flow
    end
  end

  defp secret_done(flow, name) do
    case Cards.entry_check(name) do
      :ok ->
        # Whether a PIN was set is all the flow keeps of it.
        flow = if name == :pin, do: put_in(flow.answers[:pin?], flow.display != ""), else: flow

        flow =
          if name == :number, do: put_in(flow.answers[:card], Cards.entry_summary()), else: flow

        {:cont, advance(flow)}

      {:error, why} ->
        {:cont, %{flow | error: why}}
    end
  end

  defp text_done(flow, name, value) do
    case parse(name, value) do
      {:ok, v} -> {:cont, advance(put_in(flow.answers[name], v))}
      {:error, why} -> {:cont, %{flow | error: why}}
    end
  end

  defp parse(field, "") when field in [:per_purchase, :per_month], do: {:ok, nil}

  defp parse(field, value) when field in [:per_purchase, :per_month] do
    case Float.parse(String.trim_leading(value, "$")) do
      {n, ""} when n > 0 -> {:ok, Float.round(n, 2)}
      _ -> {:error, "a number, like 25 or 40.50"}
    end
  end

  defp parse(:purpose, ""), do: {:error, "say what it's for: each purchase is checked against it"}
  defp parse(_field, value), do: {:ok, value}

  defp choose(flow, name, k) do
    case List.keyfind(choices(name), k, 0) do
      nil ->
        {:cont, flow}

      {_, "discard", _} ->
        Cards.discard_entry()
        {:cancel, "the card wasn't saved"}

      {_, "save", _} ->
        save(flow)

      {_, value, _} ->
        {:cont, advance(put_in(flow.answers[name], value))}
    end
  end

  # Steps that don't apply are skipped: the CVC when it's asked each time, the
  # second PIN when there's none.
  defp advance(flow) do
    next = %{flow | step: flow.step + 1, display: "", buffer: ""}

    case step(next) do
      {:cvc, _, _} ->
        if Map.get(next.answers, :cvc_policy) == "ask", do: advance(next), else: next

      {:pin_again, _, _} ->
        if next.answers[:pin?], do: next, else: advance(next)

      _ ->
        next
    end
  end

  defp save(flow) do
    a = flow.answers
    card = a[:card] || %{}

    answers = %{
      "label" => blank_to_nil(a[:label]) || "#{card[:brand]} ••#{card[:last4]}",
      "purpose" => a[:purpose],
      "shops" => if(a[:shops] in [nil, ""], do: "any", else: a[:shops]),
      "remember" => a[:remember],
      "per_purchase_max" => a[:per_purchase],
      "monthly_max" => a[:per_month],
      "cvc" => a[:cvc_policy]
    }

    case Cards.save(answers) do
      {:ok, meta} -> {:done, saved_message(meta)}
      {:error, why} -> {:cont, %{flow | error: why}}
    end
  end

  defp blank_to_nil(v) when v in [nil, ""], do: nil
  defp blank_to_nil(v), do: v

  @doc "One line describing a saved card: never its number."
  def saved_message(meta) do
    remember =
      case meta.remember do
        "session" -> "for this session only"
        "forever" -> "until you remove it"
        days -> "for #{String.trim_trailing(days, "d")} day(s)"
      end

    extras =
      [
        meta.pin && "locked with a PIN",
        meta.cvc == "ask" && "CVC asked each time",
        meta.per_purchase_max && "≤ #{meta.per_purchase_max} a purchase",
        meta.monthly_max && "≤ #{meta.monthly_max} a month"
      ]
      |> Enum.filter(& &1)

    "💳 saved #{meta.label} (#{meta.brand} ••#{meta.last4}) #{remember}" <>
      if(extras == [], do: "", else: "; " <> Enum.join(extras, ", ")) <>
      ". Card details are in tiny-axe's vault#{if meta.keyring, do: " and your keyring"} only."
  end

  @doc "What's been answered so far, for the popup: nothing secret."
  def summary_lines(flow) do
    a = flow.answers

    [
      a[:card] && "Card: #{a[:card][:brand]} ending #{a[:card][:last4]}",
      a[:cvc_policy] &&
        "CVC: #{if a[:cvc_policy] == "ask", do: "asked each time", else: "kept with the card"}",
      a[:label] && "Name: #{a[:label]}",
      a[:purpose] && "For: #{a[:purpose]}",
      Map.has_key?(a, :shops) && "Shops: #{if a[:shops] in [nil, ""], do: "any", else: a[:shops]}",
      a[:remember] &&
        "Remembered: #{a[:remember] |> then(&List.keyfind(@remember, &1, 1)) |> elem(2)}",
      Map.has_key?(a, :per_purchase) &&
        "Per purchase: #{a[:per_purchase] || "your overall limit"}",
      Map.has_key?(a, :per_month) && "Per month: #{a[:per_month] || "no monthly limit"}",
      Map.has_key?(a, :pin?) && "PIN: #{if a[:pin?], do: "yes", else: "no"}"
    ]
    |> Enum.filter(& &1)
  end
end
