defmodule TinyAxe.PurchaseGateTest do
  @moduledoc """
  Buying through the gate, end to end, on the fixture site's checkout with the
  real Chrome headless. The site records what it receives, so each test can
  check whether an order was actually placed.
  """

  use ExUnit.Case, async: false

  alias TinyAxe.{Browser, Decider, FixtureSite, MCP, Purchases}
  alias TinyAxe.Tools.Gate

  @moduletag :browser
  @moduletag :tmp_dir
  @moduletag timeout: 180_000

  @intent %{request: "buy the blue mug, under $50", max: 50.0, currency: "USD"}
  @fake Path.expand("../support/fake_mcp/server", __DIR__)

  setup_all do
    if Browser.available?() do
      site = FixtureSite.start()
      name = "browser-buy-#{System.unique_integer([:positive])}"

      profile =
        Path.join(System.tmp_dir!(), "tiny_axe_buy_profile_#{System.unique_integer([:positive])}")

      {:ok, _} =
        MCP.start_server(name, Browser.config(profile: profile, headless: true, no_window: true))

      on_exit(fn ->
        MCP.stop_server(name)
        File.rm_rf(profile)
      end)

      # The browser server's log, to check card numbers never reach it.
      log = Path.join([TinyAxe.Ops.Journal.state_dir(), "mcp", "#{name}.log"])
      %{site: site, server: name, server_log: log}
    else
      {:skip, "Node, Playwright or Chrome isn't available"}
    end
  end

  setup %{tmp_dir: dir} do
    keys = [:purchases, :decider, :script_decider, :state_dir]
    previous = Map.new(keys, &{&1, Application.get_env(:tiny_axe, &1)})
    limits(per_order_max: 100.0, daily_max: 200.0)
    Application.put_env(:tiny_axe, :state_dir, dir)

    Decider.Script.script(fn
      :matches, _, _ -> 0.9
      _, _, _ -> nil
    end)

    FixtureSite.clear()
    FixtureSite.set_price(12.0)

    on_exit(fn ->
      for {k, v} <- previous,
          do:
            if(v == nil,
              do: Application.delete_env(:tiny_axe, k),
              else: Application.put_env(:tiny_axe, k, v)
            )
    end)
  end

  defp limits(opts),
    do:
      Application.put_env(
        :tiny_axe,
        :purchases,
        Keyword.merge([enabled: true, currency: "USD", merchants: :any], opts)
      )

  defp open_task(ctx, intent, servers \\ nil) do
    me = self()

    {:ok, task} =
      Gate.open_task(&send(me, {:gate, &1}), servers: servers || [ctx.server], intent: intent)

    on_exit(fn -> Gate.close_task(task.id) end)
    task
  end

  # One call through the gate. `answer` replies to a purchase approval; `before`
  # runs first (to change the page while the user "decides").
  defp call(task, name, args, answer \\ :deny, before \\ fn -> :ok end) do
    caller =
      Task.async(fn ->
        Req.post!(task.url,
          json: %{
            jsonrpc: "2.0",
            id: 1,
            method: "tools/call",
            params: %{name: name, arguments: args}
          },
          headers: %{"authorization" => "Bearer #{task.token}"},
          receive_timeout: 90_000,
          retry: false
        ).body["result"]
      end)

    await(caller, answer, before)
  end

  defp await(caller, answer, before) do
    receive do
      {:gate, {:purchase_approval, ask}} ->
        send(self(), {:asked, ask})
        before.()
        send(ask.reply_to, {:purchase_answer, ask.ref, answer})
        await(caller, answer, before)

      {ref, result} when ref == caller.ref ->
        Process.demonitor(ref, [:flush])
        result
    after
      90_000 -> flunk("the call never finished")
    end
  end

  defp text(%{"content" => content}),
    do: content |> Enum.filter(&(&1["type"] == "text")) |> Enum.map_join("\n", & &1["text"])

  # Opens a checkout and clicks "Place order".
  defp buy(ctx, task, answer \\ :confirm, before \\ fn -> :ok end, path \\ "/order") do
    page = text(call(task, "#{ctx.server}__browser_navigate", %{url: ctx.site <> path}))
    [_, ref] = Regex.run(~r/button "Place order" \[ref=(\w+)\]/, page)

    call(
      task,
      "#{ctx.server}__browser_click",
      %{ref: ref, element: "Place order"},
      answer,
      before
    )
  end

  # Clicks "Place order" on the page as it is (without loading it again).
  defp place_order(ctx, task, answer \\ :confirm) do
    page = text(call(task, "#{ctx.server}__browser_snapshot", %{}))
    [_, ref] = Regex.run(~r/button "Place order" \[ref=(\w+)\]/, page)
    call(task, "#{ctx.server}__browser_click", %{ref: ref, element: "Place order"}, answer)
  end

  defp placed, do: for({"/place-order", _} <- FixtureSite.submissions(), do: :order)

  defp journal do
    [id] = File.ls!(Purchases.dir())
    {id, Enum.map(Purchases.events(id), & &1["t"])}
  end

  test "the user sees what code read from the page, types the total, and the order is placed",
       ctx do
    result = buy(ctx, open_task(ctx, @intent))

    assert_received {:asked, %{summary: s, checks: checks}}
    assert s["host"] == "127.0.0.1"
    assert s["total"] == 16.0 and s["total_text"] == "$16.00"
    assert "Blue mug × 1 — $12.00" in s["items"]
    assert s["ship_to"] =~ "Sam Lee"
    assert s["payment"] == "Paying with Visa ending in 4242"
    assert Enum.all?(checks, &match?({:ok, _}, &1))

    assert placed() == [:order]
    assert text(result) =~ "tiny-axe placed the order after the user confirmed it; order TA-1001."
    assert_received {:gate, {:purchased, %{order: "TA-1001", total_text: "$16.00"}}}

    {id, events} = journal()
    assert events == ~w(intent summary confirmed clicking clicked receipt)
    assert File.read!(Path.join(Purchases.dir(id), "receipt.txt")) =~ "Order number: TA-1001"

    assert <<137, 80, 78, 71, _::binary>> =
             File.read!(Path.join(Purchases.dir(id), "receipt.png"))
  end

  test "the user says no: nothing is bought", ctx do
    result = buy(ctx, open_task(ctx, @intent), :deny)

    assert text(result) =~ "the user didn't confirm the purchase"
    assert placed() == []
    assert {_, ~w(intent summary declined)} = journal()
  end

  test "over the user's maximum: refused without asking, nothing bought", ctx do
    result = buy(ctx, open_task(ctx, %{@intent | max: 10.0}))

    refute_received {:asked, _}
    assert text(result) =~ "$16.00 is over your maximum of $10.00"
    assert_received {:gate, {:purchase_refused, _}}
    assert placed() == []
  end

  test "no maximum given: the agent is told to ask the user for one", ctx do
    result = buy(ctx, open_task(ctx, %{@intent | max: nil}))
    assert text(result) =~ "Ask the user the most they want to spend"
    assert placed() == []
  end

  test "the user never asked to buy anything: refused", ctx do
    result = buy(ctx, open_task(ctx, nil))
    assert text(result) =~ "you didn't ask to buy anything"
    assert placed() == []
  end

  test "the daily limit counts what was already bought today", ctx do
    limits(per_order_max: 100.0, daily_max: 20.0)
    task = open_task(ctx, @intent)

    buy(ctx, task)
    assert placed() == [:order]

    result = buy(ctx, task)
    assert text(result) =~ "$16.00 already today; this would pass the $20.00 daily limit"
    assert placed() == [:order]
  end

  test "items Jev says weren't asked for: refused", ctx do
    Decider.Script.script(fn _, _, _ -> 0.1 end)
    result = buy(ctx, open_task(ctx, @intent))
    assert text(result) =~ "the items don't look like what you asked for"
    assert placed() == []
  end

  test "the total changes while the user decides: nothing is clicked", ctx do
    change = fn ->
      FixtureSite.set_price(22.0)
      # The page picks up the new price within 200 ms.
      Process.sleep(700)
    end

    result = buy(ctx, open_task(ctx, @intent), :confirm, change)

    assert text(result) =~ "the total changed from $16.00 to $26.00"
    assert placed() == []
    assert {_, ~w(intent summary confirmed changed)} = journal()
  end

  test "purchases switched off: refused, as before", ctx do
    Application.put_env(:tiny_axe, :purchases, enabled: false)
    result = buy(ctx, open_task(ctx, @intent))
    assert text(result) =~ "spending money isn't enabled"
    assert placed() == []
  end

  test "only tiny-axe's browser can buy: another server's money tool is refused", ctx do
    name = "money#{System.unique_integer([:positive])}"

    {:ok, _} =
      MCP.start_server(name, %{"command" => @fake, "policy" => %{"commit" => ["send_note"]}})

    on_exit(fn -> MCP.stop_server(name) end)

    task = open_task(ctx, @intent, [name])
    result = call(task, "#{name}__send_note", %{to: "shop", text: "pay"})
    assert text(result) =~ "only tiny-axe's browser can buy things"
  end

  describe "payment" do
    @card_number "4111 1111 1111 1111"

    defp cards(cards), do: limits(per_order_max: 100.0, daily_max: 200.0, cards: cards)

    defp gate_events do
      receive do
        {:gate, e} -> [e | gate_events()]
      after
        0 -> []
      end
    end

    test "a card saved at the shop: the chosen one is shown; choosing another is local", ctx do
      task = open_task(ctx, @intent)

      page =
        text(call(task, "#{ctx.server}__browser_navigate", %{url: ctx.site <> "/order-saved"}))

      # Choosing the Visa: a radio button, so it just runs.
      [_, visa] = Regex.run(~r/radio "Visa ending in 4242" \[ref=(\w+)\]/, page)
      call(task, "#{ctx.server}__browser_click", %{ref: visa})
      refute_received {:gate, {:tool_approval, _}}

      place_order(ctx, task)
      assert_received {:asked, %{summary: %{"paying_with" => "Visa ending in 4242"}}}
      assert placed() == [:order]
    end

    test "card fields and no virtual card: refused; tiny-axe never types card details", ctx do
      result = buy(ctx, open_task(ctx, @intent), :confirm, fn -> :ok end, "/order-card")
      assert text(result) =~ "the page needs card details, which tiny-axe never types"
      assert placed() == []
    end

    test "a virtual card is filled in only after the user confirms, and is seen nowhere else",
         ctx do
      cards([%{label: "Test virtual card", keyring: "card-test", merchants: :any}])
      result = buy(ctx, open_task(ctx, @intent), :confirm, fn -> :ok end, "/order-card")

      assert_received {:asked, %{summary: %{"paying_with" => paying}}}
      assert paying =~ "Test virtual card (a virtual card"
      assert text(result) =~ "tiny-axe placed the order"

      # It reached the shop…
      assert [{"/place-order", %{"ccnumber" => @card_number, "cvc" => "737", "ccexp" => "12/30"}}] =
               FixtureSite.submissions()

      # …and nowhere else: not the transcript's events, the result, the purchase
      # journal and receipt, the tool journal, or the browser server's log.
      {id, events} = journal()
      assert "card_filled" in events
      refute inspect(gate_events(), limit: :infinity) =~ "4111"
      refute inspect(result, limit: :infinity) =~ "4111"

      for file <- File.ls!(Purchases.dir(id)),
          file != "receipt.png",
          do: refute(File.read!(Path.join(Purchases.dir(id), file)) =~ "4111", file)

      for dir <- Path.wildcard(Path.join(TinyAxe.Ops.Journal.state_dir(), "tasks/*")),
          do: refute(File.read!(Path.join(dir, "calls.jsonl")) =~ "4111")

      if File.exists?(ctx.server_log), do: refute(File.read!(ctx.server_log) =~ "4111")
    end

    test "a virtual card only for other shops isn't used", ctx do
      cards([%{label: "Test virtual card", keyring: "card-test", merchants: ["other.example"]}])
      result = buy(ctx, open_task(ctx, @intent), :confirm, fn -> :ok end, "/order-card")
      assert text(result) =~ "needs card details"
      assert placed() == []
    end

    test "card details the user typed themselves (a handoff) are paid with", ctx do
      task = open_task(ctx, @intent)
      call(task, "#{ctx.server}__browser_navigate", %{url: ctx.site <> "/order-card"})

      # The user fills the card in the browser window.
      {:ok, _} =
        MCP.call(ctx.server, "browser_fill_card", %{
          "expect_host" => "127.0.0.1",
          "card" => %{
            "number" => @card_number,
            "exp_month" => "1",
            "exp_year" => "2031",
            "cvc" => "123"
          }
        })

      place_order(ctx, task)
      assert_received {:asked, %{summary: %{"paying_with" => "the card details you entered"}}}
      assert placed() == [:order]
    end

    test "card filling refuses any shop but the one confirmed", ctx do
      task = open_task(ctx, @intent)
      call(task, "#{ctx.server}__browser_navigate", %{url: ctx.site <> "/order-card"})

      {:ok, result} =
        MCP.call(ctx.server, "browser_fill_card", %{
          "expect_host" => "shop.example",
          "card" => %{"number" => @card_number}
        })

      assert result["isError"] == true
      assert text(result) =~ "the page is on 127.0.0.1, not shop.example"
    end

    test "agents can't call the card filling", ctx do
      task = open_task(ctx, @intent)

      result =
        call(task, "#{ctx.server}__browser_fill_card", %{
          expect_host: "127.0.0.1",
          card: %{number: @card_number}
        })

      assert text(result) =~ "for tiny-axe only"
    end
  end

  describe "cards given with /credit-card" do
    alias TinyAxe.Cards

    setup do
      on_exit(fn -> for c <- Cards.list(), do: Cards.forget(c.label) end)
    end

    defp add_card(answers, pin \\ nil) do
      Cards.start_entry()

      for {field, text} <- [
            number: "4111 1111 1111 1111",
            exp: "12/30",
            cvc: "737",
            name: "Sam Lee"
          ],
          ch <- String.graphemes(text),
          do: Cards.entry_key(field, ch)

      if pin,
        do: for(f <- [:pin, :pin_again], ch <- String.graphemes(pin), do: Cards.entry_key(f, ch))

      {:ok, card} =
        Cards.save(
          Map.merge(
            %{
              "label" => "Test card",
              "purpose" => "household things",
              "remember" => "session",
              "cvc" => "stored"
            },
            answers
          )
        )

      card
    end

    # One call through the gate; `respond` gets each approval and returns the answer.
    defp call_with(task, name, args, respond) do
      caller =
        Task.async(fn ->
          Req.post!(task.url,
            json: %{
              jsonrpc: "2.0",
              id: 1,
              method: "tools/call",
              params: %{name: name, arguments: args}
            },
            headers: %{"authorization" => "Bearer #{task.token}"},
            receive_timeout: 90_000,
            retry: false
          ).body["result"]
        end)

      respond_loop(caller, respond)
    end

    defp respond_loop(caller, respond) do
      receive do
        {:gate, {:purchase_approval, ask}} ->
          send(self(), {:asked, ask})
          send(ask.reply_to, {:purchase_answer, ask.ref, respond.(ask)})
          respond_loop(caller, respond)

        {ref, result} when ref == caller.ref ->
          Process.demonitor(ref, [:flush])
          result
      after
        90_000 -> flunk("the call never finished")
      end
    end

    defp type_unlock(ask, field, text),
      do: for(ch <- String.graphemes(text), do: Cards.unlock_key(ask.ref, field, ch))

    defp click_button(ctx, task, path, label, respond) do
      page = text(call(task, "#{ctx.server}__browser_navigate", %{url: ctx.site <> path}))
      [_, ref] = Regex.run(~r/button "#{label}" \[ref=(\w+)\]/, page)
      call_with(task, "#{ctx.server}__browser_click", %{ref: ref}, respond)
    end

    test "a card locked with a PIN, its CVC asked each time: both typed at checkout, into the vault",
         ctx do
      Decider.Script.script(fn _, _, _ -> 0.9 end)
      add_card(%{"cvc" => "ask"}, "4821")
      Cards.start_entry()

      result =
        click_button(ctx, open_task(ctx, @intent), "/order-card", "Place order", fn ask ->
          assert ask.needs == [:pin, :cvc]
          type_unlock(ask, :pin, "4821")
          type_unlock(ask, :cvc, "999")
          :confirm
        end)

      assert text(result) =~ "tiny-axe placed the order"

      assert [{"/place-order", %{"ccnumber" => "4111111111111111", "cvc" => "999"}}] =
               FixtureSite.submissions()
    end

    test "a wrong PIN buys nothing", ctx do
      Decider.Script.script(fn _, _, _ -> 0.9 end)
      add_card(%{}, "4821")

      result =
        click_button(ctx, open_task(ctx, @intent), "/order-card", "Place order", fn ask ->
          type_unlock(ask, :pin, "0000")
          :confirm
        end)

      assert text(result) =~ "the PIN didn't unlock the card"
      assert placed() == []
    end

    test "a purchase that doesn't fit the card's purpose, or its own limit, is refused", ctx do
      Decider.Script.script(fn
        :fits, _, _ -> 0.1
        _, _, _ -> 0.9
      end)

      add_card(%{})

      result =
        click_button(ctx, open_task(ctx, @intent), "/order-card", "Place order", fn _ ->
          :confirm
        end)

      assert text(result) =~ "this doesn't look like what Test card is for (household things)"

      Decider.Script.script(fn _, _, _ -> 0.9 end)
      Cards.forget("Test card")
      add_card(%{"per_purchase_max" => 10.0})

      result =
        click_button(ctx, open_task(ctx, @intent), "/order-card", "Place order", fn _ ->
          :confirm
        end)

      assert text(result) =~ "over Test card's limit of $10.00 a purchase"
      assert placed() == []
    end

    test "filled in, the card shows as dots to anyone watching the window", ctx do
      task = open_task(ctx, @intent)
      call(task, "#{ctx.server}__browser_navigate", %{url: ctx.site <> "/order-card"})

      {:ok, _} =
        MCP.call(ctx.server, "browser_fill_card", %{
          "expect_host" => "127.0.0.1",
          "card" => %{"number" => "4111111111111111"}
        })

      assert Enum.any?(1..20, fn _ ->
               Process.sleep(100)

               text(call(task, "#{ctx.server}__browser_extract", %{})) =~
                 "number field shows: dots"
             end)
    end

    test "a form that would send the card over plain http isn't filled, and nothing is bought",
         ctx do
      Decider.Script.script(fn _, _, _ -> 0.9 end)
      add_card(%{})

      result =
        click_button(ctx, open_task(ctx, @intent), "/order-insecure", "Place order", fn _ ->
          :confirm
        end)

      assert text(result) =~ "couldn't be filled in"
      assert FixtureSite.submissions() == []
    end

    test "a two-step checkout: the card step asks to fill it in, the order is bought once, under the card's rules",
         ctx do
      Decider.Script.script(fn _, _, _ -> 0.9 end)
      add_card(%{"per_purchase_max" => 50.0})
      task = open_task(ctx, @intent)

      result =
        click_button(ctx, task, "/pay-step", "Continue", fn %{mode: :card_step} -> :confirm end)

      assert_received {:asked, %{mode: :card_step}}
      assert text(result) =~ "Review your order"
      assert [{"/pay-step", %{"ccnumber" => "4111111111111111"}}] = FixtureSite.submissions()

      page = text(call(task, "#{ctx.server}__browser_snapshot", %{}))
      [_, ref] = Regex.run(~r/button "Place order" \[ref=(\w+)\]/, page)

      call_with(task, "#{ctx.server}__browser_click", %{ref: ref}, fn ask ->
        assert ask.mode == :order
        assert {:ok, "within Test card's $50.00 a purchase"} in ask.checks
        :confirm
      end)

      assert placed() == [:order]
      # Spent once, not twice.
      assert Purchases.spent_today("USD") == 16.0
    end

    test "Chrome never saves cards, and is driven only over a private pipe", ctx do
      _ = ctx
      profiles = Path.wildcard(Path.join(System.tmp_dir!(), "tiny_axe_buy_profile_*"))

      assert Enum.any?(profiles, fn p ->
               case File.read(Path.join([p, "Default", "Preferences"])) do
                 {:ok, raw} ->
                   get_in(JSON.decode!(raw), ["autofill", "credit_card_enabled"]) == false

                 _ ->
                   false
               end
             end)

      chrome =
        for pid <- File.ls!("/proc"),
            pid =~ ~r/\A\d+\z/,
            {:ok, cmd} <- [File.read("/proc/#{pid}/cmdline")],
            cmd =~ "tiny_axe_buy_profile_",
            cmd =~ "--user-data-dir",
            do: cmd

      # The browser is driven over a pipe; no process listens on a debugging port
      # another program could attach to (Chrome's helper processes have neither).
      assert chrome != []
      assert Enum.any?(chrome, &(&1 =~ "--remote-debugging-pipe"))
      refute Enum.any?(chrome, &(&1 =~ "--remote-debugging-port"))
    end
  end
end
