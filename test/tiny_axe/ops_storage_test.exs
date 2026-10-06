defmodule TinyAxe.OpsStorageTest do
  use ExUnit.Case, async: false

  alias TinyAxe.Ops
  alias TinyAxe.Ops.Journal

  @moduletag :tmp_dir
  @moduletag :capture_log

  setup %{tmp_dir: dir} do
    home = Path.join(dir, "home")
    trash = Path.join(dir, "Trash")
    File.mkdir_p!(home)

    for {key, value} <- [fs_root: home, trash_dir: trash, state_dir: Path.join(dir, "state")] do
      previous = Application.get_env(:tiny_axe, key)
      Application.put_env(:tiny_axe, key, value)
      on_exit(fn -> Application.put_env(:tiny_axe, key, previous) end)
    end

    %{home: home, trash: trash, marker: Path.join(dir, "marker")}
  end

  test "a trash metadata error returns instead of retrying forever", %{home: home, marker: marker} do
    # Valid on this filesystem, but adding .trashinfo exceeds its name limit.
    path = Path.join(home, String.duplicate("x", 250))
    File.write!(path, "keep me")

    task = Task.async(fn -> Ops.step(%{op: :trash, path: path}, marker) end)
    result = Task.yield(task, 2_000) || Task.shutdown(task, :brutal_kill)

    assert {:ok, {:error, message}} = result
    assert message =~ "enametoolong"
    assert File.read!(path) == "keep me"
    refute File.exists?(marker)
  end

  test "a failed recovery marker leaves the source and releases the Trash reservation", %{
    home: home,
    trash: trash,
    marker: marker
  } do
    path = Path.join(home, "notes")
    File.write!(path, "keep me")
    File.mkdir_p!(marker)

    assert {:error, _} = Ops.step(%{op: :trash, path: path}, marker)
    assert File.read!(path) == "keep me"
    assert File.ls!(Path.join(trash, "info")) == []
    assert File.ls!(Path.join(trash, "files")) == []
  end

  test "an occupied metadata filename is skipped without changing its owner", %{
    home: home,
    trash: trash,
    marker: marker
  } do
    path = Path.join(home, "notes")
    File.write!(path, "notes")
    File.mkdir_p!(Path.join(trash, "info"))
    occupied = Path.join(trash, "info/notes.trashinfo")
    File.write!(occupied, "reserved by another operation")

    assert {:ok, [record]} = Ops.step(%{op: :trash, path: path}, marker)
    assert record["to"] == Path.join(trash, "files/notes.1")
    assert File.read!(occupied) == "reserved by another operation"
    assert File.read!(record["to"]) == "notes"
  end

  test "pruning preserves an old plan if its discarded files cannot reach system Trash", %{
    trash: trash
  } do
    {:ok, id} = Journal.create("old plan", [])
    :ok = Journal.event(id, %{t: "undone", notes: []})
    {:ok, plan} = Journal.load(id)
    kept_file = Path.join(plan.dir, "trash/notes")
    File.mkdir_p!(Path.dirname(kept_file))
    File.write!(kept_file, "irreplaceable")

    journal = Path.join(plan.dir, "journal.jsonl")
    old_at = DateTime.utc_now() |> DateTime.add(-40, :day) |> DateTime.to_iso8601()
    File.write!(journal, String.replace(File.read!(journal), plan.at, old_at, global: false))

    # The system Trash cannot be created: a file occupies its path.
    File.write!(trash, "blocked")
    restart_journal()
    assert File.read!(kept_file) == "irreplaceable"
    assert File.exists?(journal)

    # Once storage works again, the retained plan can be pruned on startup.
    File.rm!(trash)
    restart_journal()
    refute File.exists?(plan.dir)
    assert File.read!(Path.join(trash, "files/notes")) == "irreplaceable"
  end

  defp restart_journal do
    :ok = Supervisor.terminate_child(TinyAxe.Ops.Supervisor, Journal)
    {:ok, _} = Supervisor.restart_child(TinyAxe.Ops.Supervisor, Journal)
  end
end
