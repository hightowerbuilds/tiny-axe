defmodule TinyAxe.OpsTest do
  # Sets global config (the fake home), so not async.
  use ExUnit.Case, async: false

  alias TinyAxe.Ops

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    home = Path.join(dir, "home")
    project = Path.join(home, "project")

    for {key, value} <- [fs_root: home, project_dir: project, trash_dir: Path.join(dir, "Trash")] do
      previous = Application.get_env(:tiny_axe, key)
      Application.put_env(:tiny_axe, key, value)
      on_exit(fn -> Application.put_env(:tiny_axe, key, previous) end)
    end

    for file <-
          ~w(Downloads/a.pdf Downloads/b.pdf Downloads/c.txt Documents/notes.md .ssh/id_ed25519 project/mix.exs) do
      path = Path.join(home, file)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "contents of #{file}\n")
    end

    %{home: home, trash: Path.join(dir, "trash"), system_trash: Path.join(dir, "Trash")}
  end

  defp at(home, rel), do: Path.join(home, rel)

  describe "expand/1" do
    test "expands wildcards into a folder the plan makes first", %{home: home} do
      raw = [
        %{"op" => "mkdir", "path" => at(home, "Documents/papers")},
        %{
          "op" => "move",
          "from" => at(home, "Downloads/*.pdf"),
          "to" => at(home, "Documents/papers")
        }
      ]

      assert {:ok,
              [
                %{op: :mkdir},
                %{op: :move, from: a, to: a_to},
                %{op: :move, from: b, to: b_to}
              ]} = Ops.expand(raw)

      assert {a, a_to} == {at(home, "Downloads/a.pdf"), at(home, "Documents/papers/a.pdf")}
      assert {b, b_to} == {at(home, "Downloads/b.pdf"), at(home, "Documents/papers/b.pdf")}
    end

    test "reports every problem in plain words", %{home: home} do
      raw = [
        %{"op" => "move", "from" => at(home, "Downloads/nope.pdf"), "to" => at(home, "x.pdf")},
        %{
          "op" => "copy",
          "from" => at(home, "Downloads/c.txt"),
          "to" => at(home, "Documents/notes.md")
        },
        %{"op" => "move", "from" => at(home, ".ssh/id_ed25519"), "to" => at(home, "key")},
        %{"op" => "write", "path" => "/etc/motd"},
        %{"op" => "delete", "path" => at(home, "Documents")}
      ]

      assert {:error, problems} = Ops.expand(raw)
      assert Enum.any?(problems, &(&1 =~ "Nothing matches"))
      assert Enum.any?(problems, &(&1 =~ "Unknown operation"))

      # Expansion errors come first; fix them and simulation finds the rest.
      raw = Enum.drop(raw, 1) |> Enum.drop(-1)
      assert {:error, problems} = Ops.expand(raw)
      assert Enum.any?(problems, &(&1 =~ "already exists; tiny-axe never overwrites"))
      assert Enum.any?(problems, &(&1 =~ ".ssh/id_ed25519 can't be moved"))
      assert Enum.any?(problems, &(&1 =~ "Can't write /etc/motd"))
    end

    test "sees earlier steps: a file moved away can't be moved again", %{home: home} do
      raw = [
        %{"op" => "move", "from" => at(home, "Downloads/c.txt"), "to" => at(home, "c.txt")},
        %{"op" => "move", "from" => at(home, "Downloads/c.txt"), "to" => at(home, "d.txt")}
      ]

      assert {:error, [problem]} = Ops.expand(raw)
      assert problem =~ "Downloads/c.txt doesn't exist (at that point in the plan)"
    end

    test "refuses to move a folder into itself", %{home: home} do
      raw = [
        %{"op" => "move", "from" => at(home, "Downloads"), "to" => at(home, "Downloads/inner")}
      ]

      assert {:error, [problem]} = Ops.expand(raw)
      assert problem =~ "into itself"
    end
  end

  describe "step/2 and undo_record/2" do
    test "a move goes back", %{home: home, trash: trash} do
      op = %{op: :move, from: at(home, "Downloads/a.pdf"), to: at(home, "Papers/a.pdf")}
      assert {:ok, records} = Ops.step(op, "unused")
      assert File.exists?(at(home, "Papers/a.pdf"))

      assert Enum.flat_map(records, &Ops.undo_record(&1, trash)) == []
      assert File.exists?(at(home, "Downloads/a.pdf"))
      refute File.exists?(at(home, "Papers"))
    end

    test "a rewrite is backed up, and undo restores it and keeps the undone version", %{
      home: home,
      trash: trash
    } do
      path = at(home, "Documents/notes.md")
      old = File.read!(path)
      backup = Path.join(trash, "../backup-0")

      op = %{op: :write, path: path, content: "# New notes\n", old_hash: Ops.hash(old)}
      assert {:ok, records} = Ops.step(op, backup)
      assert File.read!(path) == "# New notes\n"
      assert File.read!(backup) == old

      assert Enum.flat_map(records, &Ops.undo_record(&1, trash)) == []
      assert File.read!(path) == old
      assert File.read!(Path.join(trash, "Documents/notes.md")) == "# New notes\n"
    end

    test "a write refuses a file that changed since it was read", %{home: home} do
      op = %{
        op: :write,
        path: at(home, "Documents/notes.md"),
        content: "x",
        old_hash: Ops.hash("stale")
      }

      assert {:error, message} = Ops.step(op, "unused")
      assert message =~ "changed since tiny-axe read it"
    end

    test "undo leaves alone anything changed since", %{home: home, trash: trash} do
      op = %{op: :write, path: at(home, "new.md"), content: "one\n", old_hash: nil}
      assert {:ok, records} = Ops.step(op, "unused")
      File.write!(at(home, "new.md"), "the user edited this\n")

      assert [note] = Enum.flat_map(records, &Ops.undo_record(&1, trash))
      assert note =~ "changed since it was written, so it was kept"
      assert File.read!(at(home, "new.md")) == "the user edited this\n"
    end
  end

  describe "trash" do
    test "moves a file to the system Trash with a .trashinfo, and undo brings it back",
         %{home: home, trash: trash, system_trash: system_trash} do
      path = at(home, "Downloads/a.pdf")
      assert {:ok, [op]} = Ops.expand([%{"op" => "trash", "path" => path}])
      assert Ops.describe(op) =~ "trash ~/Downloads/a.pdf"

      marker = Path.join(trash, "../marker-0")
      assert {:ok, records} = Ops.step(op, marker)
      refute File.exists?(path)
      assert File.read!(Path.join(system_trash, "files/a.pdf")) == "contents of Downloads/a.pdf\n"

      info = File.read!(Path.join(system_trash, "info/a.pdf.trashinfo"))
      assert [_, encoded] = Regex.run(~r/\A\[Trash Info\]\nPath=(.+)\n/, info)
      assert URI.decode(encoded) == path
      assert info =~ ~r/DeletionDate=\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\n/

      assert Enum.flat_map(records, &Ops.undo_record(&1, trash)) == []
      assert File.exists?(path)
      assert File.ls!(Path.join(system_trash, "info")) == []
    end

    test "two trashed files with the same name both keep their own entry", %{
      home: home,
      system_trash: system_trash
    } do
      File.write!(at(home, "Documents/a.pdf"), "another a\n")

      {:ok, ops} =
        Ops.expand([
          %{"op" => "trash", "path" => at(home, "Downloads/a.pdf")},
          %{"op" => "trash", "path" => at(home, "Documents/a.pdf")}
        ])

      for {op, i} <- Enum.with_index(ops),
          do: {:ok, _} = Ops.step(op, Path.join(system_trash, "../m-#{i}"))

      assert File.ls!(Path.join(system_trash, "files")) |> Enum.sort() == ["a.1.pdf", "a.pdf"]
      assert File.read!(Path.join(system_trash, "files/a.1.pdf")) == "another a\n"
    end

    test "a folder shows how many files go with it", %{home: home} do
      assert {:ok, [op]} = Ops.expand([%{"op" => "trash", "path" => at(home, "Downloads")}])
      assert Ops.describe(op) == "trash folder ~/Downloads (3 files)"
    end

    test "replacing a file: trash the old one, then move the new one into place", %{home: home} do
      raw = [
        %{"op" => "trash", "path" => at(home, "Documents/notes.md")},
        %{
          "op" => "move",
          "from" => at(home, "Downloads/c.txt"),
          "to" => at(home, "Documents/notes.md")
        }
      ]

      assert {:ok, [%{op: :trash}, %{op: :move}]} = Ops.expand(raw)
      # Without the trash step, the move would overwrite, which is refused.
      assert {:error, [problem]} = Ops.expand(Enum.drop(raw, 1))
      assert problem =~ "never overwrites"
    end

    test "hidden files can't be trashed", %{home: home} do
      assert {:error, [problem]} =
               Ops.expand([%{"op" => "trash", "path" => at(home, ".ssh/id_ed25519")}])

      assert problem =~ "can't be trashed"
    end

    test "after a crash, settle finds whether the file reached the Trash", %{
      home: home,
      trash: trash,
      system_trash: system_trash
    } do
      {:ok, [op]} = Ops.expand([%{"op" => "trash", "path" => at(home, "Downloads/a.pdf")}])
      marker = Path.join(trash, "../marker-0")

      # The step never started: no marker, nothing to undo.
      assert {:not_done, [], []} = Ops.settle(op, marker, trash)

      {:ok, records} = Ops.step(op, marker)
      assert {:done, ^records, []} = Ops.settle(op, marker, trash)

      # Reserved but never moved (crash between the two): the .trashinfo is cleaned up.
      File.rename!(Path.join(system_trash, "files/a.pdf"), at(home, "Downloads/a.pdf"))
      assert {:not_done, [], []} = Ops.settle(op, marker, trash)
      assert File.ls!(Path.join(system_trash, "info")) == []
    end
  end
end
