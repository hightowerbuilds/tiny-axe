defmodule TinyAxe.AgentDispatchTest do
  @moduledoc """
  Agents that dispatch agents (`TinyAxe.Agent.Dispatch`): the gate's
  `dispatch_agents` tool, called over HTTP as a driver would, with the
  sub-agents run by the fake `claude` (test/support/fake_cli), each reaching
  a fake MCP server through a gate task of its own. And how the TUI shows
  them.
  """

  # Swaps the app-wide model roles and the dispatch deadline, so not async.
  use ExUnit.Case, async: false

  alias TinyAxe.{Agent, MCP, TUI, Tools}
  alias TinyAxe.Tools.Gate

  @server Path.expand("../support/fake_mcp/server", __DIR__)
  @keys ~w(models dispatch_timeout code_check web_search)a

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

  ## Helpers

  # An agent's own task, driven by Claude, as Agent.run opens it.
  defp parent(server) do
    me = self()

    {:ok, task} =
      Gate.open_task(&send(me, {:event, &1}),
        servers: [server],
        objective: "the user's request"
      )

    on_exit(fn -> Gate.close_task(task.id) end)
    assert Gate.driven_by(task.id, {:claude, "haiku"})
    task
  end

  defp rpc(task, method, params) do
    Req.post!(task.url,
      json: %{jsonrpc: "2.0", id: 1, method: method, params: params},
      headers: %{"authorization" => "Bearer #{task.token}"},
      receive_timeout: 60_000,
      retry: false
    ).body["result"]
  end

  defp names(task), do: for(t <- rpc(task, "tools/list", %{})["tools"], do: t["name"])

  defp parts(objectives), do: %{"tasks" => Enum.map(objectives, &%{"objective" => &1})}

  defp dispatch(task, objectives),
    do: rpc(task, "tools/call", %{name: "dispatch_agents", arguments: parts(objectives)})

  defp text(%{"content" => [%{"text" => t} | _]}), do: t

  defp events do
    receive do
      {:event, e} -> [e | events()]
    after
      0 -> []
    end
  end

  # The sub-agents' own gate tasks, from their drivers' start events.
  defp sub_tasks(events), do: for({:subagent, _, {:agent, %{task: id}}} <- events, do: id)

  defp echo(server, text), do: ~s(SCENARIO:tool:#{server}__echo:{"text":"#{text}"})

  defp pid_file,
    do: Path.join(System.tmp_dir!(), "tiny_axe_fake_cli_#{System.unique_integer([:positive])}")

  defp wait_for(file, tries \\ 200) do
    cond do
      File.exists?(file) and File.read!(file) != "" -> :ok
      tries == 0 -> flunk("the fake CLI never started")
      true -> Process.sleep(50) && wait_for(file, tries - 1)
    end
  end

  defp assert_dead(file, tries \\ 100) do
    pid = File.read!(file)

    case System.cmd("kill", ["-0", pid], stderr_to_stdout: true) do
      {_, 0} when tries > 0 ->
        Process.sleep(50)
        assert_dead(file, tries - 1)

      {_, status} ->
        File.rm(file)
        assert status != 0, "the sub-agent's CLI (OS pid #{pid}) is still running"
    end
  end

  defp assert_closed(id, tries \\ 100) do
    cond do
      GenServer.call(Gate, {:get, id}) == nil -> :ok
      tries == 0 -> flunk("the sub-agent's gate task #{id} is still open")
      true -> Process.sleep(50) && assert_closed(id, tries - 1)
    end
  end

  ## The tool

  describe "who is offered dispatch_agents" do
    test "an agent's own task driven by Claude; never a sub-agent's, nor the local model's", %{
      server: s
    } do
      me = self()
      open = fn opts -> Gate.open_task(&send(me, {:event, &1}), [servers: [s]] ++ opts) end

      {:ok, top} = open.([])
      refute "dispatch_agents" in names(top)
      assert Gate.driven_by(top.id, {:claude, "haiku"})
      assert "dispatch_agents" in names(top)

      {:ok, local} = open.([])
      refute Gate.driven_by(local.id, {:ollama, "local-test"})
      refute "dispatch_agents" in names(local)

      {:ok, sub} = open.(depth: 1, parent: top.id)
      refute Gate.driven_by(sub.id, {:claude, "haiku"})
      refute "dispatch_agents" in names(sub)

      # Called anyway, it doesn't exist for a sub-agent.
      result = rpc(sub, "tools/call", %{name: "dispatch_agents", arguments: parts(["x"])})
      assert result["isError"]
      assert text(result) =~ "there's no tool called dispatch_agents"

      Enum.each([top, local, sub], &Gate.close_task(&1.id))
    end

    test "the system prompt explains it only when it's offered", %{server: s} do
      assert Agent.system_prompt([s], "", dispatch: true) =~ "dispatch_agents"
      refute Agent.system_prompt([s], "") =~ "dispatch_agents"

      # An agent run driven by Claude gets it.
      models = Application.get_env(:tiny_axe, :models, [])
      Application.put_env(:tiny_axe, :models, Keyword.put(models, :agent, {:claude, "haiku"}))
      me = self()
      Agent.run([], "Hello", &send(me, {:event, &1}), remote: :allowed)
      [reply] = for {:done, text} <- events(), do: JSON.decode!(text)
      args = reply["args"]
      system = args |> Enum.drop_while(&(&1 != "--system-prompt")) |> Enum.at(1)
      assert system =~ "dispatch_agents"
    end
  end

  describe "dispatching" do
    test "runs each part as a sub-agent with its own gate task, and returns every answer", %{
      server: s
    } do
      task = parent(s)
      before = length(usage_lines("subagent"))
      result = dispatch(task, [echo(s, "one"), echo(s, "two"), echo(s, "three")])

      refute result["isError"]
      # Each sub-agent's tokens are counted for /token, as a sub-agent's.
      Process.sleep(50)
      assert length(usage_lines("subagent")) - before == 3
      report = text(result)
      assert report =~ "3 sub-agents ran (3 done)"

      for {word, n} <- Enum.with_index(~w(one two three), 1) do
        assert report =~ "## Agent #{n}: done\nTask: #{echo(s, word)}"
        assert report =~ "echo: #{word}"
      end

      # A sub-agent's own prompt never offers it.
      refute report =~ "dispatch_agents"

      events = events()

      for n <- 1..3 do
        assert {:subagent, %{n: ^n}, :started} =
                 Enum.find(events, &match?({_, %{n: ^n}, :started}, &1))

        assert {:subagent,
                %{
                  n: n,
                  objective: Enum.at([echo(s, "one"), echo(s, "two"), echo(s, "three")], n - 1)
                }, {:finished, :done}} in events
      end

      assert [_, _, _] = for({:subagent, _, {:tool_call, %{class: :read}}} <- events, do: 1)
      # Their text never reaches the parent's notify as its own.
      refute Enum.any?(events, &match?({:delta, _}, &1))
      refute Enum.any?(events, &match?({:subagent, _, {:delta, _}}, &1))

      # Each journaled as a task of its own, naming the parent, and closed.
      subs = sub_tasks(events)
      assert length(Enum.uniq(subs)) == 3

      for id <- subs do
        echo = "#{s}__echo"
        assert [%{"tool" => ^echo, "decision" => "ran"}] = Tools.Journal.read(id)
        info = JSON.decode!(File.read!(Path.join(Tools.Journal.dir(id), "task.json")))
        assert info["parent"] == task.id
        assert info["objective"] == "the user's request"
        assert info["driver"] == "haiku"
        assert info["part"] =~ "SCENARIO:tool"
        assert GenServer.call(Gate, {:get, id}) == nil
      end

      # The dispatch itself is one call of the parent's.
      assert [%{"tool" => "dispatch_agents", "decision" => "ran"}] = Tools.Journal.read(task.id)
    end

    test "one part failing doesn't sink the rest", %{server: s} do
      task = parent(s)

      report =
        text(dispatch(task, ["SCENARIO:garbage", echo(s, "fine"), "SCENARIO:not_logged_in"]))

      assert report =~ "3 sub-agents ran"
      assert report =~ "## Agent 1: error"
      assert report =~ "## Agent 2: done"
      assert report =~ "echo: fine"
      assert report =~ "## Agent 3: error"
      assert report =~ "not logged in"

      events = events()
      assert {:subagent, %{n: 1, objective: "SCENARIO:garbage"}, {:finished, :error}} in events
    end

    test "more than 4 parts, or none, are refused with the reason", %{server: s} do
      task = parent(s)

      result = dispatch(task, for(n <- 1..5, do: "part #{n}"))
      assert result["isError"]
      assert text(result) =~ "takes at most 4 tasks, not 5"

      result = rpc(task, "tools/call", %{name: "dispatch_agents", arguments: %{"tasks" => []}})
      assert text(result) =~ "needs at least one task"

      result =
        rpc(task, "tools/call", %{
          name: "dispatch_agents",
          arguments: %{"tasks" => [%{"context" => "no objective"}]}
        })

      assert text(result) =~ ~s(needs an "objective")

      refute Enum.any?(events(), &match?({:subagent, _, _}, &1))
    end

    test "parts run at once; one still working at the deadline is stopped and reported", %{
      server: s
    } do
      Application.put_env(:tiny_axe, :dispatch_timeout, 15_000)
      task = parent(s)
      files = [pid_file(), pid_file()]
      me = self()

      call =
        Task.async(fn ->
          send(me, {:result, dispatch(task, Enum.map(files, &"SCENARIO:sleep:#{&1}"))})
        end)

      # Both sub-agents' CLIs are running at the same time.
      Enum.each(files, &wait_for/1)

      Task.await(call, 30_000)
      assert_received {:result, result}
      report = text(result)
      assert report =~ "2 sub-agents ran (2 timed out)"
      assert report =~ "## Agent 1: timed out"
      assert report =~ "didn't finish within 15 seconds, so it was stopped"

      events = events()

      assert {:subagent, %{n: 2, objective: "SCENARIO:sleep:#{Enum.at(files, 1)}"},
              {:finished, :timed_out}} in events

      # Their CLIs are gone, and so are their gate tasks.
      Enum.each(files, &assert_dead/1)
      Enum.each(sub_tasks(events), &assert_closed/1)
    end

    test "a sub-agent's outward call asks the user, through the parent's notify", %{server: s} do
      task = parent(s)
      me = self()
      note = ~s(SCENARIO:tool:#{s}__send_note:{"to":"Sam","text":"hi"})
      call = Task.async(fn -> send(me, {:result, dispatch(task, [echo(s, "a"), note])}) end)

      assert_receive {:event, {:subagent, %{n: 2}, {:tool_approval, ask}}}, 30_000
      assert ask.tool == "#{s}__send_note"
      send(ask.reply_to, {:tool_answer, ask.ref, :once})

      Task.await(call, 30_000)
      assert_received {:result, result}
      assert text(result) =~ "2 sub-agents ran (2 done)"
    end
  end

  test "cancelling the run stops every sub-agent, their CLIs and their gate tasks", %{server: s} do
    files = [pid_file(), pid_file()]
    me = self()

    # The run's process, like the TUI's request task: it owns the parent task.
    {:ok, owner} =
      Task.start(fn ->
        {:ok, task} =
          Gate.open_task(&send(me, {:event, &1}), servers: [s], objective: "two sites")

        Gate.driven_by(task.id, {:claude, "haiku"})
        send(me, {:parent, task})
        Process.sleep(:infinity)
      end)

    assert_receive {:parent, task}, 5_000

    # The driver's call, in the gate's HTTP process as a real one is.
    call = Task.async(fn -> dispatch(task, Enum.map(files, &"SCENARIO:sleep:#{&1}")) end)
    Enum.each(files, &wait_for/1)
    subs = sub_tasks(events())
    assert length(subs) == 2

    Process.exit(owner, :kill)

    Enum.each(files, &assert_dead/1)
    Enum.each(subs, &assert_closed/1)

    # The call itself ends now, not at the deadline.
    report = text(Task.await(call, 15_000))
    assert report =~ "## Agent 1: error"
    assert report =~ "it was stopped"
  end

  ## The TUI

  describe "the TUI" do
    defp draw(state) do
      terminal = ExRatatui.init_test_terminal(110, 32)
      ExRatatui.draw(terminal, TUI.render(state, %ExRatatui.Frame{width: 110, height: 32}))
      ExRatatui.get_buffer_content(terminal)
    end

    defp ask(tool) do
      %{
        tool: tool,
        server: "notes",
        description: "Sends a note.",
        args: %{"to" => "Sam"},
        class: :outward,
        reply_to: self(),
        ref: make_ref()
      }
    end

    test "marks sub-agents' lines, keeps their text out, and queues their questions saying who asks" do
      {:ok, state} = TUI.mount(test_mode: {110, 32})
      id = make_ref()
      pid = spawn(fn -> Process.sleep(:infinity) end)
      state = %{state | run: {id, pid}, transcript: [{:user, "check two shops"}]}

      event = fn state, e ->
        {:noreply, state} = TUI.handle_info({:pipeline, id, e}, state)
        state
      end

      one = %{n: 1, objective: "check shop A"}
      two = %{n: 2, objective: "check shop B"}

      call = %{
        tool: "browser__browser_navigate",
        class: :read,
        args: %{"url" => "https://b.test"}
      }

      state =
        state
        |> event.({:subagent, two, :started})
        |> event.({:subagent, two, {:agent, %{driver: "Claude haiku", servers: [], task: "t"}}})
        |> event.({:subagent, two, {:tool_call, call}})
        |> event.({:subagent, two, {:delta, "partial text"}})
        |> event.({:subagent, two, {:done, "its answer"}})
        |> event.({:subagent, two, {:finished, :timed_out}})

      lines = for {:meta, line} <- state.transcript, do: line
      assert "🤖 agent 2 started: check shop B" in lines
      assert Enum.any?(lines, &String.starts_with?(&1, "agent 2 · 🔧 browser__browser_navigate"))
      assert "agent 2 finished (timed out)" in lines
      # Its text and answer aren't the parent's: the run goes on.
      assert state.streaming in [nil, ""]
      refute Enum.any?(state.transcript, &match?({:assistant, _}, &1))
      assert state.run == {id, pid}

      first = ask("notes__send")
      second = ask("notes__post")

      state =
        state
        |> event.({:subagent, two, {:tool_approval, first}})
        |> event.({:subagent, one, {:tool_approval, second}})

      assert %{from: "agent 2", run: ^id} = state.tool_ask
      assert [{:tool_ask, %{from: "agent 1", run: ^id}}] = state.waiting
      assert draw(state) =~ "asked by agent 2"

      # Cancelling the run refuses both, so the sub-agents' calls let go.
      state = TUI.Run.cancel(state)
      first_ref = first.ref
      second_ref = second.ref
      assert_received {:tool_answer, ^first_ref, :deny}
      assert_received {:tool_answer, ^second_ref, :deny}
      assert state.tool_ask == nil and state.waiting == []
    end
  end

  # Calls TinyAxe.Usage has on record, of a kind (for /token).
  defp usage_lines(kind) do
    TinyAxe.Usage.summary()

    case File.read(TinyAxe.Usage.file()) do
      {:ok, data} ->
        data
        |> String.split("\n", trim: true)
        |> Enum.map(&JSON.decode!/1)
        |> Enum.filter(&(&1["kind"] == kind))

      _ ->
        []
    end
  end
end
