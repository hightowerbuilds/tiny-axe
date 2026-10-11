defmodule TinyAxe.AgentShellTest do
  @moduledoc """
  The agent's shell (`TinyAxe.Agent.ShellTool`): the gate's `shell_run`
  tool, called over HTTP as a driver would. Commands that only look run at
  once; others wait for the user's answer, every time.
  """

  # Sets global config (the fake home and project), so not async.
  use ExUnit.Case, async: false

  alias TinyAxe.{Agent, Shell}
  alias TinyAxe.Agent.ShellTool
  alias TinyAxe.Tools.Gate

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    TinyAxe.Location.reset()
    home = Path.join(dir, "home")
    project = Path.join(home, "project")
    File.mkdir_p!(Path.join(home, ".hidden"))
    File.mkdir_p!(project)
    File.write!(Path.join(project, "notes.txt"), "the first line\n")

    for {key, value} <- [fs_root: home, project_dir: project, agent_shell: true] do
      previous = Application.get_env(:tiny_axe, key)
      Application.put_env(:tiny_axe, key, value)

      on_exit(fn ->
        if previous == nil,
          do: Application.delete_env(:tiny_axe, key),
          else: Application.put_env(:tiny_axe, key, previous)
      end)
    end

    TinyAxe.Location.set(project)
    %{home: home, project: project}
  end

  ## Helpers

  # An agent's task as Agent.run opens it, driven by Claude unless `driven: false`.
  defp task(opts \\ []) do
    me = self()
    {:ok, task} = Gate.open_task(&send(me, {:event, &1}), servers: [], objective: "check things")
    on_exit(fn -> Gate.close_task(task.id) end)
    if Keyword.get(opts, :driven, true), do: Gate.driven_by(task.id, {:claude, "haiku"})
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

  defp shell_run(task, args), do: rpc(task, "tools/call", %{name: "shell_run", arguments: args})

  # The call runs in its own process, so the test can answer its question.
  defp shell_run_async(task, args), do: Task.async(fn -> shell_run(task, args) end)

  defp text(%{"content" => [%{"text" => t} | _]}), do: t

  defp approval do
    assert_receive {:event, {:tool_approval, ask}}, 5_000
    ask
  end

  defp bwrap(_context), do: if(Shell.available?(), do: :ok, else: {:skip, "bwrap not installed"})

  describe "who gets it" do
    test "every agent task once its driver is known, sub-agents' too" do
      assert "shell_run" in names(task())
      refute "shell_run" in names(task(driven: false))

      {:ok, sub} = Gate.open_task(fn _ -> :ok end, servers: [], depth: 1, parent: "p")
      on_exit(fn -> Gate.close_task(sub.id) end)
      refute Gate.driven_by(sub.id, {:claude, "haiku"})
      assert "shell_run" in names(sub)
    end

    test "not when it's switched off" do
      Application.put_env(:tiny_axe, :agent_shell, false)
      refute "shell_run" in names(task())
    end

    test "the agent's prompt says how commands run, and that it runs them itself" do
      prompt = Agent.system_prompt([], "", shell: true)
      assert prompt =~ "You can run shell commands yourself with shell_run"
      assert prompt =~ "Commands that only look run straight away"
      assert prompt =~ "sudo"
      refute Agent.system_prompt([], "", shell: false) =~ "shell_run"
    end
  end

  describe "ShellTool.check/1" do
    test "a command line that only looks is read; anything else is outward", %{project: p} do
      assert {:read, _, %{command: "ls -la", dir: ^p, read_only?: true}} =
               ShellTool.check(%{"command" => "  ls -la "})

      assert {:outward, reason, %{read_only?: false}} =
               ShellTool.check(%{"command" => "touch made.txt"})

      assert reason =~ "can change things"
    end

    test "cwd is relative to the current folder, ~/…, or absolute", %{home: home, project: p} do
      File.mkdir_p!(Path.join(p, "web"))
      assert {:read, _, %{dir: dir}} = ShellTool.check(%{"command" => "ls", "cwd" => "web"})
      assert dir == Path.join(p, "web")
      assert {:read, _, %{dir: ^home}} = ShellTool.check(%{"command" => "ls", "cwd" => home})
    end

    test "refuses what the Commander refuses, and says what to do with cwd", %{home: home} do
      assert {:refused, why} = ShellTool.check(%{"command" => "sudo ls"})
      assert why =~ "sudo"

      assert {:refused, why} = ShellTool.check(%{"command" => "pacman -S jq"})
      assert why =~ "system package manager"

      assert {:refused, why} = ShellTool.check(%{"command" => "touch x", "cwd" => home})
      assert why =~ "home folder itself"
      assert why =~ ~s("cwd")
      refute why =~ ~s("dir")

      assert {:refused, _} = ShellTool.check(%{"command" => "ls", "cwd" => "missing"})
      assert {:refused, _} = ShellTool.check(%{"command" => "  "})
      assert {:refused, _} = ShellTool.check(%{"command" => 5})
    end
  end

  describe "running" do
    setup :bwrap

    test "a command that only looks runs at once and returns its output" do
      task = task()
      result = shell_run(task, %{"command" => "cat notes.txt"})

      assert result["isError"] == false
      assert text(result) =~ "Ran `cat notes.txt`"
      assert text(result) =~ "read-only, without asking"
      assert text(result) =~ "the first line"
      refute_received {:event, {:tool_approval, _}}
    end

    test "a failing command says so and is an error" do
      result = shell_run(task(), %{"command" => "ls no-such-file"})
      assert result["isError"] == true
      assert text(result) =~ "exit 2"
    end

    test "a command that changes things asks first, never for the session", %{project: p} do
      call = shell_run_async(task(), %{"command" => "touch made.txt"})
      ask = approval()

      assert ask.shell.command == "touch made.txt"
      assert ask.shell.dir =~ "project"
      assert ask.session_ok == false
      refute File.exists?(Path.join(p, "made.txt"))

      send(ask.reply_to, {:tool_answer, ask.ref, :once})
      result = Task.await(call, 30_000)

      assert text(result) =~ "after the user approved"
      assert File.exists?(Path.join(p, "made.txt"))
    end

    test "a command the user refuses doesn't run", %{project: p} do
      call = shell_run_async(task(), %{"command" => "touch refused.txt"})
      ask = approval()
      send(ask.reply_to, {:tool_answer, ask.ref, :deny})
      result = Task.await(call, 30_000)

      assert result["isError"] == true
      assert text(result) =~ "the user said no to this command"
      refute File.exists?(Path.join(p, "refused.txt"))
    end

    test "a refused command never reaches the user" do
      result = shell_run(task(), %{"command" => "sudo touch x"})

      assert result["isError"] == true
      assert text(result) =~ "tiny-axe stopped this call"
      refute_received {:event, {:tool_approval, _}}
    end

    test "is stopped when the run that asked for it is cancelled", %{project: p} do
      me = self()

      # The run: it opens the task (and so owns it), then waits to be killed.
      run =
        spawn(fn ->
          {:ok, task} = Gate.open_task(&send(me, {:event, &1}), servers: [])
          Gate.driven_by(task.id, {:claude, "haiku"})
          send(me, {:task, task})
          Process.sleep(:infinity)
        end)

      assert_receive {:task, task}, 5_000
      started = System.monotonic_time(:millisecond)
      call = shell_run_async(task, %{"command" => "sleep 30 && touch late.txt"})
      ask = approval()
      send(ask.reply_to, {:tool_answer, ask.ref, :once})

      Process.sleep(500)
      Process.exit(run, :kill)
      Task.await(call, 20_000)

      assert System.monotonic_time(:millisecond) - started < 15_000
      refute File.exists?(Path.join(p, "late.txt"))
    end
  end
end
