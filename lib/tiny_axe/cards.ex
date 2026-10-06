defmodule TinyAxe.Cards do
  @moduledoc """
  The card vault: payment cards the user gave tiny-axe with `/credit-card`.

  Card details live only in this process and in the system keyring, never in
  the TUI's state, the transcript, a log, a journal or anything a model sees.
  This process is marked sensitive (its state can't be traced or read with
  `process_info`) and its state is scrubbed from crash reports.

    * **Entry** — the TUI sends each keystroke of the number, expiry, CVC and
      PIN here (`entry_key/2`) and gets back only a masked display; the draft
      is checked here (Luhn, a future expiry) and discarded unless saved.
    * **Remembering** — for this session only (in memory, never on disk), or
      for a number of days, or until removed: then the details go to the
      keyring (`secret-tool`, encrypted at rest by the user's login), and only
      a description (name, brand, last 4, purpose, shops, limits, when to
      forget) goes to `purchases.json`. A card past its time is wiped from the
      keyring (`expire_due/0`).
    * **A PIN** — encrypts the details with a key derived from it
      (PBKDF2-HMAC-SHA256, 200,000 rounds; AES-256-GCM), so even a program
      that can read the keyring can't use the card. The PIN is asked at each
      purchase and never stored.
    * **The CVC** — stored with the card, or asked at each purchase and never
      stored.
    * **Use** — at checkout the TUI sends the PIN / CVC keystrokes for that
      purchase here (`unlock_key/3`); `details/2` then decrypts the card for
      that one purchase and forgets what was typed.
  """

  use GenServer

  require Logger

  alias TinyAxe.{MCP, Purchases}

  @iterations 200_000
  @remember %{"session" => nil, "1d" => 1, "7d" => 7, "30d" => 30, "forever" => :forever}

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  ## Entry (the TUI's /credit-card)

  @doc "Starts a fresh entry, discarding any draft."
  def start_entry, do: GenServer.call(__MODULE__, :start_entry)

  @doc "Discards the draft."
  def discard_entry, do: GenServer.call(__MODULE__, :discard_entry)

  @doc """
  A keystroke for a sensitive field of the draft (`:number`, `:exp`, `:cvc`,
  `:name`, `:pin`, `:pin_again`): a character, or "backspace". Returns the
  field as it should be shown (masked).
  """
  @spec entry_key(atom(), String.t()) :: String.t()
  def entry_key(field, key), do: GenServer.call(__MODULE__, {:entry_key, field, key})

  @doc "Checks a draft field: `:ok` or `{:error, why}`."
  @spec entry_check(atom()) :: :ok | {:error, String.t()}
  def entry_check(field), do: GenServer.call(__MODULE__, {:entry_check, field})

  @doc "What the draft card is, safe to show: brand and last 4."
  @spec entry_summary() :: %{brand: String.t(), last4: String.t()}
  def entry_summary, do: GenServer.call(__MODULE__, :entry_summary)

  @doc """
  Saves the draft with the user's answers: `label`, `purpose`, `shops` ("any"
  or a list), `remember` ("session" | "1d" | "7d" | "30d" | "forever"),
  `per_purchase_max`, `monthly_max` (numbers or nil), `cvc` ("stored" |
  "ask"). A PIN, if one was entered, encrypts it. Returns the card's
  description.
  """
  @spec save(map()) :: {:ok, map()} | {:error, String.t()}
  def save(answers), do: GenServer.call(__MODULE__, {:save, answers}, 30_000)

  ## Cards

  @doc "Every card tiny-axe knows (descriptions only), the session's first."
  @spec list() :: [map()]
  def list, do: GenServer.call(__MODULE__, :session_cards) ++ stored()

  @doc "Forgets a card by its name: wiped from memory or the keyring."
  @spec forget(String.t()) :: :ok | {:error, :not_found}
  def forget(label) do
    case Enum.find(list(), &(&1.label == label)) do
      nil -> {:error, :not_found}
      card -> forget_card(card)
    end
  end

  @doc "Forgets cards whose time is up. Returns a note for each."
  @spec expire_due() :: [String.t()]
  def expire_due do
    now = DateTime.utc_now()

    for card <- stored(),
        is_binary(card.expires_at),
        {:ok, at, _} <- [DateTime.from_iso8601(card.expires_at)],
        DateTime.compare(at, now) == :lt do
      forget_card(card)
      "💳 forgot #{card.label} (#{card.brand} ••#{card.last4}): its time to be remembered was up"
    end
  end

  ## Use (the purchase gate)

  @doc "Whether a card can be used: in memory, or still in the keyring (read in this process)."
  @spec available?(map()) :: boolean()
  def available?(card), do: GenServer.call(__MODULE__, {:available, card})

  @doc "Whether using a card needs the PIN and/or the CVC typed at checkout."
  @spec needs(map()) :: [:pin | :cvc]
  def needs(card) do
    Enum.filter([pin: card[:pin] == true, cvc: card[:cvc] == "ask"], &elem(&1, 1))
    |> Keyword.keys()
  end

  @doc "A keystroke of the PIN or CVC for one purchase (`ref`). Returns the masked field."
  @spec unlock_key(reference(), :pin | :cvc, String.t()) :: String.t()
  def unlock_key(ref, field, key), do: GenServer.call(__MODULE__, {:unlock_key, ref, field, key})

  @doc """
  The card's details for one purchase: decrypted with the PIN typed for
  `ref`, with the CVC typed for it if the card doesn't store one. What was
  typed is forgotten either way.
  """
  @spec details(map(), reference() | nil) :: {:ok, map()} | {:error, String.t()}
  def details(card, ref), do: GenServer.call(__MODULE__, {:details, card, ref}, 30_000)

  ## Server

  @impl true
  def init(:ok) do
    # Nothing can trace this process or read its state with process_info.
    Process.flag(:sensitive, true)
    {:ok, %{draft: blank(), session: %{}, unlock: %{}}}
  end

  # Crash reports and :sys.get_status show no card details.
  @impl true
  def format_status(status), do: Map.put(status, :state, :redacted)

  defp blank, do: %{number: "", exp: "", cvc: "", name: "", pin: "", pin_again: ""}

  @impl true
  def handle_call(:start_entry, _from, s), do: {:reply, :ok, %{s | draft: blank()}}
  def handle_call(:discard_entry, _from, s), do: {:reply, :ok, %{s | draft: blank()}}

  def handle_call({:entry_key, field, key}, _from, s) do
    value = edit(s.draft[field], key, limit(field), allowed(field))
    draft = Map.put(s.draft, field, value)
    {:reply, mask(field, value), %{s | draft: draft}}
  end

  def handle_call({:entry_check, field}, _from, s), do: {:reply, check(field, s.draft), s}

  def handle_call(:entry_summary, _from, s) do
    digits = digits(s.draft.number)
    {:reply, %{brand: brand(digits), last4: String.slice(digits, -4, 4)}, s}
  end

  def handle_call({:save, answers}, _from, s) do
    # A CVC asked at each purchase is never typed here.
    fields = [:number, :exp, :pin] ++ if(answers["cvc"] == "ask", do: [], else: [:cvc])

    case Enum.find_value(fields, &(check(&1, s.draft) |> error_or_nil())) do
      nil ->
        {reply, s} = do_save(answers, s)
        {:reply, reply, %{s | draft: blank()}}

      why ->
        {:reply, {:error, why}, s}
    end
  end

  def handle_call({:available, card}, _from, s) do
    available =
      Map.has_key?(s.session, card[:id]) or
        (is_binary(card[:keyring]) and MCP.keyring(card.keyring) != "")

    {:reply, available, s}
  end

  def handle_call(:session_cards, _from, s),
    do: {:reply, Enum.map(Map.values(s.session), & &1.meta), s}

  def handle_call({:forget_session, id}, _from, s),
    do: {:reply, :ok, %{s | session: Map.delete(s.session, id)}}

  def handle_call({:unlock_key, ref, field, key}, _from, s) do
    current = get_in(s.unlock, [ref, field]) || ""
    value = edit(current, key, limit(field), allowed(field))
    unlock = Map.update(s.unlock, ref, %{field => value}, &Map.put(&1, field, value))
    {:reply, mask(field, value), %{s | unlock: unlock}}
  end

  def handle_call({:details, card, ref}, _from, s) do
    {typed, unlock} = Map.pop(s.unlock, ref, %{})
    {:reply, unlock_details(card, typed, s), %{s | unlock: unlock}}
  end

  ## Keystrokes

  defp edit(value, "backspace", _limit, _allowed), do: String.slice(value, 0..-2//1)

  defp edit(value, key, limit, allowed) do
    if String.length(key) == 1 and key =~ allowed and String.length(value) < limit,
      do: value <> key,
      else: value
  end

  defp limit(:number), do: 23
  defp limit(:exp), do: 5
  defp limit(:cvc), do: 4
  defp limit(:name), do: 60
  defp limit(field) when field in [:pin, :pin_again], do: 12

  defp allowed(:number), do: ~r/\A[0-9 ]\z/
  defp allowed(:exp), do: ~r/\A[0-9\/]\z/
  defp allowed(:name), do: ~r/\A[\p{L} .'-]\z/u
  defp allowed(_digits), do: ~r/\A[0-9]\z/

  # Only the last 4 of the number ever shows; the CVC and PIN never do.
  defp mask(:number, value) do
    d = digits(value)
    shown = String.duplicate("•", max(String.length(d) - 4, 0)) <> String.slice(d, -4, 4)
    shown |> String.graphemes() |> Enum.chunk_every(4) |> Enum.map_join(" ", &Enum.join/1)
  end

  defp mask(field, value) when field in [:exp, :name], do: value
  defp mask(_secret, value), do: String.duplicate("•", String.length(value))

  ## Checks

  defp check(:number, d) do
    digits = digits(d.number)

    cond do
      String.length(digits) not in 13..19 ->
        {:error, "a card number has 13 to 19 digits"}

      not TinyAxe.Tools.Redact.luhn?(digits) ->
        {:error, "that isn't a valid card number (check the digits)"}

      true ->
        :ok
    end
  end

  defp check(:exp, d) do
    with [_, mm, yy] <- Regex.run(~r/\A(\d{2})\/?(\d{2})\z/, d.exp),
         {m, ""} when m in 1..12 <- Integer.parse(mm),
         {y, ""} <- Integer.parse(yy) do
      today = Date.utc_today()
      last_day = Date.end_of_month(Date.new!(2000 + y, m, 1))

      if Date.compare(last_day, today) == :lt,
        do: {:error, "that card has expired"},
        else: :ok
    else
      _ -> {:error, "the expiry is MM/YY, like 08/29"}
    end
  end

  defp check(:cvc, d),
    do:
      if(String.length(d.cvc) in 3..4,
        do: :ok,
        else: {:error, "the CVC is 3 or 4 digits (4 on Amex)"}
      )

  defp check(:name, _d), do: :ok

  defp check(:pin, d) do
    cond do
      d.pin == "" -> :ok
      String.length(d.pin) < 4 -> {:error, "a PIN has at least 4 digits"}
      true -> :ok
    end
  end

  defp check(:pin_again, d),
    do: if(d.pin == d.pin_again, do: :ok, else: {:error, "the PINs don't match; type it again"})

  defp error_or_nil({:error, why}), do: why
  defp error_or_nil(:ok), do: nil

  defp digits(value), do: String.replace(value, ~r/\D/, "")

  @doc false
  def brand("4" <> _), do: "Visa"
  def brand("5" <> <<d, _::binary>>) when d in ?1..?5, do: "Mastercard"
  def brand("2" <> _), do: "Mastercard"
  def brand("34" <> _), do: "Amex"
  def brand("37" <> _), do: "Amex"
  def brand("6" <> _), do: "Discover"
  def brand(_), do: "Card"

  ## Saving

  defp do_save(answers, s) do
    d = s.draft
    digits = digits(d.number)
    [mm, yy] = Regex.run(~r/\A(\d{2})\/?(\d{2})\z/, d.exp, capture: :all_but_first)
    store_cvc? = answers["cvc"] != "ask"

    details =
      %{"number" => digits, "exp_month" => mm, "exp_year" => "20#{yy}", "name" => d.name}
      |> then(&if(store_cvc?, do: Map.put(&1, "cvc", d.cvc), else: &1))

    id = "card-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    remember = answers["remember"] || "session"

    meta = %{
      id: id,
      label: answers["label"] || "#{brand(digits)} ••#{String.slice(digits, -4, 4)}",
      brand: brand(digits),
      last4: String.slice(digits, -4, 4),
      purpose: answers["purpose"],
      merchants: shops(answers["shops"]),
      per_purchase_max: answers["per_purchase_max"],
      monthly_max: answers["monthly_max"],
      cvc: if(store_cvc?, do: "stored", else: "ask"),
      pin: d.pin != "",
      remember: remember,
      expires_at: expires_at(@remember[remember]),
      keyring: if(remember == "session", do: nil, else: "tiny-axe-" <> id)
    }

    secret = if meta.pin, do: encrypt(details, d.pin), else: %{"v" => 1, "card" => details}

    if remember == "session" do
      {{:ok, meta}, %{s | session: Map.put(s.session, id, %{meta: meta, secret: secret})}}
    else
      case keyring_store(meta.keyring, meta.label, JSON.encode!(secret)) do
        :ok ->
          Purchases.update_file(
            &Map.update(&1, "cards", [to_json(meta)], fn cards -> cards ++ [to_json(meta)] end)
          )

          {{:ok, meta}, s}

        {:error, why} ->
          {{:error, "couldn't save it to the keyring: #{why}"}, s}
      end
    end
  end

  defp shops(nil), do: :any
  defp shops("any"), do: :any
  defp shops(list) when is_list(list), do: if(list == [], do: :any, else: list)

  # "any", "any shop", "anywhere" or nothing: any shop. Otherwise web
  # addresses, lowercased ("Amazon.com" is amazon.com).
  defp shops(text) when is_binary(text) do
    text = text |> String.trim() |> String.downcase()

    if text == "" or text =~ ~r/\bany/,
      do: :any,
      else:
        text |> String.split([",", " "], trim: true) |> Enum.map(&String.trim_leading(&1, "www."))
  end

  defp expires_at(nil), do: nil
  defp expires_at(:forever), do: nil

  defp expires_at(days),
    do:
      DateTime.utc_now()
      |> DateTime.add(days, :day)
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()

  defp to_json(meta) do
    %{
      "id" => meta.id,
      "label" => meta.label,
      "brand" => meta.brand,
      "last4" => meta.last4,
      "purpose" => meta.purpose,
      "shops" => if(meta.merchants == :any, do: "any", else: meta.merchants),
      "per_purchase_max" => meta.per_purchase_max,
      "monthly_max" => meta.monthly_max,
      "cvc" => meta.cvc,
      "pin" => meta.pin,
      "remember" => meta.remember,
      "expires_at" => meta.expires_at,
      "keyring" => meta.keyring
    }
  end

  @doc false
  # Cards described in purchases.json (and config), the way Purchases reads them.
  def stored, do: Purchases.settings()[:cards] || []

  defp forget_card(%{keyring: nil, id: id}), do: GenServer.call(__MODULE__, {:forget_session, id})

  defp forget_card(card) do
    keyring_clear(card.keyring)

    Purchases.update_file(fn json ->
      Map.update(json, "cards", [], fn cards ->
        Enum.reject(
          cards,
          &((&1["id"] == card[:id] and card[:id] != nil) or &1["label"] == card.label)
        )
      end)
    end)

    :ok
  end

  ## Unlocking

  defp unlock_details(card, typed, s) do
    secret =
      case Map.get(s.session, card[:id]) do
        %{secret: secret} -> {:ok, secret}
        nil -> keyring_secret(card)
      end

    with {:ok, secret} <- secret,
         {:ok, details} <- open(secret, typed[:pin]) do
      cond do
        card[:cvc] == "ask" and String.length(typed[:cvc] || "") not in 3..4 ->
          {:error, "the CVC wasn't typed"}

        card[:cvc] == "ask" ->
          {:ok, Map.put(details, "cvc", typed[:cvc])}

        true ->
          {:ok, details}
      end
    end
  end

  defp keyring_secret(card) do
    case MCP.keyring(card.keyring) do
      "" ->
        {:error, "#{card.label} isn't in the keyring any more"}

      raw ->
        JSON.decode(raw)
        |> then(fn
          {:ok, j} -> {:ok, j}
          _ -> {:error, "#{card.label}'s keyring entry can't be read"}
        end)
    end
  end

  # v1: %{"v" => 1, "card" => details}; v1 with a PIN: %{"v" => 1, "salt", "iv", "tag", "data"};
  # cards from before /credit-card: the details themselves.
  defp open(%{"v" => 1, "card" => details}, _pin), do: {:ok, details}

  defp open(%{"v" => 1, "data" => _} = secret, pin) when is_binary(pin) and pin != "" do
    key = :crypto.pbkdf2_hmac(:sha256, pin, Base.decode64!(secret["salt"]), @iterations, 32)

    case :crypto.crypto_one_time_aead(
           :aes_256_gcm,
           key,
           Base.decode64!(secret["iv"]),
           Base.decode64!(secret["data"]),
           "tiny-axe card",
           Base.decode64!(secret["tag"]),
           false
         ) do
      plain when is_binary(plain) -> JSON.decode(plain)
      :error -> {:error, "the PIN didn't unlock the card"}
    end
  end

  defp open(%{"v" => 1, "data" => _}, _pin),
    do: {:error, "the card is locked with a PIN, and none was typed"}

  defp open(%{"number" => _} = details, _pin), do: {:ok, details}
  defp open(_other, _pin), do: {:error, "the card's details can't be read"}

  defp encrypt(details, pin) do
    salt = :crypto.strong_rand_bytes(16)
    iv = :crypto.strong_rand_bytes(12)
    key = :crypto.pbkdf2_hmac(:sha256, pin, salt, @iterations, 32)

    {data, tag} =
      :crypto.crypto_one_time_aead(
        :aes_256_gcm,
        key,
        iv,
        JSON.encode!(details),
        "tiny-axe card",
        true
      )

    %{
      "v" => 1,
      "salt" => Base.encode64(salt),
      "iv" => Base.encode64(iv),
      "tag" => Base.encode64(tag),
      "data" => Base.encode64(data)
    }
  end

  ## The keyring

  # The secret goes in through an environment variable of a process that ends
  # at once, never on a command line (where `ps` would show it) or in a file.
  defp keyring_store(key, label, secret) do
    tool = Application.get_env(:tiny_axe, :secret_tool, "secret-tool")

    case System.find_executable(tool) do
      nil ->
        {:error, "secret-tool isn't installed"}

      path ->
        {out, status} =
          System.cmd(
            "sh",
            [
              "-c",
              ~s(printf '%s' "$TINY_AXE_SECRET" | exec "$0" store --label="$1" service tiny-axe key "$2"),
              path,
              "tiny-axe #{label}",
              key
            ],
            env: [{"TINY_AXE_SECRET", secret}],
            stderr_to_stdout: true
          )

        if status == 0, do: :ok, else: {:error, String.trim(out)}
    end
  end

  defp keyring_clear(key) do
    tool = Application.get_env(:tiny_axe, :secret_tool, "secret-tool")

    with path when path != nil <- System.find_executable(tool),
         do:
           System.cmd(path, ["clear", "service", "tiny-axe", "key", key], stderr_to_stdout: true)

    :ok
  end
end
