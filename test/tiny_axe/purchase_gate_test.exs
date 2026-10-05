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

      %{site: site, server: name}
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

  # Opens the checkout and clicks "Place order".
  defp buy(ctx, task, answer \\ :confirm, before \\ fn -> :ok end) do
    page = text(call(task, "#{ctx.server}__browser_navigate", %{url: ctx.site <> "/order"}))
    [_, ref] = Regex.run(~r/button "Place order" \[ref=(\w+)\]/, page)

    call(
      task,
      "#{ctx.server}__browser_click",
      %{ref: ref, element: "Place order"},
      answer,
      before
    )
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
end
