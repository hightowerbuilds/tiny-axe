defmodule TinyAxe.ToolGateTest do
  @moduledoc """
  The MCP client and the tool gate, end to end over HTTP, with a fake MCP
  server (test/support/fake_mcp/server) behind the gate.
  """

  use ExUnit.Case, async: true

  alias TinyAxe.{MCP, Tools}
  alias TinyAxe.Tools.{Gate, Policy, Redact}

  @server Path.expand("../support/fake_mcp/server", __DIR__)

  setup do
    name = "fake#{System.unique_integer([:positive])}"

    policy = %{
      "read" => ["echo", "card", "slow", "calls", "ask_client"],
      "deny" => ["delete_all"],
      "commit" => ["crash"]
    }

    {:ok, _} = MCP.start_server(name, %{"command" => @server, "policy" => policy})
    on_exit(fn -> MCP.stop_server(name) end)
    %{server: name}
  end

  defp open(server, opts \\ []) do
    me = self()
    {:ok, task} = Gate.open_task(&send(me, {:gate, &1}), Keyword.put(opts, :servers, [server]))
    on_exit(fn -> Gate.close_task(task.id) end)
    task
  end

  defp rpc(task, method, params \\ %{}, token \\ nil) do
    Req.post!(task.url,
      json: %{jsonrpc: "2.0", id: 1, method: method, params: params},
      headers: %{"authorization" => "Bearer #{token || task.token}"},
      retry: false
    )
  end

  # Calls a tool in a task, answering an approval question with `answer`.
  defp call_tool(task, name, args \\ %{}, answer \\ nil) do
    caller = Task.async(fn -> rpc(task, "tools/call", %{name: name, arguments: args}) end)
    await(caller, answer)
  end

  defp await(caller, answer) do
    receive do
      {:gate, {:tool_approval, ask}} ->
        if answer, do: send(ask.reply_to, {:tool_answer, ask.ref, answer})
        # Left for the test to check, since this took the question itself.
        send(self(), {:asked, ask})
        await(caller, answer)

      {ref, %Req.Response{body: body}} when ref == caller.ref ->
        Process.demonitor(ref, [:flush])
        body["result"]
    after
      15_000 -> flunk("the tool call never finished")
    end
  end

  defp text(%{"content" => [%{"text" => t} | _]}), do: t

  defp downstream_calls(task, server) do
    # Read straight from the server, not through the gate (which would count).
    {:ok, result} = MCP.call(server, "calls", %{})
    _ = task
    # Less this question itself.
    result |> text() |> JSON.decode!() |> Map.delete("calls")
  end

  describe "the MCP client" do
    test "connects, lists the server's tools, and calls them", %{server: s} do
      names = for t <- MCP.tools([s]), do: t.name
      assert "#{s}__echo" in names and "#{s}__send_note" in names

      assert {:ok, %{"content" => [%{"text" => "echo: hi"}]}} = MCP.call(s, "echo", %{text: "hi"})
    end

    test "declines requests the server sends it (tiny-axe offers only tool calls)", %{server: s} do
      assert {:ok, result} = MCP.call(s, "ask_client", %{})
      assert text(result) == "client declined"
    end

    test "a server that dies is restarted", %{server: s} do
      [{pid, _}] = Registry.lookup(TinyAxe.MCP.Registry, s)
      assert {:error, _} = MCP.call(s, "crash", %{})

      assert Enum.any?(1..100, fn _ ->
               Process.sleep(50)

               match?([{new, _}] when new != pid, Registry.lookup(TinyAxe.MCP.Registry, s)) and
                 match?({:ok, _}, MCP.call(s, "echo", %{text: "back"}))
             end)
    end
  end

  describe "the gate's endpoint" do
    test "speaks MCP, offering namespaced tools and hiding denied ones", %{server: s} do
      task = open(s)

      assert %{status: 200, body: %{"result" => %{"serverInfo" => %{"name" => "tiny-axe"}}}} =
               rpc(task, "initialize", %{protocolVersion: "2025-06-18"})

      %{body: %{"result" => %{"tools" => tools}}} = rpc(task, "tools/list")
      names = Enum.map(tools, & &1["name"])

      assert "#{s}__echo" in names
      refute "#{s}__delete_all" in names
    end

    test "a wrong token gets nothing, and an unknown method is \"not found\"", %{server: s} do
      task = open(s)
      assert %{status: 401} = rpc(task, "tools/list", %{}, "wrong")
      assert %{body: %{"error" => %{"code" => -32601}}} = rpc(task, "server/discover")
    end
  end

  describe "a tool call" do
    test "a read runs at once, and is journaled", %{server: s} do
      task = open(s)
      assert text(call_tool(task, "#{s}__echo", %{text: "hi"})) == "echo: hi"
      refute_received {:asked, _}
      assert_received {:gate, {:tool_call, %{tool: tool, class: :read}}}
      assert tool == "#{s}__echo"

      assert [%{"tool" => ^tool, "decision" => "ran", "result" => "echo: hi"}] =
               Tools.Journal.read(task.id)
    end

    test "an outward call waits for the user; once means once", %{server: s} do
      task = open(s)
      note = %{to: "Sam", text: "hi"}

      assert text(call_tool(task, "#{s}__send_note", note, :once)) == "note sent to Sam"
      assert_received {:asked, %{class: :outward, args: %{"to" => "Sam"}}}

      call_tool(task, "#{s}__send_note", %{note | text: "again"}, :once)
      assert_received {:asked, _}
    end

    test "allowed for the session, it isn't asked about again", %{server: s} do
      task = open(s)
      call_tool(task, "#{s}__send_note", %{to: "A", text: "1"}, :session)
      assert_received {:asked, _}

      assert text(call_tool(task, "#{s}__send_note", %{to: "B", text: "2"})) == "note sent to B"
      refute_received {:asked, _}
    end

    test "refused by the user, it never reaches the server", %{server: s} do
      task = open(s)
      result = call_tool(task, "#{s}__send_note", %{to: "Sam", text: "hi"}, :deny)

      assert result["isError"] == true
      assert text(result) =~ "the user said no"
      refute Map.has_key?(downstream_calls(task, s), "send_note")
    end

    test "a denied tool and a purchase are refused without reaching the server", %{server: s} do
      task = open(s)

      assert text(call_tool(task, "#{s}__delete_all")) =~ "tiny-axe doesn't allow this tool"
      assert text(call_tool(task, "#{s}__crash")) =~ "spending money isn't enabled"
      assert downstream_calls(task, s) == %{}
    end

    test "card numbers are removed from results and from the journal", %{server: s} do
      task = open(s)
      result_text = text(call_tool(task, "#{s}__card"))

      assert result_text =~ "[card number removed]"
      refute result_text =~ "4242"
      # Not a card number: left alone.
      assert result_text =~ "1234567890"
      refute File.read!(Path.join(Tools.Journal.dir(task.id), "calls.jsonl")) =~ "4242 4242"
    end

    test "a task is stopped at its call limit", %{server: s} do
      task = open(s, max_calls: 2)
      call_tool(task, "#{s}__echo", %{text: "1"})
      call_tool(task, "#{s}__echo", %{text: "2"})

      assert text(call_tool(task, "#{s}__echo", %{text: "3"})) =~ "limit of 2 tool calls"
      assert_received {:gate, {:tool_limit, _}}
    end

    test "the same call three times in a row is stopped", %{server: s} do
      task = open(s)
      for _ <- 1..2, do: call_tool(task, "#{s}__echo", %{text: "same"})
      assert text(call_tool(task, "#{s}__echo", %{text: "same"})) =~ "three times in a row"
    end

    test "a closed task's token no longer works", %{server: s} do
      task = open(s)
      Gate.close_task(task.id)
      assert %{status: 401} = rpc(task, "tools/list")
    end
  end

  describe "policy" do
    test "a tool the policy doesn't name is outward" do
      assert Policy.classify(%{"name" => "anything"}, %{}) == :outward
    end

    test "wildcards name tools by class, and deny wins" do
      policy = %{"read" => ["get_*"], "deny" => ["get_secret"]}
      assert Policy.classify(%{"name" => "get_issue"}, policy) == :read
      assert Policy.classify(%{"name" => "get_secret"}, policy) == :refused
    end

    test "annotations can make a class stricter, never looser" do
      sends = %{"name" => "post", "annotations" => %{"openWorldHint" => true}}
      claims_safe = %{"name" => "post", "annotations" => %{"readOnlyHint" => true}}

      assert Policy.classify(sends, %{"read" => ["post"]}) == :outward
      assert Policy.classify(claims_safe, %{}) == :outward
    end
  end

  test "redaction keeps order numbers and phone numbers, removes card numbers" do
    assert Redact.text("card 4111-1111-1111-1111 ok") == "card [card number removed] ok"
    assert Redact.text("order 1234567890123") == "order 1234567890123"
    assert Redact.text("call +1 415 555 0100") == "call +1 415 555 0100"
  end
end
