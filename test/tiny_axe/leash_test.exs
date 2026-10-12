defmodule TinyAxe.LeashTest do
  @moduledoc """
  The leash (`TinyAxe.Leash`, docs/plan-leash.md) through the gate, on the
  fixture site with the real Chrome headless: browser actions and orders
  whose checks all pass go through without asking, only for a task opened
  on the leash, and only while it's on.
  """

  use ExUnit.Case, async: false

  alias TinyAxe.{Browser, Decider, FixtureSite, Leash, MCP}
  alias TinyAxe.Tools.Gate

  @moduletag :browser
  @moduletag :tmp_dir
  @moduletag timeout: 180_000

  @intent %{request: "buy the blue mug", max: nil, currency: "USD"}

  setup_all do
    if Browser.available?() do
      site = FixtureSite.start()
      name = "browser-leash-#{System.unique_integer([:positive])}"

      profile =
        Path.join(
          System.tmp_dir!(),
          "tiny_axe_leash_profile_#{System.unique_integer([:positive])}"
        )

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

    Application.put_env(:tiny_axe, :purchases,
      enabled: true,
      currency: "USD",
      merchants: :any,
      per_order_max: 150.0,
      daily_max: 300.0
    )

    Application.put_env(:tiny_axe, :state_dir, dir)

    Decider.Script.script(fn
      :matches, _, _ -> 0.9
      _, _, _ -> nil
    end)

    FixtureSite.clear()
    FixtureSite.set_price(12.0)

    on_exit(fn ->
      Leash.set(false)

      for {k, v} <- previous,
          do:
            if(v == nil,
              do: Application.delete_env(:tiny_axe, k),
              else: Application.put_env(:tiny_axe, k, v)
            )
    end)
  end

  defp open_task(ctx, opts) do
    me = self()
    {:ok, task} = Gate.open_task(&send(me, {:gate, &1}), [servers: [ctx.server]] ++ opts)
    on_exit(fn -> Gate.close_task(task.id) end)
    task
  end

  # One call through the gate; any question is answered with `answer` and noted.
  defp call(task, name, args, answer \\ :deny) do
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

    await(caller, answer)
  end

  defp await(caller, answer) do
    receive do
      {:gate, {:tool_approval, ask}} ->
        send(self(), {:asked, ask})

        send(
          ask.reply_to,
          {:tool_answer, ask.ref, if(answer == :confirm, do: :once, else: answer)}
        )

        await(caller, answer)

      {:gate, {:purchase_approval, ask}} ->
        send(self(), {:asked, ask})
        send(ask.reply_to, {:purchase_answer, ask.ref, answer})
        await(caller, answer)

      {ref, result} when ref == caller.ref ->
        Process.demonitor(ref, [:flush])
        result
    after
      90_000 -> flunk("the call never finished")
    end
  end

  defp text(%{"content" => content}),
    do: content |> Enum.filter(&(&1["type"] == "text")) |> Enum.map_join("\n", & &1["text"])

  defp ref(snapshot, role, name) do
    [_, ref] = Regex.run(~r/#{role} "#{Regex.escape(name)}"[^\n]*\[ref=(\w+)\]/, snapshot)
    ref
  end

  defp send_contact(ctx, task, answer \\ :deny) do
    page = text(call(task, "#{ctx.server}__browser_navigate", %{url: ctx.site <> "/contact"}))

    call(task, "#{ctx.server}__browser_type", %{
      ref: ref(page, "textbox", "Your name"),
      text: "Sam"
    })

    call(
      task,
      "#{ctx.server}__browser_click",
      %{ref: ref(page, "button", "Send message")},
      answer
    )
  end

  defp buy(ctx, task, answer \\ :deny) do
    page = text(call(task, "#{ctx.server}__browser_navigate", %{url: ctx.site <> "/order"}))
    [_, ref] = Regex.run(~r/button "Place order" \[ref=(\w+)\]/, page)
    call(task, "#{ctx.server}__browser_click", %{ref: ref, element: "Place order"}, answer)
  end

  defp placed, do: for({"/place-order", _} <- FixtureSite.submissions(), do: :order)

  describe "browser actions" do
    test "on the leash, sending a form runs without asking", ctx do
      Leash.set(true)
      send_contact(ctx, open_task(ctx, leash: true))
      refute_received {:asked, _}
      assert [{"/contact", %{"name" => "Sam"}}] = FixtureSite.submissions()
    end

    test "a task not opened on the leash (the 🌐 chat) still asks", ctx do
      Leash.set(true)
      send_contact(ctx, open_task(ctx, leash: false))
      assert_received {:asked, %{class: :outward}}
      assert FixtureSite.submissions() == []
    end

    test "with the leash off, it asks", ctx do
      send_contact(ctx, open_task(ctx, leash: true))
      assert_received {:asked, %{class: :outward}}
      assert FixtureSite.submissions() == []
    end
  end

  describe "orders" do
    test "on the leash, an order whose checks all pass is placed without asking", ctx do
      Leash.set(true)
      result = buy(ctx, open_task(ctx, leash: true, intent: @intent))

      refute_received {:asked, _}
      assert_received {:gate, {:purchase_leashed, %{mode: :order, summary: %{"host" => _}}}}
      assert_received {:gate, {:purchased, %{total_text: _}}}
      assert placed() == [:order]
      refute result["isError"]
    end

    test "on the leash, an order over the limit is still refused", ctx do
      Leash.set(true)
      FixtureSite.set_price(160.0)
      result = buy(ctx, open_task(ctx, leash: true, intent: @intent))

      refute_received {:asked, _}
      assert text(result) =~ "over the $150.00 limit per order"
      assert placed() == []
    end

    test "off the leash it asks, and a no buys nothing", ctx do
      buy(ctx, open_task(ctx, leash: true, intent: @intent), :deny)
      assert_received {:asked, %{mode: :order}}
      assert placed() == []
    end

    test "no maximum named: the per-order limit stands in for it", ctx do
      buy(ctx, open_task(ctx, leash: true, intent: @intent), :deny)
      assert_received {:asked, %{checks: checks}}
      assert {:ok, "you named no maximum, so the per-order limit is it"} in checks
    end
  end

  describe "dead ends" do
    # Opens the note form, types a note and clicks "Send note"; the click's result.
    defp send_note(ctx, task) do
      page = text(call(task, "#{ctx.server}__browser_navigate", %{url: ctx.site <> "/note"}))
      call(task, "#{ctx.server}__browser_type", %{ref: ref(page, "textbox", "Note"), text: "hi"})
      {page, call(task, "#{ctx.server}__browser_click", %{ref: ref(page, "button", "Send note")})}
    end

    # The answer's check verifies the click: the site said it failed.
    defp fail_note(ctx, task) do
      {page, _} = send_note(ctx, task)
      Gate.complete(task.id, "Sent.")
      :sys.get_state(TinyAxe.Browser.DeadEnds)
      page
    end

    test "kept per site; twice is a dead end; the agent is warned; a repeat is refused", ctx do
      Application.put_env(:tiny_axe, :dead_ends, enabled: true)
      on_exit(fn -> Application.put_env(:tiny_axe, :dead_ends, enabled: false) end)
      Leash.set(true)
      # Jev, verifying: the page shows an error and nothing took effect.
      Decider.Script.script(fn
        :shows_error, _, _ -> 0.9
        :took_effect, _, _ -> 0.1
        _, _, _ -> nil
      end)

      FixtureSite.set_outcome(:refused)
      on_exit(fn -> FixtureSite.set_outcome(:ok) end)

      first = fail_note(ctx, open_task(ctx, leash: true, objective: "send the note hi"))
      refute first =~ "Known dead ends"
      assert TinyAxe.Browser.DeadEnds.known("127.0.0.1") == []

      fail_note(ctx, open_task(ctx, leash: true, objective: "send the note hi"))

      assert [%{"action" => "click", "label" => "Send note", "failures" => 2}] =
               TinyAxe.Browser.DeadEnds.known("127.0.0.1")

      # A new task is told when it reaches the site, once.
      task = open_task(ctx, leash: true, objective: "send the note hi")
      page = fail_note(ctx, task)
      assert page =~ ~s(Known dead ends on 127.0.0.1)
      assert page =~ ~s(- click "Send note" on /note: didn't work 2 times)

      # It failed again here, so trying it once more is refused.
      {again, result} = send_note(ctx, task)
      refute again =~ "Known dead ends"
      assert text(result) =~ "dead_end: this didn't work on this site"
      assert length(for({"/note", _} <- FixtureSite.submissions(), do: :sent)) == 3
    end
  end
end
