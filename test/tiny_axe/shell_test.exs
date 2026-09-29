defmodule TinyAxe.ShellTest do
  # Sets global config (the fake home and project), so not async.
  use ExUnit.Case, async: false

  alias TinyAxe.{Commander, Shell}

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    TinyAxe.Location.reset()
    home = Path.join(dir, "home")
    project = Path.join(home, "project")
    File.mkdir_p!(Path.join(home, ".hidden"))
    File.mkdir_p!(project)

    for {key, value} <- [fs_root: home, project_dir: project] do
      previous = Application.get_env(:tiny_axe, key)
      Application.put_env(:tiny_axe, key, value)
      on_exit(fn -> Application.put_env(:tiny_axe, key, previous) end)
    end

    %{home: home, project: project}
  end

  describe "the sandbox" do
    setup do
      if Shell.available?(), do: :ok, else: {:skip, "bwrap not installed"}
    end

    test "only the working folder keeps changes; the home folder's writes vanish", %{
      project: project
    } do
      marker = Path.expand("~/tiny_axe_sandbox_#{System.unique_integer([:positive])}")

      assert {:ok, 0, out} =
               Shell.run(
                 project,
                 ~s(touch "#{marker}" && echo "home write ok" && echo kept > kept.txt)
               )

      assert out == "home write ok"
      refute File.exists?(marker)
      assert File.read!(Path.join(project, "kept.txt")) == "kept\n"
    end

    test "streams output, reports the exit status and gives an empty stdin", %{project: project} do
      me = self()
      on_start = fn pid -> send(me, {:os_pid, pid}) end

      assert {:ok, 3, "asked: []"} =
               Shell.run(
                 project,
                 ~s(read answer; echo "asked: [$answer]"; exit 3),
                 &send(me, {:out, &1}),
                 on_start: on_start
               )

      assert_received {:out, "asked: []\n"}
      assert_received {:os_pid, pid} when is_integer(pid)
    end

    test "is killed at the timeout", %{project: project} do
      {micros, result} =
        :timer.tc(fn -> Shell.run(project, "sleep 30", fn _ -> :ok end, timeout: 300) end)

      assert result == {:error, :timeout}
      assert micros < 5_000_000
    end
  end

  describe "Commander.check/2" do
    test "accepts the project and folders under home", %{home: home, project: project} do
      assert {:ok, ^project} = Commander.check(project, ["npm install"])
      File.mkdir_p!(Path.join(home, "code"))
      assert {:ok, _} = Commander.check("~/code", ["ls"])
    end

    test "refuses the home folder itself, hidden and missing folders, and sudo", %{
      home: home,
      project: project
    } do
      assert {:error, [p]} = Commander.check(home, ["ls"])
      assert p =~ "not the home folder itself"

      assert {:error, [p]} = Commander.check(Path.join(home, ".hidden"), ["ls"])
      assert p =~ "outside hidden folders"

      assert {:error, [p]} = Commander.check(Path.join(home, "nope"), ["ls"])
      assert p =~ "isn't an existing folder"

      assert {:error, [p]} = Commander.check(project, ["cd x && sudo apt install nodejs"])
      assert p =~ "sudo"
    end

    test "won't run commands in a hidden folder, even after cd-ing into it", %{home: home} do
      assert {:ok, hidden} = TinyAxe.Location.cd(Path.join(home, ".hidden"))
      assert {:error, [p]} = Commander.check(hidden, ["echo hi > x"])
      assert p =~ "outside hidden folders"
    end

    test "sends a scaffolder aimed at a non-empty folder to a subfolder instead", %{
      project: project
    } do
      assert {:ok, _} = Commander.check(project, ["npm create vite@latest . -- --template react"])

      File.write!(Path.join(project, "README.md"), "# app\n")

      for c <- [
            "npm create vite@latest . -- --template react",
            "npx create-next-app .",
            "yarn create vite ."
          ] do
        assert {:error, [p]} = Commander.check(project, [c])
        assert p =~ "isn't empty (README.md)"
      end

      assert {:ok, _} =
               Commander.check(project, ["npm create vite@latest web -- --template react"])
    end
  end
end
