defmodule TinyAxe.ChromeTest do
  @moduledoc """
  Claude in Chrome through the gate: the rules (`TinyAxe.Chrome`), and the
  gate end to end over HTTP — Claude Code's permission questions to
  `chrome_permission` and its hook's results to `POST /hook/<task>`, shaped
  as P0 saw them (docs/plan-chrome-purchases.md).
  """

  use ExUnit.Case, async: true

  alias TinyAxe.Agent.ClaudeDriver
  alias TinyAxe.Chrome
  alias TinyAxe.Tools.Gate

  @c "mcp__claude-in-chrome__"
  @shop "http://127.0.0.1:39849"

  # What Claude in Chrome's results look like (P0).
  defp tab_context(tab, url),
    do: [
      %{
        "type" => "text",
        "text" =>
          "\n\nTab Context:\n- Executed on tabId: #{tab}\n- Available tabs:\n  • tabId #{tab}: \"Checkout\" (\"#{url}\")"
      }
    ]

  defp found(tab, ref, label),
    do:
      [
        %{
          "type" => "text",
          "text" =>
            "Found 1 matching element\n\n- #{ref}: button \"\"#{label}\"\" (button) - Exact match"
        }
      ] ++
        tab_context(tab, "#{@shop}/order-saved")

  defp page(tab, url, text),
    do:
      [
        %{
          "type" => "text",
          "text" => "Title: Checkout\nURL: #{url}\nSource element: <main>\n---\n#{text}"
        }
      ] ++ tab_context(tab, url)

  defp click(tab, ref), do: %{"action" => "left_click", "ref" => ref, "tabId" => tab}

  defp seen_checkout do
    Chrome.new()
    |> Chrome.observe(
      @c <> "get_page_text",
      %{"tabId" => 7},
      page(7, "#{@shop}/order-saved", "Review your order\nOrder total: $16.00\nPlace order")
    )
    |> Chrome.observe(@c <> "find", %{"tabId" => 7}, found(7, "ref_16", "Place order"))
    |> Chrome.observe(
      @c <> "find",
      %{"tabId" => 7},
      found(7, "ref_3", "Mastercard ending in 5555")
    )
  end

  describe "the rules" do
    test "looking runs; batches, scripts and shortcuts are refused" do
      seen = Chrome.new()

      for tool <- ~w(tabs_context_mcp read_page get_page_text find read_console_messages),
          do: assert({:read, _, _} = Chrome.classify(seen, @c <> tool, %{}))

      assert {:read, _, _} = Chrome.classify(seen, @c <> "computer", %{"action" => "screenshot"})

      for tool <- ~w(browser_batch javascript_tool shortcuts_execute file_upload),
          do: assert({:refused, _, _} = Chrome.classify(seen, @c <> tool, %{}))
    end

    test "results teach it each tab's address, each ref's label and a page's text" do
      seen = seen_checkout()
      assert seen.tabs[7] == "#{@shop}/order-saved"
      assert seen.labels[{7, "ref_16"}] == "Place order"
      assert seen.pages[7].url == "#{@shop}/order-saved"

      # A new page: what its refs named is gone.
      seen =
        Chrome.observe(
          seen,
          @c <> "navigate",
          %{"tabId" => 7, "url" => "#{@shop}/shop"},
          tab_context(7, "#{@shop}/shop")
        )

      assert seen.labels == %{}
      assert seen.pages == %{}
    end

    test "a click on a button that places an order is a commit; others are acts on the tab's site" do
      seen = seen_checkout()

      assert {:commit, ~s(clicks "Place order"), "127.0.0.1"} =
               Chrome.classify(seen, @c <> "computer", click(7, "ref_16"))

      assert {:act, ~s(clicks "Mastercard ending in 5555"), "127.0.0.1"} =
               Chrome.classify(seen, @c <> "computer", click(7, "ref_3"))

      assert {:act, "opens www.example.com", "www.example.com"} =
               Chrome.classify(seen, @c <> "navigate", %{"url" => "https://www.example.com/x"})

      # "back" goes on in the same tab's site.
      assert {:act, _, "127.0.0.1"} =
               Chrome.classify(seen, @c <> "navigate", %{"url" => "back", "tabId" => 7})
    end

    test "every click names a known element: by position or an unknown ref is refused" do
      seen = seen_checkout()

      # The hole the first live run found: "Place order" clicked by where it is.
      for s <- [seen, Chrome.new()] do
        assert {:refused, "click by ref, not by position" <> _, _} =
                 Chrome.classify(s, @c <> "computer", %{
                   "action" => "left_click",
                   "coordinate" => [400, 300],
                   "tabId" => 7
                 })
      end

      assert {:refused, "tiny-axe doesn't know ref_99 yet" <> _, _} =
               Chrome.classify(seen, @c <> "computer", click(7, "ref_99"))
    end

    test "Enter: refused on a page tiny-axe hasn't read, held on a checkout" do
      enter = %{"action" => "key", "text" => "Return", "tabId" => 7}

      assert {:refused, "read the page first" <> _, _} =
               Chrome.classify(Chrome.new(), @c <> "computer", enter)

      assert {:commit, _, _} = Chrome.classify(seen_checkout(), @c <> "computer", enter)

      article =
        Chrome.observe(
          Chrome.new(),
          @c <> "get_page_text",
          %{"tabId" => 7},
          page(7, "#{@shop}/article", "An article")
        )

      assert {:act, "presses Enter", _} = Chrome.classify(article, @c <> "computer", enter)
    end

    test "on a checkout, Continue / Submit / Confirm may place the order: held" do
      seen =
        Chrome.observe(
          seen_checkout(),
          @c <> "find",
          %{"tabId" => 7},
          found(7, "ref_20", "Continue")
        )

      assert {:commit, ~s(clicks "Continue" on a checkout), _} =
               Chrome.classify(seen, @c <> "computer", click(7, "ref_20"))

      elsewhere =
        Chrome.observe(
          Chrome.new(),
          @c <> "find",
          %{"tabId" => 8},
          found(8, "ref_20", "Continue")
        )

      assert {:act, _, _} = Chrome.classify(elsewhere, @c <> "computer", click(8, "ref_20"))
    end

    test "a card number is never typed or filled in" do
      card = "4242 4242 4242 4242"

      assert {:refused, "that looks like a card number" <> _, _} =
               Chrome.classify(Chrome.new(), @c <> "computer", %{
                 "action" => "type",
                 "text" => card
               })

      assert {:refused, _, _} =
               Chrome.classify(Chrome.new(), @c <> "form_input", %{
                 "ref" => "ref_1",
                 "value" => card
               })

      assert {:act, _, _} =
               Chrome.classify(Chrome.new(), @c <> "form_input", %{
                 "ref" => "ref_1",
                 "value" => "blue mug"
               })
    end
  end

  describe "through the gate" do
    defp open(opts \\ []) do
      me = self()

      {:ok, task} =
        Gate.open_task(&send(me, {:gate, &1}), Keyword.merge([servers: [], chrome: true], opts))

      on_exit(fn -> Gate.close_task(task.id) end)
      Gate.driven_by(task.id, {:claude, "claude-haiku-5-5"})
      task
    end

    defp rpc(task, method, params) do
      Req.post!(task.url,
        json: %{jsonrpc: "2.0", id: 1, method: method, params: params},
        headers: %{"authorization" => "Bearer #{task.token}"},
        retry: false
      ).body["result"]
    end

    defp hook(task, tool, input, response, token \\ nil) do
      Req.post!(task.hook_url,
        json: %{
          "hook_event_name" => "PostToolUse",
          "tool_name" => @c <> tool,
          "tool_input" => input,
          "tool_response" => response
        },
        headers: %{"authorization" => "Bearer #{token || task.token}"},
        retry: false
      ).status
    end

    # Claude Code's permission question, answering any approval with `answer`.
    defp permission(task, tool, input, answer \\ nil) do
      caller =
        Task.async(fn ->
          rpc(task, "tools/call", %{
            name: "chrome_permission",
            arguments: %{tool_name: @c <> tool, input: input, tool_use_id: "toolu_1"}
          })
        end)

      wait(caller, answer)
    end

    defp wait(caller, answer) do
      receive do
        {:gate, {:tool_approval, ask}} ->
          if answer, do: send(ask.reply_to, {:tool_answer, ask.ref, answer})
          send(self(), {:asked, ask})
          wait(caller, answer)

        {ref, result} when ref == caller.ref ->
          Process.demonitor(ref, [:flush])
          [%{"text" => text}] = result["content"]
          JSON.decode!(text)
      after
        5_000 -> flunk("no answer")
      end
    end

    test "it's offered to Claude only, with a Chrome task" do
      names = fn task -> for t <- rpc(task, "tools/list", %{})["tools"], do: t["name"] end
      assert "chrome_permission" in names.(open())

      plain = open(chrome: false)
      refute "chrome_permission" in names.(plain)

      local = open()
      Gate.driven_by(local.id, {:ollama, "gemma"})
      refute "chrome_permission" in names.(local)
    end

    test "looking is allowed at once, unchanged" do
      task = open()
      input = %{"tabId" => 7}

      assert %{"behavior" => "allow", "updatedInput" => ^input} =
               permission(task, "get_page_text", input)

      refute_received {:asked, _}
    end

    test "acting on a new site asks; \"a\" allows that site for the task; no is a refusal" do
      task = open()
      nav = %{"url" => "https://shop.example/cart"}

      assert %{"behavior" => "allow"} = permission(task, "navigate", nav, :session)

      assert_received {:asked,
                       %{session_ok: true, site: "shop.example", tool: "chrome · navigate"}}

      # The same site again: no question.
      assert %{"behavior" => "allow"} =
               permission(task, "navigate", %{"url" => "https://shop.example/checkout"})

      refute_received {:asked, _}

      assert %{"behavior" => "deny", "message" => "tiny-axe stopped this call: the user said no."} =
               permission(task, "navigate", %{"url" => "https://other.example/"}, :deny)
    end

    test "with what the hook showed, a Place order click is held, and a batch is refused" do
      task = open()

      assert hook(
               task,
               "get_page_text",
               %{"tabId" => 7},
               page(7, "#{@shop}/order-saved", "Order total: $16.00\nPlace order")
             ) == 204

      assert hook(task, "find", %{"tabId" => 7}, found(7, "ref_16", "Place order")) == 204

      assert %{"behavior" => "deny", "message" => message} =
               permission(task, "computer", click(7, "ref_16"))

      assert message =~ ~s(clicks "Place order" would place an order)
      refute_received {:asked, _}
      assert_received {:gate, {:tool_call, %{tool: "computer", class: :commit}}}

      assert %{"behavior" => "deny", "message" => batch} =
               permission(task, "browser_batch", %{"actions" => []})

      assert batch =~ "one call at a time"
    end

    test "the hook needs the task's token" do
      task = open()

      assert hook(task, "find", %{"tabId" => 7}, found(7, "ref_16", "Place order"), "wrong") ==
               401
    end

    test "only Chrome calls are answered there" do
      task = open()

      result =
        rpc(task, "tools/call", %{
          name: "chrome_permission",
          arguments: %{tool_name: "Bash", input: %{"command" => "rm -rf ~"}}
        })

      [%{"text" => text}] = result["content"]
      assert %{"behavior" => "deny"} = JSON.decode!(text)
    end
  end

  describe "the Claude driver" do
    test "a Chrome task's run gets --chrome, the hook and the permission tool" do
      args = ClaudeDriver.args("claude-haiku-5-5", "/tmp/gate.json", "system", "/tmp/hooks.json")
      assert "--chrome" in args

      assert ["--settings", "/tmp/hooks.json"] ==
               Enum.drop_while(args, &(&1 != "--settings")) |> Enum.take(2)

      assert ["--permission-prompt-tool", "mcp__tinyaxe__chrome_permission"] ==
               Enum.drop_while(args, &(&1 != "--permission-prompt-tool")) |> Enum.take(2)

      # Still none of Claude Code's own tools, and only the gate's.
      assert ["--tools", ""] == Enum.drop_while(args, &(&1 != "--tools")) |> Enum.take(2)

      assert ["--allowedTools", "mcp__tinyaxe"] ==
               Enum.drop_while(args, &(&1 != "--allowedTools")) |> Enum.take(2)

      refute "--chrome" in ClaudeDriver.args("claude-haiku-5-5", "/tmp/gate.json", "system")
    end

    test "the hook posts Chrome results to the gate, with the address and token from its environment" do
      [hook] = ClaudeDriver.hook_settings()["hooks"]["PostToolUse"]
      assert hook["matcher"] == "mcp__claude-in-chrome__.*"
      [%{"command" => command}] = hook["hooks"]
      assert command =~ "$TINYAXE_HOOK_URL"
      assert command =~ "Bearer $TINYAXE_HOOK_TOKEN"
    end
  end
end
