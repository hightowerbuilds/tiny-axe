defmodule TinyAxe.PurchasesTest do
  @moduledoc "The purchase gate's own logic: intent, checks, the journal. No browser."

  # Swaps app-wide settings (purchases, decider, state folder), so not async.
  use ExUnit.Case, async: false

  alias TinyAxe.{Decider, Purchases}

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    keys = [:purchases, :decider, :script_decider, :state_dir]
    previous = Map.new(keys, &{&1, Application.get_env(:tiny_axe, &1)})

    Application.put_env(:tiny_axe, :purchases,
      enabled: true,
      per_order_max: 100.0,
      daily_max: 200.0,
      currency: "USD",
      merchants: :any
    )

    Application.put_env(:tiny_axe, :state_dir, dir)

    Decider.Script.script(fn
      :buy, _, _ -> 0.9
      :matches, _, _ -> 0.9
      _, _, _ -> nil
    end)

    on_exit(fn ->
      for {k, v} <- previous,
          do:
            if(v == nil,
              do: Application.delete_env(:tiny_axe, k),
              else: Application.put_env(:tiny_axe, k, v)
            )
    end)
  end

  @summary %{
    "host" => "shop.example",
    "total" => 16.0,
    "total_text" => "$16.00",
    "currency" => "USD",
    "items" => ["Blue mug × 1 — $12.00"],
    "payment" => "Visa ending in 4242"
  }
  @intent %{request: "buy the blue mug, under $50", max: 50.0, currency: "USD"}

  describe "intent" do
    test "the most to spend comes from the user's own words" do
      assert Purchases.max_price("buy a mug under $50") == {50.0, "USD"}
      assert Purchases.max_price("no more than £30 please") == {30.0, "GBP"}
      assert Purchases.max_price("with a budget of 25 euros") == {25.0, "EUR"}
      assert Purchases.max_price("up to 19.99 dollars") == {19.99, "USD"}
      assert Purchases.max_price("max $7,50") == {7.5, "USD"}
      assert Purchases.max_price("buy me a mug") == {nil, nil}
    end

    test "only a request to buy has an intent; without a maximum it can't be met" do
      assert %{max: 50.0, currency: "USD"} = Purchases.intent("buy the blue mug, under $50")
      assert %{max: nil} = Purchases.intent("buy the blue mug")

      Decider.Script.script(fn _, _, _ -> nil end)
      assert Purchases.intent("what mugs are there?") == nil

      # Jev unavailable: no intent, so nothing can be bought.
      Decider.Script.script(fn _, _, _ -> :unknown end)
      assert Purchases.intent("buy the blue mug, under $50") == nil
    end

    test "purchases switched off: never an intent" do
      Application.put_env(:tiny_axe, :purchases, enabled: false)
      assert Purchases.intent("buy the blue mug, under $50") == nil
    end
  end

  describe "checks" do
    defp failed(intent, summary),
      do: for({:fail, why} <- Purchases.checks(intent, summary), do: why)

    test "a summary within every limit passes" do
      assert failed(@intent, @summary) == []
    end

    test "over the user's maximum, the per-order cap, or another currency fails" do
      assert ["$16.00 is over your maximum of $10.00"] = failed(%{@intent | max: 10.0}, @summary)

      Application.put_env(:tiny_axe, :purchases,
        enabled: true,
        per_order_max: 15.0,
        daily_max: 200.0,
        currency: "USD"
      )

      assert ["over the $15.00 limit per order"] = failed(@intent, @summary)

      Application.put_env(:tiny_axe, :purchases,
        enabled: true,
        per_order_max: 100.0,
        daily_max: 200.0,
        currency: "USD"
      )

      assert [why] = failed(%{@intent | currency: "GBP", max: 99.0}, @summary)
      assert why =~ "in USD, you asked in GBP"
    end

    test "no intent, no maximum, or no total read from the page fails" do
      assert "you didn't ask to buy anything in this request" in failed(nil, @summary)

      assert "you didn't say the most to spend (e.g. \"under $50\")" in failed(
               %{@intent | max: nil},
               @summary
             )

      assert "tiny-axe couldn't read the total on the page" in failed(
               @intent,
               Map.put(@summary, "total", nil)
             )
    end

    test "Jev must agree the items are what was asked for; no answer fails" do
      Decider.Script.script(fn _, _, _ -> 0.1 end)
      assert ["the items don't look like what you asked for"] = failed(@intent, @summary)

      Decider.Script.script(fn _, _, _ -> :unknown end)

      assert ["tiny-axe couldn't check the items against your request"] =
               failed(@intent, @summary)
    end

    test "a shop list, when there is one" do
      Application.put_env(:tiny_axe, :purchases,
        enabled: true,
        currency: "USD",
        merchants: ["other.example"]
      )

      assert ["shop.example isn't on your list of shops"] = failed(@intent, @summary)
    end
  end

  describe "the journal" do
    test "today's spending counts only purchases that were clicked" do
      clicked = Purchases.start(@intent)
      Purchases.event(clicked, %{t: "summary", summary: @summary})
      Purchases.event(clicked, %{t: "clicking"})

      declined = Purchases.start(@intent)
      Purchases.event(declined, %{t: "summary", summary: @summary})
      Purchases.event(declined, %{t: "declined"})

      assert Purchases.spent_today("USD") == 16.0
      assert Purchases.spent_today("GBP") == 0.0
    end

    test "an order clicked without a receipt is reported once, and never clicked again" do
      id = Purchases.start(@intent)
      Purchases.event(id, %{t: "summary", summary: @summary})
      Purchases.event(id, %{t: "clicking"})

      assert [note] = Purchases.uncertain()
      assert note =~ "an order may have been placed at shop.example for $16.00"
      assert note =~ "it won't be placed again"
      assert Purchases.uncertain() == []

      done = Purchases.start(@intent)
      Purchases.event(done, %{t: "clicking"})
      Purchases.event(done, %{t: "receipt", order: "X1"})
      assert Purchases.uncertain() == []
    end
  end

  describe "payment" do
    @card [label: "Test virtual card", keyring: "card-test", merchants: :any]

    defp with_cards(cards),
      do:
        Application.put_env(:tiny_axe, :purchases,
          enabled: true,
          currency: "USD",
          merchants: :any,
          cards: cards
        )

    test "a card saved at the shop, as the page shows it" do
      assert Purchases.payment(
               %{@summary | "items" => []}
               |> Map.put("payment", "Visa ending in 4242")
             ) ==
               {:saved, "Visa ending in 4242"}
    end

    test "card fields the user filled in themselves" do
      assert {:entered, _} =
               Purchases.payment(
                 Map.merge(@summary, %{"card_fields" => 4, "card_fields_empty" => false})
               )
    end

    test "empty card fields: a virtual card from the keyring, if one is allowed at this shop" do
      empty = Map.merge(@summary, %{"card_fields" => 4, "card_fields_empty" => true})

      assert {:none, why} = Purchases.payment(empty)
      assert why =~ "never types"

      with_cards([Map.new(@card)])

      assert {:virtual,
              %{label: "Test virtual card", details: %{"number" => "4111 1111 1111 1111"}}} =
               Purchases.payment(empty)

      assert Purchases.paying_with(empty) =~
               "Test virtual card (a virtual card; tiny-axe fills it in after you confirm)"

      # Only at the shops it's for.
      with_cards([Map.new(Keyword.put(@card, :merchants, ["other.example"]))])
      assert {:none, _} = Purchases.payment(empty)

      # Not in the keyring: no card.
      with_cards([Map.new(Keyword.put(@card, :keyring, "missing"))])
      assert {:none, _} = Purchases.payment(empty)
    end

    test "no way to pay that tiny-axe can see fails the checks" do
      unpaid = Map.delete(@summary, "payment")
      assert {:none, _} = Purchases.payment(unpaid)

      assert "tiny-axe can't see how this would be paid" in for(
               {:fail, w} <- Purchases.checks(@intent, unpaid),
               do: w
             )
    end
  end
end
