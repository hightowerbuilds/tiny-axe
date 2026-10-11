defmodule TinyAxe.ShellTest do
  # Sets global config (the fake home and project), so not async.
  use ExUnit.Case, async: false

  alias TinyAxe.{Commander, Shell}
  alias TinyAxe.Commander.Validation

  doctest Shell

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

  defp put_env(key, value) do
    previous = Application.get_env(:tiny_axe, key)
    Application.put_env(:tiny_axe, key, value)

    on_exit(fn ->
      if previous == nil,
        do: Application.delete_env(:tiny_axe, key),
        else: Application.put_env(:tiny_axe, key, previous)
    end)
  end

  # A process outside any sandbox, for commands to look at (or stop).
  defp outside_process do
    port = Port.open({:spawn_executable, System.find_executable("sleep")}, args: ["30"])
    {:os_pid, pid} = Port.info(port, :os_pid)

    on_exit(fn ->
      System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
    end)

    pid
  end

  # One tiny-axe didn't start: its parent has gone.
  defp detached_process do
    {out, 0} = System.cmd("sh", ["-c", "sleep 30 > /dev/null 2>&1 & echo $!"])
    pid = out |> String.trim() |> String.to_integer()

    on_exit(fn ->
      System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
    end)

    pid
  end

  defp alive?(pid),
    do: match?({_, 0}, System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true))

  describe "the sandbox" do
    setup do
      if Shell.available?(), do: :ok, else: {:skip, "bwrap not installed"}
    end

    test "approved: only the working folder keeps changes; the home folder's writes vanish", %{
      project: project
    } do
      marker = Path.expand("~/tiny_axe_sandbox_#{System.unique_integer([:positive])}")

      assert {:ok, 0, out} =
               Shell.run(
                 project,
                 ~s(touch "#{marker}" && echo "home write ok" && echo kept > kept.txt),
                 fn _ -> :ok end,
                 mode: :approved
               )

      assert out == "home write ok"
      refute File.exists?(marker)
      assert File.read!(Path.join(project, "kept.txt")) == "kept\n"
    end

    test "read-only: nothing can be written, not even the working folder; /tmp is scratch", %{
      project: project
    } do
      assert {:ok, 0, out} =
               Shell.run(
                 project,
                 "touch here.txt 2>/dev/null || echo refused; echo s > /tmp/s && cat /tmp/s"
               )

      assert out == "refused\ns"
      refute File.exists?(Path.join(project, "here.txt"))
    end

    test "streams output, reports the exit status and gives an empty stdin", %{project: project} do
      me = self()
      on_start = fn pid -> send(me, {:os_pid, pid}) end

      for mode <- [:read_only, :approved] do
        assert {:ok, 3, "asked: []"} =
                 Shell.run(
                   project,
                   ~s(read answer; echo "asked: [$answer]"; exit 3),
                   &send(me, {:out, &1}),
                   on_start: on_start,
                   mode: mode
                 )

        assert_received {:out, "asked: []\n"}
        assert_received {:os_pid, pid} when is_integer(pid)
      end
    end

    test "is killed at the timeout, with what it started", %{project: project} do
      {micros, result} =
        :timer.tc(fn ->
          Shell.run(project, "sleep 30", fn _ -> :ok end, timeout: 300, mode: :approved)
        end)

      assert result == {:error, :timeout}
      assert micros < 5_000_000
    end

    test "approved: what a command leaves running is stopped when it ends", %{project: project} do
      assert {:ok, 0, pid} =
               Shell.run(project, "sleep 30 & echo $!", fn _ -> :ok end, mode: :approved)

      Process.sleep(100)
      refute alive?(String.to_integer(pid))
    end

    test "stop/1 stops a running command and its children", %{project: project} do
      me = self()

      task =
        Task.async(fn ->
          Shell.run(project, "sleep 30 & echo $!; wait", &send(me, {:out, &1}),
            mode: :approved,
            on_start: &send(me, {:os_pid, &1})
          )
        end)

      assert_receive {:os_pid, sandbox}, 5_000
      assert_receive {:out, child}, 5_000
      child = child |> String.trim() |> String.to_integer()
      assert alive?(child)

      Shell.stop(sandbox)
      assert {:ok, _status, _} = Task.await(task, 5_000)
      Process.sleep(100)
      refute alive?(child)
      refute alive?(sandbox)
    end

    test "secret files and folders are hidden in both modes", %{project: project, tmp_dir: dir} do
      # tiny-axe's own settings and browser profile stand in for ~/.ssh and the like.
      settings = Path.join(dir, "purchases.json")
      File.write!(settings, "the secret settings")
      profile = Path.join(dir, "profile")
      File.mkdir_p!(profile)
      File.write!(Path.join(profile, "Cookies"), "the secret cookies")
      put_env(:purchases_config, settings)

      put_env(
        :browser,
        Keyword.put(Application.get_env(:tiny_axe, :browser, []), :profile, profile)
      )

      assert {:file, settings} in Shell.hidden_paths()
      assert {:dir, profile} in Shell.hidden_paths()

      for mode <- [:read_only, :approved] do
        assert {:ok, _, out} =
                 Shell.run(
                   project,
                   ~s(cat "#{settings}"; ls -A "#{profile}"; echo end),
                   fn _ -> :ok end,
                   mode: mode
                 )

        refute out =~ "secret"
        refute out =~ "Cookies"
        assert out =~ "end"
      end

      # Hidden, not changed.
      assert File.read!(settings) == "the secret settings"
    end

    test "environment variables that look like secrets are removed", %{project: project} do
      System.put_env("TINY_AXE_TEST_API_KEY", "key-value")
      System.put_env("TINY_AXE_TEST_TOKEN", "token-value")
      System.put_env("ANTHROPIC_BASE_URL", "anthropic-value")
      System.put_env("TINY_AXE_TEST_PLAIN", "plain-value")

      on_exit(fn ->
        for v <-
              ~w(TINY_AXE_TEST_API_KEY TINY_AXE_TEST_TOKEN ANTHROPIC_BASE_URL TINY_AXE_TEST_PLAIN),
            do: System.delete_env(v)
      end)

      for mode <- [:read_only, :approved] do
        assert {:ok, 0, out} = Shell.run(project, "env", fn _ -> :ok end, mode: mode)
        refute out =~ "key-value"
        refute out =~ "token-value"
        refute out =~ "anthropic-value"
        assert out =~ "TINY_AXE_TEST_PLAIN=plain-value"
        assert out =~ "PATH="
        assert out =~ "HOME="
        assert out =~ "CI=true"
      end
    end

    test "your processes are visible; only approved commands can stop them", %{project: project} do
      pid = outside_process()

      assert {:ok, 0, "sleep"} =
               Shell.run(project, "ps -o comm= -p #{pid}", fn _ -> :ok end, mode: :read_only)

      # A read-only command has its own process namespace: the pid isn't there.
      assert {:ok, status, _} =
               Shell.run(project, "kill #{pid}", fn _ -> :ok end, mode: :read_only)

      assert status != 0
      assert alive?(pid)

      assert {:ok, 0, _} = Shell.run(project, "kill #{pid}", fn _ -> :ok end, mode: :approved)
      Process.sleep(100)
      refute alive?(pid)
    end
  end

  describe "how the sandbox is set up" do
    test "read-only gets no writable folder and its own process namespace", %{project: project} do
      args = Shell.args(:read_only, project, "ls")
      refute "--bind" in args
      refute "--tmp-overlay" in args
      assert "--unshare-pid" in args
      assert ["--ro-bind", project, project] == Enum.slice(args, 7, 3)
    end

    test "approved binds the working folder and existing install folders, never settings", %{
      project: project
    } do
      args = Shell.args(:approved, project, "ls")
      refute "--unshare-pid" in args
      binds = args |> Enum.chunk_every(3, 1) |> Enum.filter(&match?(["--bind", _, _], &1))
      bound = Enum.map(binds, &Enum.at(&1, 1))

      assert project in bound

      for {path, _} <- Shell.install_folders(),
          File.dir?(path),
          do: assert(Shell.real_path(path) in bound)

      home = System.user_home!()

      for never <- [".config", ".local/share/tiny-axe", ".local/state", ".ssh"] do
        refute Enum.any?(bound, &String.starts_with?(&1, Path.join(home, never))), never
      end

      # Secrets are hidden after the binds, so one inside an install folder stays hidden.
      last_bind =
        args |> Enum.with_index() |> Enum.filter(&(elem(&1, 0) == "--bind")) |> List.last()

      first_tmpfs = Enum.find_index(Enum.drop(args, 6), &(&1 == "--tmpfs"))
      if first_tmpfs, do: assert(first_tmpfs + 6 > elem(last_bind, 1))
    end

    test "secret-looking variable names" do
      for name <- ~w(GITHUB_TOKEN GH_TOKEN OPENAI_API_KEY ANTHROPIC_API_KEY TYPESAFE_KEY
                     AWS_SECRET_ACCESS_KEY AWS_PROFILE NPM_TOKEN DATABASE_PASSWORD SSH_AUTH_SOCK
                     DBUS_SESSION_BUS_ADDRESS RELEASE_COOKIE BASH_FUNC_ls%% my_secret) do
        assert Shell.secret_env?(name), name
      end

      for name <- ~w(PATH HOME LANG LC_ALL USER SHELL TERM XDG_CONFIG_HOME EDITOR MIX_ENV) do
        refute Shell.secret_env?(name), name
      end
    end

    test "the description of the shell comes from the same lists" do
      text = TinyAxe.Capabilities.shell()
      assert text =~ "`df`"
      assert text =~ "sudo"
      assert text =~ "pacman"
      assert text =~ "~/.cargo"
      assert text =~ "SSH and GPG keys"
      assert text =~ "10 minutes"
      assert TinyAxe.Capabilities.summary() =~ "approval"
    end
  end

  describe "Commander.check/2" do
    test "accepts the project and folders under home", %{home: home, project: project} do
      assert {:ok, ^project} = Commander.check(project, ["npm install"])
      File.mkdir_p!(Path.join(home, "code"))
      assert {:ok, _} = Commander.check("~/code", ["ls"])
    end

    test "commands that only look may run in the home folder and hidden folders", %{home: home} do
      assert {:ok, ^home} = Commander.check(home, ["ls", "df -h"])
      assert {:ok, _} = Commander.check(Path.join(home, ".hidden"), ["ls -la"])
    end

    test "commands that change things don't run in the home folder itself, hidden or missing folders",
         %{home: home} do
      assert {:error, [p]} = Commander.check(home, ["touch x"])
      assert p =~ "can't run in the home folder itself"
      assert p =~ "\"dir\""

      # One changing command makes the whole plan a changing one.
      assert {:error, [_]} = Commander.check(home, ["ls", "touch x"])

      assert {:error, [p]} = Commander.check(Path.join(home, ".hidden"), ["touch x"])
      assert p =~ "hidden folder"

      assert {:error, [p]} = Commander.check(Path.join(home, "nope"), ["ls"])
      assert p =~ "isn't an existing folder"
    end

    test "sudo and system package managers are refused", %{project: project} do
      assert {:error, [p]} = Commander.check(project, ["cd x && sudo apt install nodejs"])
      assert p =~ "sudo"

      assert {:error, [p]} = Commander.check(project, ["pacman -S nodejs"])
      assert p =~ "system package manager"

      assert {:error, [_]} = Commander.check(project, ["ls && apt-get install -y x"])
      assert {:ok, _} = Commander.check(project, ["npm install pacman"])
    end

    test "commands that would stop tiny-axe itself are refused", %{project: project} do
      me = System.pid()

      for c <- [
            "kill #{me}",
            "kill -9 #{me}",
            "kill -s KILL -- #{me}",
            "pkill beam.smp",
            "kill -9 -1"
          ] do
        assert {:error, [p]} = Commander.check(project, [c]), c
        assert p =~ "tiny-axe", c
      end

      # tiny-axe's own children are protected too; other processes aren't.
      assert {:error, [_]} = Commander.check(project, ["kill #{outside_process()}"])
      assert {:ok, _} = Commander.check(project, ["kill #{detached_process()}"])
    end

    test "…including through $(…) and xargs, when the inner command only looks", %{
      project: project
    } do
      if Shell.available?() do
        me = System.pid()
        assert {:error, [_]} = Commander.check(project, ["kill $(echo #{me})"])
        assert {:error, [_]} = Commander.check(project, ["echo #{me} | xargs kill -9"])
        assert {:ok, _} = Commander.check(project, ["echo 99999999 | xargs kill"])
      end
    end

    test "won't run changing commands in a hidden folder, even after cd-ing into it", %{
      home: home
    } do
      assert {:ok, hidden} = TinyAxe.Location.cd(Path.join(home, ".hidden"))
      assert {:error, [p]} = Commander.check(hidden, ["echo hi > x"])
      assert p =~ "hidden folder"
    end

    test "approved commands are re-checked when they run, and refused if the rules now say no",
         %{home: home} do
      dir = Path.join(home, "work")
      File.mkdir_p!(dir)

      plan = %{
        request: "x",
        dir: dir,
        commands: [%{command: "touch ran.txt", review: 0.9}],
        review: 0.9
      }

      # Between approval and running, the folder becomes hidden.
      hidden = Path.join(home, ".work")
      File.rename!(dir, hidden)
      me = self()
      Commander.execute(%{plan | dir: hidden}, &send(me, &1))

      assert_received {:cmds_refused, [problem]}
      assert problem =~ "hidden folder"
      refute_received {:cmd_start, _, _}
      refute File.exists?(Path.join(hidden, "ran.txt"))
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

  describe "the plan's \"dir\"" do
    test "names a subfolder of the current folder", %{home: home, project: project} do
      assert {:ok, ^project} = Validation.check_plan(home, "project", ["touch x"])
      assert {:ok, ^project} = Validation.check_plan(home, "~/project", ["touch x"])
      assert {:ok, ^project} = Validation.check_plan(project, "", ["touch x"])
      assert {:ok, ^project} = Validation.check_plan(project, ".", ["touch x"])
    end

    test "can't leave the current folder or name one that doesn't exist", %{
      home: home,
      project: project
    } do
      assert {:error, [p]} = Validation.check_plan(project, "..", ["touch x"])
      assert p =~ "must be a subfolder of the current folder"
      assert {:error, [_]} = Validation.check_plan(project, "/etc", ["ls"])
      assert {:error, [_]} = Validation.check_plan(project, "sub/../../x", ["ls"])

      assert {:error, [p]} = Validation.check_plan(home, "code/new-app", ["touch x"])
      assert p =~ "isn't an existing folder"
    end
  end
end
