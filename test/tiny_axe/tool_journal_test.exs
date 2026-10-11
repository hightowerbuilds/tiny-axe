defmodule TinyAxe.ToolJournalTest do
  @moduledoc """
  The task journal's folders (`TinyAxe.Tools.Journal`): pruning never takes
  an open task's folder or one written in the last hour (another tiny-axe
  may be using it), and writing never raises.
  """

  # Points the state folder elsewhere for the test, so not async.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias TinyAxe.Tools.Journal

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    previous = Application.get_env(:tiny_axe, :state_dir)
    Application.put_env(:tiny_axe, :state_dir, dir)
    on_exit(fn -> Application.put_env(:tiny_axe, :state_dir, previous) end)
    %{root: Path.join(dir, "tasks")}
  end

  # A task folder last written two hours ago.
  defp old_task(root, id) do
    path = Path.join(root, id)
    File.mkdir_p!(path)
    File.write!(Path.join(path, "calls.jsonl"), "{}\n")
    two_hours_ago = System.os_time(:second) - 7200
    File.touch!(Path.join(path, "calls.jsonl"), two_hours_ago)
    File.touch!(path, two_hours_ago)
  end

  test "pruning keeps the newest 50, and never an open task's folder or a recent one", %{
    root: root
  } do
    for i <- 10..69, do: old_task(root, "20200101-0000#{i}-1")

    # The oldest two by name: one still open, one written just now.
    open = "20200101-000010-1"
    recent = "20200101-000011-1"
    File.write!(Path.join([root, recent, "calls.jsonl"]), "{}\n", [:append])

    Journal.start("20991231-235959-1", [open])
    left = File.ls!(root)

    assert open in left and recent in left
    # 50 newest (the new task among them), plus the two kept.
    assert length(left) == 52
    refute "20200101-000012-1" in left
  end

  test "writing never raises: a removed folder is made again, other failures are logged", %{
    root: root
  } do
    Journal.start("t1")
    File.rm_rf!(Path.join(root, "t1"))
    assert :ok = Journal.append("t1", %{tool: "x"})
    assert [%{"tool" => "x"}] = Journal.read("t1")

    # The task's folder can't be made: a file stands where it should be.
    File.write!(Path.join(root, "t2"), "not a folder")

    assert capture_log(fn -> assert :ok = Journal.append_decision("t2", %{id: "d"}) end) =~
             "couldn't write the journal of task t2"
  end
end
