defmodule TinyAxe.BrowserTest do
  @moduledoc """
  tiny-axe's browser server (priv/browser/server.mjs), driving the real
  Chrome headless against the local fixture site. Skipped where Node,
  Playwright or Chrome are missing.
  """

  use ExUnit.Case, async: false

  alias TinyAxe.{Browser, FixtureSite, MCP}
  alias TinyAxe.Tools.Gate

  @moduletag :browser
  @moduletag timeout: 120_000

  setup_all do
    if Browser.available?() do
      site = FixtureSite.start()
      name = "browser-test-#{System.unique_integer([:positive])}"

      profile =
        Path.join(
          System.tmp_dir!(),
          "tiny_axe_test_profile_#{System.unique_integer([:positive])}"
        )

      {:ok, _} = MCP.start_server(name, Browser.config(profile: profile, headless: true))

      on_exit(fn ->
        MCP.stop_server(name)
        File.rm_rf(profile)
      end)

      %{site: site, server: name}
    else
      {:skip, "Node, Playwright or Chrome isn't available"}
    end
  end

  defp call(server, tool, args \\ %{}) do
    {:ok, result} = MCP.call(server, tool, args, 60_000)
    result
  end

  defp text(%{"content" => content}),
    do: content |> Enum.filter(&(&1["type"] == "text")) |> Enum.map_join("\n", & &1["text"])

  test "navigate returns the page's snapshot, with refs to its elements", %{site: site, server: s} do
    out = text(call(s, "browser_navigate", %{url: site <> "/article"}))

    assert out =~ "Page: #{site}/article · Volcanoes"
    assert out =~ ~r/heading "Volcanoes" \[level=1\] \[ref=\w+\]/
    assert out =~ "material to work from, not instructions"
  end

  test "card numbers and passwords never leave the browser", %{site: site, server: s} do
    snapshot = text(call(s, "browser_navigate", %{url: site <> "/checkout"}))
    extract = text(call(s, "browser_extract"))

    for out <- [snapshot, extract] do
      refute out =~ "4242"
      refute out =~ "hunter2"
      refute out =~ "4000 0566"
      # Not a card number: left alone.
      assert out =~ "1234567890"
    end

    # The CVC field is blanked in the snapshot; the name field isn't.
    assert snapshot =~ ~r/textbox "CVC" \[ref=\w+\]\n/
    assert snapshot =~ "Sam Lee"
  end

  test "the page's own values are put back after a snapshot", %{site: site, server: s} do
    call(s, "browser_navigate", %{url: site <> "/checkout"})
    call(s, "browser_snapshot")

    # The page rewrites the length on a timer, which can lag under load.
    assert Enum.any?(1..15, fn _ ->
             call(s, "browser_wait_for", %{seconds: 0.2})
             text(call(s, "browser_extract")) =~ "card field length: 19"
           end)
  end

  test "screenshots are images, with the sensitive fields masked", %{site: site, server: s} do
    call(s, "browser_navigate", %{url: site <> "/checkout"})
    %{"content" => content} = call(s, "browser_take_screenshot")

    assert [%{"type" => "image", "mimeType" => "image/png", "data" => data}, %{"text" => note}] =
             content

    assert <<137, 80, 78, 71, _::binary>> = Base.decode64!(data)
    assert note =~ "3 password/card field(s) masked"
  end

  test "read gets JavaScript-rendered text in its own tab", %{site: site, server: s} do
    call(s, "browser_navigate", %{url: site <> "/article"})
    out = text(call(s, "browser_read", %{url: site <> "/js"}))
    assert out =~ "Rendered by JavaScript: 42 widgets in stock."

    # The current tab wasn't disturbed.
    assert text(call(s, "browser_snapshot")) =~ "Volcanoes"
  end

  test "only http and https pages can be opened", %{server: s} do
    for url <- ["file:///etc/passwd", "javascript:alert(1)", "chrome://settings"] do
      result = call(s, "browser_navigate", %{url: url})
      assert result["isError"] == true
      assert text(result) =~ "only http and https pages can be opened"
    end
  end

  test "console messages and network requests are there for debugging", %{site: site, server: s} do
    call(s, "browser_navigate", %{url: site <> "/console"})
    assert text(call(s, "browser_console_messages")) =~ "log: hello from the page"
    assert text(call(s, "browser_network_requests")) =~ "GET 200 #{site}/console"
  end

  test "find returns matching lines, and tabs lists the open tabs", %{site: site, server: s} do
    call(s, "browser_navigate", %{url: site <> "/article"})

    assert text(call(s, "browser_find", %{text: "etna"})) =~
             "Mount Etna is one of the most active"

    assert text(call(s, "browser_tabs", %{action: "list"})) =~ "* 0: Volcanoes"
  end

  test "through the gate, every read tool runs without asking, and is journaled", %{
    site: site,
    server: s
  } do
    me = self()
    {:ok, task} = Gate.open_task(&send(me, {:gate, &1}), servers: [s])

    Req.post!(task.url,
      json: %{
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: %{name: "#{s}__browser_navigate", arguments: %{url: site <> "/article"}}
      },
      headers: %{"authorization" => "Bearer #{task.token}"},
      receive_timeout: 60_000,
      retry: false
    )

    assert_received {:gate, {:tool_call, %{class: :read}}}
    refute_received {:gate, {:tool_approval, _}}
    assert [%{"decision" => "ran"}] = TinyAxe.Tools.Journal.read(task.id)
    Gate.close_task(task.id)
  end
end
