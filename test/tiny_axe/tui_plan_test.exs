defmodule TinyAxe.TUIPlanTest do
  @moduledoc "The file-plan popups, driven through the real Runner on a fake home."

  # Global config and the app's Runner, so not async.
  use ExUnit.Case, async: false

  alias ExRatatui.Event
  alias TinyAxe.{Ops, TUI}
  alias TinyAxe.Ops.Runner

  @size {110, 40}
  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    home = Path.join(dir, "home")

    for {key, value} <- [fs_root: home, state_dir: Path.join(dir, "state"), ops_step_hook: nil] do
      previous = Application.get_env(:tiny_axe, key)
      Application.put_env(:tiny_axe, key, value)
      on_exit(fn -> Application.put_env(:tiny_axe, key, previous) end)
    end

    for name <- ~w(a.pdf b.pdf) do
      path = Path.join(home, "Downloads/#{name}")
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, name)
    end

    {:ok, ops} =
      Ops.expand([
        %{
          "op" => "move",
          "from" => Path.join(home, "Downloads/*.pdf"),
          "to" => Path.join(home, "Papers/")
        }
      ])

    notes = %{
      op: :write,
      path: Path.join(home, "notes.md"),
      about: "notes",
      sources: [],
      content: "# Notes\n\nPapers moved.\n",
      old: nil,
      old_hash: nil,
      check: 0.9
    }

    %{home: home, plan: %{request: "file the papers", ops: ops ++ [notes], review: 0.87}}
  end

  defp draw(state) do
    {w, h} = @size
    terminal = ExRatatui.init_test_terminal(w, h)
    ExRatatui.draw(terminal, TUI.render(state, %ExRatatui.Frame{width: w, height: h}))
    ExRatatui.get_buffer_content(terminal)
  end

  defp key(state, code, mods \\ []) do
    {:noreply, state} =
      TUI.handle_event(%Event.Key{code: code, kind: "press", modifiers: mods}, state)

    state
  end

  # Feeds the Runner's messages to the TUI until the job ends.
  defp settle(state) do
    receive do
      {:ops, _, _} = msg ->
        {:noreply, state} = TUI.handle_info(msg, state)
        if state.ops_job, do: settle(state), else: state
    after
      5_000 -> flunk("the plan never finished")
    end
  end

  test "approving a plan carries it out, and ctrl+z undoes it after confirming", %{
    home: home,
    plan: plan
  } do
    {:ok, state} = TUI.mount(test_mode: @size)
    id = make_ref()
    state = %{state | run: {id, self()}, pending_prompt: plan.request}
    {:noreply, state} = TUI.handle_info({:pipeline, id, {:plan, plan}}, state)
    {:noreply, state} = TUI.handle_info({:pipeline, id, {:done, "Plan ready."}}, state)

    screen = draw(state)
    assert screen =~ "carry out this plan?"
    assert screen =~ "reviewer: 87%"
    assert screen =~ "Downloads/a.pdf"
    assert screen =~ "+ # Notes"

    # Typing doesn't leak into the prompt while the plan is up.
    state = key(state, "x")
    assert state.pending_plan

    state = state |> key("y") |> settle()
    assert File.exists?(Path.join(home, "Papers/a.pdf"))
    assert File.read!(Path.join(home, "notes.md")) =~ "Papers moved."
    assert {:meta, "✓ done: 3 steps · ctrl+z undoes it"} in state.transcript

    state = key(state, "z", ["ctrl"])
    assert draw(state) =~ "Undo this plan?"

    state = state |> key("y") |> settle()
    assert File.exists?(Path.join(home, "Downloads/a.pdf"))
    refute File.exists?(Path.join(home, "notes.md"))
    assert {:meta, "↶ undone"} in state.transcript
  end

  test "n cancels a plan without touching anything", %{home: home, plan: plan} do
    {:ok, state} = TUI.mount(test_mode: @size)
    state = %{state | pending_plan: plan}
    state = key(state, "n")

    assert state.pending_plan == nil
    assert File.exists?(Path.join(home, "Downloads/a.pdf"))
    assert {:meta, "plan cancelled; nothing changed"} in state.transcript
  end

  test "an interrupted plan is offered for recovery at start-up", %{home: home, plan: plan} do
    test = self()

    Application.put_env(:tiny_axe, :ops_step_hook, fn _id, i ->
      if i == 1,
        do:
          (
            send(test, {:paused, self()})
            Process.sleep(:infinity)
          )
    end)

    {:ok, id} = Runner.run(plan.request, plan.ops, self())
    assert_receive {:paused, task}, 5_000
    Process.exit(task, :kill)
    assert_receive {:ops, ^id, {:interrupted, _}}, 5_000
    Application.put_env(:tiny_axe, :ops_step_hook, nil)

    # A fresh TUI, as after a restart, finds it in the journal.
    {:ok, state} = TUI.mount(test_mode: @size)
    assert state.recovery.id == id
    screen = draw(state)
    assert screen =~ "A plan was interrupted after 1 of 3 steps."
    assert screen =~ "r roll back"

    state = state |> key("r") |> settle()
    assert File.exists?(Path.join(home, "Downloads/a.pdf"))
    refute File.exists?(Path.join(home, "Papers"))
    assert {:meta, "↶ rolled back"} in state.transcript
  end
end
