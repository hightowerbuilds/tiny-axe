defmodule TinyAxe.ChromePurchaseTest do
  @moduledoc """
  Buying in the user's Chrome (docs/plan-chrome-purchases.md, P2), through
  the gate over HTTP, with Claude Code's side played by the test: permission
  questions to `chrome_permission`, results to `POST /hook/<task>`, shaped as
  P0 saw them.
  """

  use ExUnit.Case, async: false

  alias TinyAxe.{Decider, Purchases}
  alias TinyAxe.Chrome.Checkout
  alias TinyAxe.Tools.Gate

  @moduletag :tmp_dir
  @c "mcp__claude-in-chrome__"
  @url "https://shop.example/checkout"
  @intent %{request: "buy the blue mug, under $50", max: 50.0, currency: "USD"}
  @checkout """
  Review your order
  Blue mug × 1 — $12.00
  Shipping: $4.00
  Order total: $16.00
  Ship to:
  Sam Lee
  1 High St, Springfield
  Payment
  Mastercard ending in 5555
  Place order
  """

  setup %{tmp_dir: dir} do
    keys = [:purchases, :decider, :script_decider, :state_dir]
    previous = Map.new(keys, &{&1, Application.get_env(:tiny_axe, &1)})
    limits(per_order_max: 100.0, daily_max: 200.0)
    Application.put_env(:tiny_axe, :state_dir, dir)

    Decider.Script.script(fn
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

  defp limits(opts),
    do:
      Application.put_env(
        :tiny_axe,
        :purchases,
        Keyword.merge([enabled: true, currency: "USD", merchants: :any], opts)
      )

  defp open(intent \\ @intent) do
    me = self()

    {:ok, task} =
      Gate.open_task(&send(me, {:gate, &1}), servers: [], chrome: true, intent: intent)

    on_exit(fn -> Gate.close_task(task.id) end)
    Gate.driven_by(task.id, {:claude, "claude-haiku-5-5"})
    task
  end

  defp tab_context(url),
    do: [
      %{
        "type" => "text",
        "text" =>
          "\n\nTab Context:\n- Executed on tabId: 7\n- Available tabs:\n  • tabId 7: \"Checkout\" (\"#{url}\")"
      }
    ]

  defp hook(task, tool, input, response) do
    204 =
      Req.post!(task.hook_url,
        json: %{"tool_name" => @c <> tool, "tool_input" => input, "tool_response" => response},
        headers: %{"authorization" => "Bearer #{task.token}"},
        retry: false
      ).status
  end

  # As Claude Code does: the permission question, then the result.
  defp read(task, text, url \\ @url) do
    ask(task, "get_page_text", %{"tabId" => 7})

    hook(
      task,
      "get_page_text",
      %{"tabId" => 7},
      [%{"type" => "text", "text" => "Title: Checkout\nURL: #{url}\n---\n#{text}"}] ++
        tab_context(url)
    )
  end

  defp ask(task, tool, input) do
    Req.post!(task.url,
      json: %{
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: %{name: "chrome_permission", arguments: %{tool_name: @c <> tool, input: input}}
      },
      headers: %{"authorization" => "Bearer #{task.token}"},
      retry: false
    ).body["result"]
  end

  defp find_button(task),
    do:
      hook(
        task,
        "find",
        %{"tabId" => 7},
        [%{"type" => "text", "text" => "- ref_16: button \"\"Place order\"\" (button)"}] ++
          tab_context(@url)
      )

  @click %{"action" => "left_click", "ref" => "ref_16", "tabId" => 7}

  # Claude Code's permission question for the click, answering the purchase
  # popup with `answer` (:confirm, :deny) if it comes up.
  defp click(task, answer \\ nil) do
    caller =
      Task.async(fn ->
        Req.post!(task.url,
          json: %{
            jsonrpc: "2.0",
            id: 1,
            method: "tools/call",
            params: %{
              name: "chrome_permission",
              arguments: %{tool_name: @c <> "computer", input: @click}
            }
          },
          headers: %{"authorization" => "Bearer #{task.token}"},
          retry: false
        ).body["result"]
      end)

    wait(caller, answer)
  end

  defp wait(caller, answer) do
    receive do
      {:gate, {:purchase_approval, ask}} ->
        if answer, do: send(ask.reply_to, {:purchase_answer, ask.ref, answer})
        send(self(), {:popup, ask})
        wait(caller, answer)

      {ref, %{"content" => [%{"text" => text}]}} when ref == caller.ref ->
        Process.demonitor(ref, [:flush])
        JSON.decode!(text)
    after
      5_000 -> flunk("no answer")
    end
  end

  defp journal(id), do: for(e <- Purchases.events(id), do: e["t"])

  test "the checkout summary, read in code from the page's text" do
    s = Checkout.summary("Title: Checkout\nURL: #{@url}\n---\n" <> @checkout, @url)
    assert s["host"] == "shop.example"
    assert s["total"] == 16.0 and s["total_text"] == "$16.00" and s["currency"] == "USD"
    assert s["items"] == ["Blue mug × 1 — $12.00"]
    assert s["ship_to"] =~ "Sam Lee"
    assert s["payment"] == "Mastercard ending in 5555"

    page =
      String.replace(
        @checkout,
        "Mastercard ending in 5555",
        "Visa ending in 4242 Mastercard ending in 5555"
      )

    two = Checkout.summary(page, @url)
    assert two["payment"] == nil
    assert two["cards"] == ["Visa ending in 4242", "Mastercard ending in 5555"]

    assert Checkout.summary(page, @url, "Mastercard ending in 5555")["payment"] ==
             "Mastercard ending in 5555"

    # A pick that isn't among the page's cards counts for nothing.
    assert Checkout.summary(page, @url, "Amex ending in 1111")["payment"] == nil

    assert Checkout.order_number("Thank you! Your order was placed. Order number: TA-1001") ==
             "TA-1001"
  end

  test "held, approved with the typed total, read again, one click, receipt" do
    task = open()
    read(task, @checkout)
    find_button(task)

    # The popup: the summary built from the page, every check passed.
    assert %{"behavior" => "deny", "message" => message} = click(task, :confirm)
    assert message =~ "the user approved this order. Now read the page once more"
    assert_received {:popup, %{summary: summary, checks: checks, mode: :order}}
    assert summary["total_text"] == "$16.00" and summary["host"] == "shop.example"
    assert Enum.all?(checks, &match?({:ok, _}, &1))

    # Not before it's read again.
    assert %{"behavior" => "deny", "message" => again} = click(task)
    assert again =~ "read the page once more"

    read(task, @checkout)
    assert %{"behavior" => "allow"} = click(task)
    refute_received {:popup, _}

    # The click's result, then the confirmation page.
    hook(task, "computer", @click, [%{"type" => "text", "text" => "Clicked on element ref_16"}])

    read(
      task,
      "Thank you!\nYour order was placed. Order number: TA-1001",
      "https://shop.example/thanks"
    )

    assert_received {:gate,
                     {:purchased,
                      %{
                        order: "TA-1001",
                        host: "shop.example",
                        total_text: "$16.00",
                        id: id,
                        dir: dir
                      }}}

    assert journal(id) == ~w(intent summary confirmed clicking clicked receipt)
    assert File.read!(Path.join(dir, "receipt.txt")) =~ "TA-1001"
    assert Purchases.spent_today("USD") == 16.0
  end

  test "a click on a page it hasn't read is held without asking anyone" do
    task = open()
    find_button(task)
    assert %{"behavior" => "deny", "message" => m} = click(task, :confirm)
    assert m =~ "read the page with get_page_text first"
    refute_received {:popup, _}
  end

  test "an action after the read makes it stale: read again first" do
    task = open()
    read(task, @checkout)
    find_button(task)

    # Choosing a card, say: let through on the shop the user allowed.
    GenServer.call(Gate, {:chrome_site, task.id, "shop.example"})

    Req.post!(task.url,
      json: %{
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: %{
          name: "chrome_permission",
          arguments: %{
            tool_name: @c <> "form_input",
            input: %{"ref" => "ref_3", "value" => "x", "tabId" => 7}
          }
        }
      },
      headers: %{"authorization" => "Bearer #{task.token}"}
    )

    assert %{"message" => m} = click(task, :confirm)
    assert m =~ "read the page with get_page_text first"
    refute_received {:popup, _}
  end

  test "the total changed while the user decided: nothing is bought" do
    task = open()
    read(task, @checkout)
    find_button(task)
    click(task, :confirm)

    read(task, String.replace(@checkout, "Order total: $16.00", "Order total: $46.00"))
    assert %{"behavior" => "deny", "message" => m} = click(task)
    assert m =~ "the total changed from $16.00 to $46.00"
    assert_received {:gate, {:purchase_changed, _}}

    # Back to the start: a new summary, a new popup.
    assert %{"behavior" => "deny"} = click(task, :deny)
    assert_received {:popup, %{summary: %{"total_text" => "$46.00"}}}
  end

  test "several cards and none picked: held until the agent clicks one by its name" do
    task = open()

    page =
      String.replace(
        @checkout,
        "Mastercard ending in 5555",
        "Visa ending in 4242\nMastercard ending in 5555"
      )

    read(task, page)
    find_button(task)
    assert %{"message" => m} = click(task, :confirm)
    assert m =~ "several cards (Visa ending in 4242, Mastercard ending in 5555)"
    refute_received {:popup, _}

    # The agent clicks the Mastercard by its name; the gate sees it go through.
    hook(
      task,
      "find",
      %{"tabId" => 7},
      [%{"type" => "text", "text" => "- ref_15: label \"Mastercard ending in 5555\""}] ++
        tab_context(@url)
    )

    hook(task, "computer", %{"action" => "left_click", "ref" => "ref_15", "tabId" => 7}, [
      %{"type" => "text", "text" => "Clicked on element ref_15"}
    ])

    read(task, page)
    assert %{"message" => approved} = click(task, :confirm)
    assert approved =~ "the user approved"
    assert_received {:popup, %{summary: %{"paying_with" => "Mastercard ending in 5555"}}}
  end

  test "the user says no" do
    task = open()
    read(task, @checkout)
    find_button(task)
    assert %{"behavior" => "deny", "message" => m} = click(task, :deny)
    assert m =~ "the user didn't confirm the purchase"
  end

  test "over a limit or with no maximum: refused, never asked" do
    limits(per_order_max: 10.0, daily_max: 200.0)
    task = open()
    read(task, @checkout)
    find_button(task)
    assert %{"message" => m} = click(task, :confirm)
    assert m =~ "over the $10.00 limit per order"
    refute_received {:popup, _}
    assert_received {:gate, {:purchase_refused, _}}

    limits(per_order_max: 100.0, daily_max: 200.0)
    task = open(%{@intent | max: nil})
    read(task, @checkout)
    find_button(task)
    assert %{"message" => m} = click(task, :confirm)
    assert m =~ "Ask the user the most they want to spend"
  end

  test "buying off: refused, with how to turn it on" do
    limits(enabled: false)
    task = open()
    read(task, @checkout)
    find_button(task)
    assert %{"message" => m} = click(task, :confirm)
    assert m =~ "buying is off"
    refute_received {:popup, _}
  end

  test "an order that may have gone through is never placed twice" do
    task = open()
    read(task, @checkout)
    find_button(task)
    click(task, :confirm)
    assert_received {:popup, _}
    read(task, @checkout)
    assert %{"behavior" => "allow"} = click(task)

    # No receipt yet: another click is refused.
    assert %{"behavior" => "deny", "message" => m} = click(task, :confirm)
    assert m =~ "never places one twice"
    refute_received {:popup, _}
  end
end
