defmodule TinyAxe.CardsTest do
  @moduledoc """
  The card vault and `/credit-card`: what's typed, what's shown, what's kept
  and where, the PIN, the CVC, forgetting. A fake secret-tool stands in for
  the keyring (test/support/fake_secret_tool).
  """

  # The vault and purchases.json are app-wide, so not async.
  use ExUnit.Case, async: false

  alias TinyAxe.{Cards, Purchases, TUI}
  alias TinyAxe.TUI.CardFlow

  @moduletag :tmp_dir
  @number "4111 1111 1111 1111"

  setup %{tmp_dir: dir} do
    previous = Map.new([:purchases_config, :purchases], &{&1, Application.get_env(:tiny_axe, &1)})
    Application.put_env(:tiny_axe, :purchases_config, Path.join(dir, "purchases.json"))
    Application.put_env(:tiny_axe, :purchases, enabled: true, currency: "USD")
    File.rm_rf(Path.join(System.tmp_dir!(), "tiny_axe_fake_keyring"))

    on_exit(fn ->
      for c <- Cards.list(), do: Cards.forget(c.label)

      for {k, v} <- previous,
          do:
            if(v == nil,
              do: Application.delete_env(:tiny_axe, k),
              else: Application.put_env(:tiny_axe, k, v)
            )
    end)
  end

  defp type(field, text),
    do: text |> String.graphemes() |> Enum.reduce("", fn ch, _ -> Cards.entry_key(field, ch) end)

  defp enter_card(opts \\ []) do
    Cards.start_entry()
    type(:number, Keyword.get(opts, :number, @number))
    type(:exp, Keyword.get(opts, :exp, "12/30"))
    type(:cvc, Keyword.get(opts, :cvc, "737"))
    type(:name, "Sam Lee")
    if pin = opts[:pin], do: type(:pin, pin) && type(:pin_again, pin)
  end

  defp save(answers),
    do:
      Cards.save(
        Map.merge(
          %{"label" => "Test Visa", "purpose" => "books", "remember" => "7d", "cvc" => "stored"},
          answers
        )
      )

  defp fake_keyring_files,
    do: Path.wildcard(Path.join([System.tmp_dir!(), "tiny_axe_fake_keyring", "*"]))

  describe "entry" do
    test "the number shows only its last 4; the CVC and PIN never show" do
      Cards.start_entry()
      assert type(:number, @number) == "•••• •••• •••• 1111"
      assert type(:cvc, "737") == "•••"
      assert type(:pin, "4821") == "••••"
      assert type(:exp, "12/30") == "12/30"
      # Letters don't go into a number.
      assert Cards.entry_key(:number, "x") == "•••• •••• •••• 1111"
    end

    test "a number must pass the Luhn check, and the card mustn't have expired" do
      Cards.start_entry()
      type(:number, "4111 1111 1111 1112")
      assert {:error, "that isn't a valid card number" <> _} = Cards.entry_check(:number)

      Cards.start_entry()
      type(:exp, "01/20")
      assert {:error, "that card has expired"} = Cards.entry_check(:exp)

      Cards.start_entry()
      type(:exp, "13/30")
      assert {:error, "the expiry is MM/YY" <> _} = Cards.entry_check(:exp)

      Cards.start_entry()
      type(:number, @number)
      assert Cards.entry_summary() == %{brand: "Visa", last4: "1111"}
    end
  end

  describe "remembering" do
    test "this session only: in memory, never written anywhere" do
      enter_card()
      {:ok, card} = save(%{"remember" => "session"})

      assert card.keyring == nil
      assert [%{label: "Test Visa"}] = Cards.list()
      refute File.exists?(Purchases.config_path())
      assert fake_keyring_files() == []
    end

    test "for some days: the details go to the keyring, only a description to purchases.json" do
      enter_card()
      {:ok, card} = save(%{"remember" => "7d", "shops" => "shop.example"})

      json = File.read!(Purchases.config_path())
      refute json =~ "4111"
      refute json =~ "737"
      assert %{"last4" => "1111", "per_purchase_max" => nil} = hd(JSON.decode!(json)["cards"])
      assert card.merchants == ["shop.example"]

      {:ok, expires, _} = DateTime.from_iso8601(card.expires_at)
      assert DateTime.diff(expires, DateTime.utc_now(), :day) in 6..7

      assert [file] = fake_keyring_files()
      assert File.read!(file) =~ "4111111111111111"
    end

    test "a PIN encrypts the details: the keyring holds no number, and the PIN unlocks it" do
      enter_card(pin: "4821")
      {:ok, card} = save(%{})

      assert [file] = fake_keyring_files()
      refute File.read!(file) =~ "4111"
      assert Cards.needs(card) == [:pin]

      ref = make_ref()
      for ch <- String.graphemes("4821"), do: Cards.unlock_key(ref, :pin, ch)
      assert {:ok, %{"number" => "4111111111111111", "cvc" => "737"}} = Cards.details(card, ref)

      # What was typed is forgotten after one use.
      assert {:error, "the card is locked with a PIN, and none was typed"} =
               Cards.details(card, ref)

      wrong = make_ref()
      for ch <- String.graphemes("0000"), do: Cards.unlock_key(wrong, :pin, ch)
      assert {:error, "the PIN didn't unlock the card"} = Cards.details(card, wrong)
    end

    test "a CVC asked each time is never stored, and is needed to pay" do
      Cards.start_entry()
      type(:number, @number)
      type(:exp, "12/30")
      {:ok, card} = save(%{"cvc" => "ask"})

      assert Cards.needs(card) == [:cvc]
      assert [file] = fake_keyring_files()
      refute File.read!(file) =~ ~s("cvc")

      assert {:error, "the CVC wasn't typed"} = Cards.details(card, make_ref())

      ref = make_ref()
      for ch <- String.graphemes("123"), do: Cards.unlock_key(ref, :cvc, ch)
      assert {:ok, %{"cvc" => "123"}} = Cards.details(card, ref)
    end

    test "a card past its time is wiped from the keyring and purchases.json" do
      enter_card()
      {:ok, card} = save(%{})

      Purchases.update_file(fn json ->
        Map.update!(json, "cards", fn cards ->
          Enum.map(cards, &Map.put(&1, "expires_at", "2020-01-01T00:00:00Z"))
        end)
      end)

      assert [note] = Cards.expire_due()
      assert note =~ "forgot Test Visa (Visa ••1111)"
      assert Cards.list() == []
      assert fake_keyring_files() == []
      refute Cards.available?(card)
    end

    test "forget wipes a card" do
      enter_card()
      {:ok, _} = save(%{})
      assert :ok = Cards.forget("Test Visa")
      assert Cards.list() == [] and fake_keyring_files() == []
      assert Cards.forget("Test Visa") == {:error, :not_found}
    end
  end

  test "the vault's state never shows in a crash report or :sys.get_status" do
    enter_card()
    assert {:status, _, _, [_, _, _, _, status]} = :sys.get_status(TinyAxe.Cards)
    refute inspect(status, limit: :infinity) =~ "4111"
  end

  describe "/credit-card" do
    defp keys(flow, keys) do
      Enum.reduce(keys, flow, fn k, flow ->
        {:cont, flow} = CardFlow.key(flow, k)
        flow
      end)
    end

    defp chars(text), do: String.graphemes(text)

    test "asks its questions, saves the card, and nothing in the TUI holds the number" do
      {:ok, state} = TUI.mount(test_mode: {120, 40})
      ExRatatui.textarea_set_value(state.input, "/credit-card")

      {:noreply, state} =
        TUI.handle_event(%ExRatatui.Event.Key{code: "enter", kind: "press", modifiers: []}, state)

      assert state.card_flow != nil

      flow =
        state.card_flow
        |> keys(chars(@number) ++ ["enter"])
        |> keys(chars("12/30") ++ ["enter"])
        # Ask for the CVC each time: the CVC step is skipped.
        |> keys(["a"])
        |> keys(chars("Sam Lee") ++ ["enter"])
        |> keys(chars("Books Visa") ++ ["enter"])
        |> keys(chars("books and stationery") ++ ["enter"])
        |> keys(chars("bookshop.org") ++ ["enter"])
        |> keys(["3"])
        |> keys(chars("30") ++ ["enter"])
        |> keys(["enter"])
        |> keys(chars("4821") ++ ["enter"])
        |> keys(chars("4821") ++ ["enter"])

      {name, :choice, _} = CardFlow.step(flow)
      assert name == :confirm
      refute inspect(flow, limit: :infinity) =~ "4111"
      refute inspect(flow, limit: :infinity) =~ "4821"
      assert "Card: Visa ending 1111" in CardFlow.summary_lines(flow)

      {:done, message} = CardFlow.key(flow, "y")

      assert message =~
               "saved Books Visa (Visa ••1111) for 7 day(s); locked with a PIN, CVC asked each time, ≤ 30.0 a purchase"

      assert [card] = Cards.list()
      assert card.purpose == "books and stationery" and card.merchants == ["bookshop.org"]
      assert card.pin and card.cvc == "ask" and card.per_purchase_max == 30.0
    end

    test "a wrong number is caught at once, and esc discards everything" do
      flow = CardFlow.new() |> keys(chars("4111 1111 1111 1112") ++ ["enter"])
      assert flow.error =~ "isn't a valid card number"

      assert {:cancel, "card entry cancelled; nothing was saved"} = CardFlow.key(flow, "esc")
      assert Cards.list() == []
    end

    test "a pasted number goes to the vault, shown masked" do
      flow = CardFlow.paste(CardFlow.new(), @number)
      assert flow.display == "•••• •••• •••• 1111"
      refute inspect(flow) =~ "4111"
    end

    test "/credit-card list and forget" do
      enter_card()
      {:ok, _} = save(%{"remember" => "session"})
      {:ok, state} = TUI.mount(test_mode: {120, 40})

      run = fn state, text ->
        ExRatatui.textarea_set_value(state.input, text)

        {:noreply, state} =
          TUI.handle_event(
            %ExRatatui.Event.Key{code: "enter", kind: "press", modifiers: []},
            state
          )

        state
      end

      state = run.(state, "/credit-card list")

      assert {:meta, "💳 Test Visa (Visa ••1111) · this session only · for books"} in state.transcript

      state = run.(state, "/credit-card forget Test Visa")

      assert List.last(state.transcript) ==
               {:meta, "💳 forgot Test Visa: wiped from tiny-axe and your keyring"}

      assert Cards.list() == []
    end
  end
end
