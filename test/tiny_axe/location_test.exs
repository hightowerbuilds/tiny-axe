defmodule TinyAxe.LocationTest do
  # The location is app-wide, so not async.
  use ExUnit.Case, async: false

  alias TinyAxe.{Location, TUI}

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    home = Path.join(dir, "home")
    repo = Path.join(home, "code/tiny-app")
    File.mkdir_p!(Path.join(repo, "web"))
    File.mkdir_p!(Path.join(home, "Downloads"))
    File.mkdir_p!(Path.join(home, ".secret"))
    File.write!(Path.join(repo, "README.md"), "# tiny app\n")

    for {key, value} <- [fs_root: home, project_dir: home] do
      previous = Application.get_env(:tiny_axe, key)
      Application.put_env(:tiny_axe, key, value)
      on_exit(fn -> Application.put_env(:tiny_axe, key, previous) end)
    end

    Location.reset()
    on_exit(&Location.reset/0)
    %{home: home, repo: repo}
  end

  test "starts where tiny-axe was launched, and cd moves like a shell", %{home: home, repo: repo} do
    assert Location.current() == home
    assert {:ok, ^repo} = Location.cd("code/tiny-app")
    assert {:ok, web} = Location.cd("web")
    assert web == Path.join(repo, "web")
    assert {:ok, ^repo} = Location.cd("..")
    assert {:ok, ^home} = Location.cd("~")
    assert {:error, :not_a_folder} = Location.cd("nope")
    assert Location.current() == home
    assert Enum.take(Location.trail(), 2) == [repo, web]
  end

  test "relative paths resolve from the current folder", %{home: home, repo: repo} do
    Location.cd("code/tiny-app")
    assert TinyAxe.Ops.resolve("web") == Path.join(repo, "web")
    assert TinyAxe.Ops.resolve("~/Downloads") == Path.join(home, "Downloads")
    # The project (file reading and editing) follows the location too.
    assert TinyAxe.Files.root() == repo
  end

  test "candidates are real, visible folders, including ones named in the request", %{
    home: home,
    repo: repo
  } do
    candidates = Location.candidates("install vite in my tiny-app repo")
    assert repo in candidates
    assert Path.join(home, "Downloads") in candidates
    refute Path.join(home, ".secret") in candidates
    assert Enum.all?(candidates, &File.dir?/1)
  end

  test "the listing shows folders with a slash and hides dotfiles", %{repo: repo} do
    assert Location.listing(repo) == "  README.md\n  web/"
  end

  test "cd and pwd at the prompt move and report without asking a model", %{repo: repo} do
    {:ok, state} = TUI.mount(test_mode: {100, 30})

    type = fn state, text ->
      ExRatatui.textarea_set_value(state.input, text)

      {:noreply, state} =
        TUI.handle_event(%ExRatatui.Event.Key{code: "enter", kind: "press", modifiers: []}, state)

      state
    end

    state = type.(state, "cd code/tiny-app")
    assert state.run == nil
    assert Location.current() == repo
    assert {:meta, "📍 " <> _} = List.last(state.transcript)

    state = type.(state, "cd nowhere")
    assert {:meta, "cd: nowhere isn't a folder" <> _} = List.last(state.transcript)
    assert Location.current() == repo

    state = type.(state, "pwd")
    assert {:meta, "📍 " <> shown} = List.last(state.transcript)
    assert String.ends_with?(shown, "code/tiny-app")
  end

  @tag :sandbox
  test "after commands, the location follows a successful `cd x && …`", %{repo: repo} do
    if not TinyAxe.Shell.available?(), do: flunk("bwrap not installed")

    plan = %{
      request: "set up web",
      dir: repo,
      commands: [%{command: "cd web && true", review: 0.9}],
      review: 0.9
    }

    me = self()
    TinyAxe.Commander.execute(plan, &send(me, &1))

    assert_received {:moved, %{to: to}}
    assert String.ends_with?(to, "code/tiny-app/web")
    assert Location.current() == Path.join(repo, "web")
  end
end
