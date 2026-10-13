defmodule TinyAxe.DesktopSnapshotTest do
  use ExUnit.Case, async: false

  alias TinyAxe.{Desktop, FakeDesktop}
  alias TinyAxe.Desktop.{Snapshot, Undo}

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    config = Path.join(dir, "config")
    state = Path.join(dir, "state")

    previous =
      {Application.get_env(:tiny_axe, :desktop), Application.get_env(:tiny_axe, :state_dir)}

    Application.put_env(
      :tiny_axe,
      :desktop,
      Keyword.put(Application.get_env(:tiny_axe, :desktop, []), :config_root, config)
    )

    Application.put_env(:tiny_axe, :state_dir, state)

    on_exit(fn ->
      {desktop, state_dir} = previous
      Application.put_env(:tiny_axe, :desktop, desktop)
      Application.put_env(:tiny_axe, :state_dir, state_dir)
      FakeDesktop.reset()
    end)

    File.mkdir_p!(Path.join(config, "hypr"))
    File.mkdir_p!(Path.join(config, "google-chrome/Default"))
    File.write!(Path.join(config, "hypr/bindings.lua"), "-- bindings\n")
    File.write!(Path.join(config, "google-chrome/Default/Cookies"), "secret")
    File.write!(Path.join(config, "hypr/api-token"), "secret")
    FakeDesktop.script(fn _, _ -> {"", 0} end)
    %{config: config, state: state}
  end

  test "only the desktop's own config is tracked, never browser profiles", %{config: config} do
    {:ok, a} = Snapshot.take("before")
    File.write!(Path.join(config, "hypr/bindings.lua"), "-- bindings\nbind = super+b\n")
    File.write!(Path.join(config, "google-chrome/Default/Cookies"), "more secret")
    File.write!(Path.join(config, "hypr/api-token"), "more secret")
    {:ok, b} = Snapshot.take("after")

    assert Snapshot.changed(a, b) == [{"M", "hypr/bindings.lua"}]
  end

  test "restore puts changed files back and sets added ones aside", %{
    config: config,
    state: state
  } do
    {:ok, a} = Snapshot.take("before")
    File.write!(Path.join(config, "hypr/bindings.lua"), "-- broken\n")
    File.write!(Path.join(config, "hypr/extra.lua"), "-- new\n")
    {:ok, b} = Snapshot.take("after")

    assert %{restored: ["hypr/bindings.lua"], set_aside: ["hypr/extra.lua"], skipped: []} =
             Snapshot.restore(a, b)

    assert File.read!(Path.join(config, "hypr/bindings.lua")) == "-- bindings\n"
    refute File.exists?(Path.join(config, "hypr/extra.lua"))
    assert [kept] = Path.wildcard(Path.join(state, "config-set-aside/*/hypr/extra.lua"))
    assert File.read!(kept) == "-- new\n"
  end

  test "a file edited again since the change is left alone", %{config: config} do
    {:ok, a} = Snapshot.take("before")
    File.write!(Path.join(config, "hypr/bindings.lua"), "-- tiny-axe's change\n")
    {:ok, b} = Snapshot.take("after")
    File.write!(Path.join(config, "hypr/bindings.lua"), "-- the user's own edit\n")

    assert %{skipped: ["hypr/bindings.lua"]} = Snapshot.restore(a, b)
    assert File.read!(Path.join(config, "hypr/bindings.lua")) == "-- the user's own edit\n"
  end

  test "Hyprland errors after a change put back only hypr files", %{config: config} do
    FakeDesktop.script(fn
      "hyprctl", ["configerrors"] -> {"bindings.lua:2: unknown dispatcher", 0}
      _, _ -> {"", 0}
    end)

    File.mkdir_p!(Path.join(config, "ghostty"))
    File.write!(Path.join(config, "ghostty/config"), "font-size = 12\n")
    {:ok, a} = Snapshot.take("before")
    File.write!(Path.join(config, "hypr/bindings.lua"), "-- bad\n")
    File.write!(Path.join(config, "ghostty/config"), "font-size = 14\n")
    {:ok, b} = Snapshot.take("after")

    assert {:reverted, "bindings.lua:2: unknown dispatcher"} = Snapshot.guard_hyprland("", a, b)
    assert File.read!(Path.join(config, "hypr/bindings.lua")) == "-- bindings\n"
    assert File.read!(Path.join(config, "ghostty/config")) == "font-size = 14\n"
  end

  test "an interrupted run becomes something /look undo puts back", %{config: config} do
    {:ok, before} = Snapshot.take("before")
    _id = Snapshot.started("bind super+b to brave", before)
    File.write!(Path.join(config, "hypr/bindings.lua"), "-- half done\n")

    assert [line] = Snapshot.recover_interrupted()
    assert line =~ "was interrupted (“bind super+b to brave”)"
    assert Snapshot.recover_interrupted() == []
    assert [%{"kind" => "snapshot"}] = Undo.load()

    assert Desktop.undo() =~ "hypr/bindings.lua put back"
    assert File.read!(Path.join(config, "hypr/bindings.lua")) == "-- bindings\n"
  end
end
