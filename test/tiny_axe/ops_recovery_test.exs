defmodule TinyAxe.OpsRecoveryTest do
  @moduledoc """
  Crash injection: plans are stopped at an exact step by killing the task, the
  Runner, or the whole application, then recovered from the journal on disk.
  """

  # Global config and the app's named processes, so not async.
  use ExUnit.Case, async: false

  # Crashes here are deliberate; keep their logs out of the test output.
  @moduletag :capture_log

  alias TinyAxe.Ops
  alias TinyAxe.Ops.{Journal, Runner}

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    TinyAxe.Location.reset()
    home = Path.join(dir, "home")

    config = [
      fs_root: home,
      project_dir: Path.join(home, "project"),
      state_dir: Path.join(dir, "state"),
      trash_dir: Path.join(dir, "Trash"),
      ops_step_hook: nil
    ]

    for {key, value} <- config do
      previous = Application.get_env(:tiny_axe, key)
      Application.put_env(:tiny_axe, key, value)
      on_exit(fn -> Application.put_env(:tiny_axe, key, previous) end)
    end

    for name <- ~w(a b c) do
      path = Path.join(home, "Downloads/#{name}.pdf")
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "#{name}\n")
    end

    raw = [
      %{"op" => "mkdir", "path" => Path.join(home, "Papers")},
      %{
        "op" => "move",
        "from" => Path.join(home, "Downloads/*.pdf"),
        "to" => Path.join(home, "Papers")
      }
    ]

    {:ok, ops} = Ops.expand(raw)
    %{home: home, ops: ops, before: snapshot(home)}
  end

  # Every file under home with its contents.
  defp snapshot(home) do
    home
    |> Path.join("**")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Map.new(&{Path.relative_to(&1, home), File.read!(&1)})
  end

  # Pauses the plan when it reaches `step`, handing the test the task's pid.
  defp pause_at(step, run \\ fn -> :ok end) do
    test = self()

    Application.put_env(:tiny_axe, :ops_step_hook, fn _id, i ->
      if i == step do
        run.()
        send(test, {:paused, self()})
        Process.sleep(:infinity)
      end
    end)
  end

  test "a plan runs, and undo puts everything back", %{home: home, ops: ops, before: before} do
    assert {:ok, id} = Runner.run("tidy", ops)
    assert_receive {:ops, ^id, {:finished, 4}}, 5_000
    assert Map.keys(snapshot(home)) == ~w(Papers/a.pdf Papers/b.pdf Papers/c.pdf)

    assert {:ok, ^id} = Runner.undo_last()
    assert_receive {:ops, ^id, {:undone, []}}, 5_000
    assert snapshot(home) == before
    refute File.exists?(Path.join(home, "Papers"))
    assert {:ok, %{status: :undone}} = Journal.load(id)
  end

  test "killing the plan mid-way leaves it interrupted, and rolling back restores the disk",
       %{home: home, ops: ops, before: before} do
    pause_at(2)
    assert {:ok, id} = Runner.run("tidy", ops)
    assert_receive {:paused, task}, 5_000

    Process.exit(task, :kill)
    assert_receive {:ops, ^id, {:interrupted, :killed}}, 5_000

    assert [%{id: ^id, in_progress: 2, done: done}] = Journal.interrupted()
    assert Map.keys(done) == [0, 1]
    # Step 1 (a.pdf) happened; step 2 (b.pdf) began but never ran.
    assert File.exists?(Path.join(home, "Papers/a.pdf"))

    Application.put_env(:tiny_axe, :ops_step_hook, nil)
    assert :ok = Runner.roll_back(id)
    assert_receive {:ops, ^id, {:rolled_back, []}}, 5_000
    assert snapshot(home) == before
    assert Journal.interrupted() == []
  end

  test "a crash in the middle of a move is settled from the disk, then the plan continues",
       %{home: home, ops: ops} do
    # The move of b.pdf happens, then the task dies before journalling it.
    pause_at(2, fn ->
      File.rename!(Path.join(home, "Downloads/b.pdf"), Path.join(home, "Papers/b.pdf"))
    end)

    assert {:ok, id} = Runner.run("tidy", ops)
    assert_receive {:paused, task}, 5_000
    Process.exit(task, :kill)
    assert_receive {:ops, ^id, {:interrupted, :killed}}, 5_000

    Application.put_env(:tiny_axe, :ops_step_hook, nil)
    assert :ok = Runner.continue(id)
    assert_receive {:ops, ^id, {:finished, 1}}, 5_000
    assert Map.keys(snapshot(home)) == ~w(Papers/a.pdf Papers/b.pdf Papers/c.pdf)

    # The settled step was journalled, so undo still covers all of it.
    assert {:ok, %{status: :finished, done: done}} = Journal.load(id)
    assert Map.keys(done) == [0, 1, 2, 3]
  end

  test "if the Runner itself dies, its plan stops with it and is recovered after the restart",
       %{home: home, ops: ops, before: before} do
    pause_at(2)
    runner = Process.whereis(Runner)
    assert {:ok, id} = Runner.run("tidy", ops)
    assert_receive {:paused, task}, 5_000
    ref = Process.monitor(task)

    Process.exit(runner, :kill)

    # The link takes the plan down too: no plan runs unsupervised.
    assert_receive {:DOWN, ^ref, :process, ^task, _}, 5_000
    new_runner = wait_for_restart(Runner, runner)
    assert new_runner != runner

    assert [%{id: ^id}] = Journal.interrupted()
    Application.put_env(:tiny_axe, :ops_step_hook, nil)
    assert :ok = Runner.roll_back(id)
    assert_receive {:ops, ^id, {:rolled_back, _}}, 5_000
    assert snapshot(home) == before
  end

  test "after the whole application stops mid-plan, the plan is found and finished on restart",
       %{home: home, ops: ops} do
    pause_at(3)
    assert {:ok, id} = Runner.run("tidy", ops)
    assert_receive {:paused, _task}, 5_000

    Application.stop(:tiny_axe)
    Application.put_env(:tiny_axe, :ops_step_hook, nil)
    {:ok, _} = Application.ensure_all_started(:tiny_axe)

    assert [%{id: ^id, in_progress: 3}] = Journal.interrupted()
    assert :ok = Runner.continue(id)
    assert_receive {:ops, ^id, {:finished, 1}}, 5_000
    assert Map.keys(snapshot(home)) == ~w(Papers/a.pdf Papers/b.pdf Papers/c.pdf)
  end

  test "a journal line torn by a crash mid-write is ignored", %{ops: ops} do
    pause_at(1)
    assert {:ok, id} = Runner.run("tidy", ops)
    assert_receive {:paused, task}, 5_000
    Process.exit(task, :kill)
    assert_receive {:ops, ^id, {:interrupted, _}}, 5_000

    {:ok, plan} = Journal.load(id)
    File.write!(Path.join(plan.dir, "journal.jsonl"), ~s({"t":"done","st), [:append])

    assert {:ok, %{status: :interrupted, in_progress: 1}} = Journal.load(id)
  end

  test "continuing is refused if the disk changed while tiny-axe was down", %{
    home: home,
    ops: ops
  } do
    pause_at(2)
    assert {:ok, id} = Runner.run("tidy", ops)
    assert_receive {:paused, task}, 5_000
    Process.exit(task, :kill)
    assert_receive {:ops, ^id, {:interrupted, _}}, 5_000

    # Someone puts a file where the plan was going to move c.pdf.
    File.write!(Path.join(home, "Papers/c.pdf"), "a different c\n")

    Application.put_env(:tiny_axe, :ops_step_hook, nil)
    assert :ok = Runner.continue(id)
    assert_receive {:ops, ^id, {:continue_refused, problems}}, 5_000
    assert Enum.any?(problems, &(&1 =~ "Papers/c.pdf already exists"))
    assert File.read!(Path.join(home, "Papers/c.pdf")) == "a different c\n"
  end

  defp wait_for_restart(name, old, tries \\ 50) do
    case Process.whereis(name) do
      pid when is_pid(pid) and pid != old ->
        pid

      _ when tries > 0 ->
        Process.sleep(20)
        wait_for_restart(name, old, tries - 1)
    end
  end

  test "a plan killed while trashing files rolls back, taking them out of the Trash",
       %{home: home, before: before} do
    {:ok, ops} = Ops.expand([%{"op" => "trash", "path" => Path.join(home, "Downloads/*.pdf")}])
    pause_at(2)
    assert {:ok, id} = Runner.run("clear out the pdfs", ops)
    assert_receive {:paused, task}, 5_000
    Process.exit(task, :kill)
    assert_receive {:ops, ^id, {:interrupted, _}}, 5_000

    # a.pdf and b.pdf reached the Trash; c.pdf's step began but never ran.
    trash = Application.get_env(:tiny_axe, :trash_dir)
    assert File.ls!(Path.join(trash, "files")) |> Enum.sort() == ["a.pdf", "b.pdf"]

    Application.put_env(:tiny_axe, :ops_step_hook, nil)
    assert :ok = Runner.roll_back(id)
    assert_receive {:ops, ^id, {:rolled_back, []}}, 5_000
    assert snapshot(home) == before
    assert File.ls!(Path.join(trash, "files")) == []
    assert File.ls!(Path.join(trash, "info")) == []
  end

  test "pruning an old plan moves what undo set aside to the system Trash, not oblivion",
       %{home: home} do
    path = Path.join(home, "notes.md")

    {:ok, id} =
      Runner.run("write notes", [%{op: :write, path: path, content: "hi\n", old_hash: nil}])

    assert_receive {:ops, ^id, {:finished, _}}, 5_000
    assert {:ok, ^id} = Runner.undo_last()
    assert_receive {:ops, ^id, {:undone, []}}, 5_000

    {:ok, plan} = Journal.load(id)
    assert File.read!(Path.join(plan.dir, "trash/notes.md")) == "hi\n"

    # Make the plan 40 days old, then restart the journal, which prunes on start.
    journal = Path.join(plan.dir, "journal.jsonl")
    old_at = DateTime.utc_now() |> DateTime.add(-40, :day) |> DateTime.to_iso8601()
    File.write!(journal, String.replace(File.read!(journal), plan.at, old_at, global: false))
    :ok = Supervisor.terminate_child(TinyAxe.Ops.Supervisor, Journal)
    {:ok, _} = Supervisor.restart_child(TinyAxe.Ops.Supervisor, Journal)

    refute File.exists?(plan.dir)
    trash = Application.get_env(:tiny_axe, :trash_dir)
    assert File.read!(Path.join(trash, "files/notes.md")) == "hi\n"
    assert File.exists?(Path.join(trash, "info/notes.md.trashinfo"))
  end
end
