defmodule TinyAxe.AgentTest do
  @moduledoc """
  The agent's drivers, each reaching a fake MCP server only through the gate.
  The Claude and Codex drivers run the fake CLIs (test/support/fake_cli),
  which call the gate the way the real ones do; the local driver runs a
  scripted model.
  """

  # Swaps the app-wide model, decider and roles, so not async.
  use ExUnit.Case, async: false

  alias TinyAxe.{Agent, Decider, MCP, Model, Pipeline, Tools}

  @server Path.expand("../support/fake_mcp/server", __DIR__)
  @keys ~w(model_backend decider script_model script_decider models local_agent_steps code_check web_search)a

  setup do
    previous = Map.new(@keys, &{&1, Application.get_env(:tiny_axe, &1)})
    name = "srv#{System.unique_integer([:positive])}"
    {:ok, _} = MCP.start_server(name, %{"command" => @server, "policy" => %{"read" => ["echo"]}})

    on_exit(fn ->
      MCP.stop_server(name)

      for {k, v} <- previous,
          do:
            if(v == nil,
              do: Application.delete_env(:tiny_axe, k),
              else: Application.put_env(:tiny_axe, k, v)
            )
    end)

    Application.put_env(:tiny_axe, :code_check, false)
    Application.put_env(:tiny_axe, :web_search, false)
    %{server: name}
  end

  defp driver(choice) do
    models = Application.get_env(:tiny_axe, :models, [])
    Application.put_env(:tiny_axe, :models, Keyword.put(models, :agent, choice))
  end

  # Runs the agent in a task, as the TUI does, answering approvals with `answer`.
  defp run(prompt, remote, answer \\ :deny) do
    me = self()
    task = Task.async(fn -> Agent.run([], prompt, &send(me, {:event, &1}), remote: remote) end)
    collect(task, answer, [])
  end

  defp collect(task, answer, acc) do
    receive do
      {:event, {:tool_approval, ask} = e} ->
        send(ask.reply_to, {:tool_answer, ask.ref, answer})
        collect(task, answer, [e | acc])

      {:event, {:ask_remote, ask} = e} ->
        send(ask.reply_to, {:remote_answer, ask.ref, answer != :deny})
        collect(task, answer, [e | acc])

      {:event, e} ->
        collect(task, answer, [e | acc])

      {ref, _} when ref == task.ref ->
        Process.demonitor(ref, [:flush])
        Enum.reverse(acc) ++ drain([])
    after
      30_000 -> flunk("the agent never finished")
    end
  end

  defp drain(acc) do
    receive do
      {:event, e} -> drain([e | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp done(events), do: Enum.find_value(events, fn e -> match?({:done, _}, e) && elem(e, 1) end)
  defp all(events, tag), do: for({^tag, v} <- events, do: v)
  defp after_flag(args, flag), do: args |> Enum.drop_while(&(&1 != flag)) |> Enum.at(1)

  describe "the Claude driver" do
    test "runs Claude Code with the gate as its only tools, and uses them through it", %{
      server: s
    } do
      driver({:claude, "haiku"})
      events = run(~s(Echo it. SCENARIO:tool:#{s}__echo:{"text":"hi"}), :allowed)
      reply = JSON.decode!(done(events))

      assert reply["tool_result"] == %{"error" => false, "text" => "echo: hi"}
      assert [%{tool: tool, class: :read}] = all(events, :tool_call)
      assert tool == "#{s}__echo"

      # Its only MCP server is this task's gate, its only tools the gate's.
      assert Map.keys(reply["mcp_config"]["mcpServers"]) == ["tinyaxe"]
      args = reply["args"]
      assert after_flag(args, "--setting-sources") == "local"
      assert after_flag(args, "--tools") == ""
      assert after_flag(args, "--allowedTools") == "mcp__tinyaxe"
      assert "--strict-mcp-config" in args
      refute "--safe-mode" in args

      # The file holding the gate's token is gone afterwards.
      refute File.exists?(after_flag(args, "--mcp-config"))
      assert [%{driver: "Claude haiku"}] = all(events, :agent)
      assert {:answered_by, %{model: "Claude haiku"}} in events
    end

    test "an outward call still waits for the user, and a no reaches the driver as a refusal", %{
      server: s
    } do
      driver({:claude, "haiku"})
      events = run(~s(SCENARIO:tool:#{s}__send_note:{"to":"Sam","text":"hi"}), :allowed, :deny)

      assert [%{tool: tool}] = all(events, :tool_approval)
      assert tool == "#{s}__send_note"
      assert %{"error" => true, "text" => why} = JSON.decode!(done(events))["tool_result"]
      assert why =~ "the user said no"
    end

    test "the task's token stops working when the run ends", %{server: s} do
      driver({:claude, "haiku"})
      events = run(~s(SCENARIO:tool:#{s}__echo:{"text":"x"}), :allowed)
      config = JSON.decode!(done(events))["mcp_config"]["mcpServers"]["tinyaxe"]

      assert %{status: 401} =
               Req.post!(config["url"],
                 json: %{jsonrpc: "2.0", id: 1, method: "tools/list"},
                 headers: config["headers"],
                 retry: false
               )
    end
  end

  test "the Codex driver gets the gate over HTTP, its token from the environment", %{server: s} do
    driver({:codex, "gpt-6-luna"})
    events = run(~s(SCENARIO:tool:#{s}__echo:{"text":"from codex"}), :allowed)
    reply = JSON.decode!(done(events))

    assert reply["tool_result"] == %{"error" => false, "text" => "echo: from codex"}
    assert "shell_tool" in reply["args"] and "browser_use" in reply["args"]
    # The token isn't on the command line.
    refute Enum.any?(reply["args"], &(&1 =~ ~r/Bearer/))
  end

  describe "the local driver" do
    test "the local model calls tools through the gate, then answers", %{server: s} do
      driver({:ollama, "local-test"})
      counter = :counters.new(1, [])

      Model.Script.script(fn _messages, _opts ->
        :counters.add(counter, 1, 1)

        if :counters.get(counter, 1) == 1,
          do:
            JSON.encode!(%{
              thought: "",
              tool: "#{s}__echo",
              arguments: ~s({"text":"local"}),
              answer: ""
            }),
          else:
            JSON.encode!(%{
              thought: "",
              tool: "",
              arguments: "{}",
              answer: "It said echo: local."
            })
      end)

      events = run("Echo something", :denied)
      assert done(events) == "It said echo: local."
      assert [%{tool: tool, class: :read}] = all(events, :tool_call)
      assert tool == "#{s}__echo"
      refute Enum.any?(events, &match?({:answered_by, _}, &1))
    end

    test "when it falls short and the user allows it, Claude's loop takes over", %{server: s} do
      driver({:ollama, "local-test"})
      Application.put_env(:tiny_axe, :local_agent_steps, 2)

      # Calls tools forever, never answering.
      Model.Script.script(fn _, _ ->
        JSON.encode!(%{
          thought: "",
          tool: "#{s}__echo",
          arguments: ~s({"text":"again"}),
          answer: ""
        })
      end)

      events = run("Do it", :allowed)

      assert [
               %{
                 to: "Claude haiku",
                 reason: "the local model ran out of steps before it finished"
               }
             ] =
               all(events, :escalate)

      assert {:answered_by, %{model: "Claude haiku"}} in events
    end
  end

  test "the local loop catches made-up tool names itself, and stops after three errors" do
    driver({:ollama, "local-test"})

    Model.Script.script(fn _, _ ->
      JSON.encode!(%{thought: "", tool: "tool", arguments: "{}", answer: ""})
    end)

    events = run("Do it", :denied)

    assert {:error,
            {:agent_fell_short, "the local model's tool calls failed three times in a row"}} in events

    # The made-up name never reached the gate.
    assert all(events, :tool_call) == []
  end

  test "without the user's say-so for Claude, the local model drives instead", %{server: s} do
    driver({:claude, "haiku"})

    Model.Script.script(fn _, _ ->
      JSON.encode!(%{thought: "", tool: "", arguments: "{}", answer: "done locally"})
    end)

    events = run(~s(SCENARIO:tool:#{s}__echo:{"text":"x"}), :denied)
    assert [_why] = all(events, :agent_local)
    assert done(events) == "done locally"
  end

  test "every agent call is journaled under its task", %{server: s} do
    driver({:claude, "haiku"})
    events = run(~s(SCENARIO:tool:#{s}__echo:{"text":"journal me"}), :allowed)
    url = JSON.decode!(done(events))["mcp_config"]["mcpServers"]["tinyaxe"]["url"]
    task_id = url |> String.split("/") |> List.last()

    assert [%{"tool" => _, "decision" => "ran", "result" => "echo: journal me"}] =
             Tools.Journal.read(task_id)
  end

  describe "routing" do
    defp route_events(prompt) do
      me = self()
      Pipeline.run([], prompt, &send(me, {:event, &1}), remote: :allowed)
      drain([])
    end

    test "a request that needs a connected service goes to the agent", %{server: s} do
      driver({:claude, "haiku"})

      Decider.Script.script(fn
        :tools, %{instructions: q}, _ -> if q =~ s, do: 0.9, else: 0.0
        _, _, _ -> nil
      end)

      events = route_events(~s(SCENARIO:tool:#{s}__echo:{"text":"routed"}))
      assert {:task, :agent} in events
      assert JSON.decode!(done(events))["tool_result"]["text"] == "echo: routed"
    end

    test "with no servers connected, there's no tools question and no agent", %{server: s} do
      MCP.stop_server(s)
      Model.Script.script(fn _, _ -> "A plain answer." end)

      Decider.Script.script(fn
        :tools, _, _ -> flunk("asked about tools with none connected")
        :addresses, _, _ -> 0.95
        _, _, _ -> nil
      end)

      events = route_events("Anything")
      assert {:task, :answer} in events
    end
  end
end
