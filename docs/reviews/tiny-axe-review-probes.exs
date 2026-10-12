defmodule TinyAxe.ReviewProbes do
  use ExUnit.Case, async: false
  alias TinyAxe.{Decider, Location, Model, Pipeline}
  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    for {key, value} <- [fs_root: dir, project_dir: dir, code_check: false,
                        web_search: false, escalate: false, num_ctx: 8192] do
      Application.put_env(:tiny_axe, key, value)
    end
    Location.reset()
    %{dir: dir}
  end

  defp run(prompt, history \\ []) do
    parent = self()
    Pipeline.run(history, prompt, &send(parent, {:review_event, &1}))
    Stream.repeatedly(fn ->
      receive do
        {:review_event, event} -> event
      after
        0 -> :end
      end
    end) |> Enum.take_while(&(&1 != :end))
  end

  test "a file truncated by final context fitting is still offered as a whole-file edit", %{dir: dir} do
    original = "# start\n" <> String.duplicate("# ordinary filler for this source file\n", 260) <> "KEEP_THIS_TAIL = True\n"
    File.write!(Path.join(dir, "demo.py"), original)
    owner = self()
    Model.Script.script(fn messages, _ ->
      material = Enum.map_join(messages, "\n", & &1.content)
      send(owner, {:material, material})
      "```python demo.py\ndef important():\n    return 1\n```"
    end)
    Decider.Script.script(fn
      :kind, _, _ -> :code
      key, _, _ when key in [:files, :change, :addresses] -> 0.99
      _, _, _ -> nil
    end)
    history = for role <- ["user", "assistant", "user", "assistant"],
      do: %{role: role, content: String.duplicate("prior context ", 240)}
    events = run("Please update @demo.py", history)
    assert_receive {:material, material}
    assert material =~ "cut to fit"
    refute material =~ "KEEP_THIS_TAIL"
    assert Enum.any?(events, &match?({:edits, [_]}, &1))
    refute Enum.any?(events, &match?({:edit_refused, _}, &1))
    assert File.read!(Path.join(dir, "demo.py")) == original
    IO.puts("REVIEW_PROBE context: source tail absent from model input; whole-file replacement still offered; no file applied")
  end

  test "another chat changing global location changes a waiting task's default shell directory", %{dir: dir} do
    a = Path.join(dir, "project-a")
    b = Path.join(dir, "project-b")
    File.mkdir_p!(a)
    File.mkdir_p!(b)
    Location.set(a)
    parent = self()
    task = Task.async(fn ->
      initial = Location.current()
      send(parent, :started_in_a)
      receive do
        :continue ->
          {:read, _, plan} = TinyAxe.Agent.ShellTool.check(%{"command" => "pwd"})
          {initial, plan.dir}
      end
    end)
    assert_receive :started_in_a
    Location.set(b)
    send(task.pid, :continue)
    assert Task.await(task) == {a, b}
    IO.puts("REVIEW_PROBE location: task starts in project-a; subsequent default shell plan uses project-b after shared location changes")
  end

  test "a known false execution claim is delivered after retry exhaustion" do
    answer = "I ran npm install for you."
    Model.Script.script(fn _, _ -> answer end)
    Decider.Script.script(fn
      :kind, _, _ -> :question
      :addresses, _, _ -> 0.9
      :false_claim, _, _ -> 0.99
      _, _, _ -> nil
    end)
    events = run("Explain installing dependencies")
    assert {:done, answer} in events
    assert Enum.count(events, &match?({:attempt, _}, &1)) == 3
    IO.puts("REVIEW_PROBE honesty: verifier flags false claim at 0.99 on all 3 attempts; final answer still says it ran npm install")
  end

  test "history redaction does not remove ordinary passwords or email addresses" do
    example = "Email: person@example.invalid; password: ShortPass!"
    assert TinyAxe.Tools.Redact.secrets(example) == example
    IO.puts("REVIEW_PROBE redaction: synthetic email and short password survive history redaction unchanged")
  end
end
