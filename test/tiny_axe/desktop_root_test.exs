defmodule TinyAxe.DesktopRootTest do
  @moduledoc """
  Root actions through tiny-axe's root helper (`TinyAxe.Desktop.Root`),
  with a stand-in sudo and the helper in its dry-run mode: nothing runs as root.
  """

  use ExUnit.Case, async: false

  alias TinyAxe.{Desktop, Decider, FakeDesktop, Model}
  alias TinyAxe.Desktop.{OsRun, Root, Value}

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    helper = Path.join(dir, "tiny-axe-root")
    File.cp!(Root.shipped_path(), helper)
    File.chmod!(helper, 0o755)
    %File.Stat{uid: uid} = File.stat!(helper)

    saved =
      for key <-
            ~w(root_helper root_helper_owner sudo model_backend script_model decider script_decider)a,
          do: {key, Application.get_env(:tiny_axe, key)}

    Application.put_env(:tiny_axe, :root_helper, helper)
    Application.put_env(:tiny_axe, :root_helper_owner, uid)
    Application.put_env(:tiny_axe, :sudo, Path.expand("../support/fake_sudo/sudo", __DIR__))
    System.put_env("TINY_AXE_ROOT_DRY_RUN", "1")

    on_exit(fn ->
      System.delete_env("TINY_AXE_ROOT_DRY_RUN")
      FakeDesktop.reset()

      for {k, v} <- saved,
          do:
            if(v == nil,
              do: Application.delete_env(:tiny_axe, k),
              else: Application.put_env(:tiny_axe, k, v)
            )
    end)

    FakeDesktop.script(fn
      "pacman", ["-Si", "--", "ripgrep"] -> {"Name : ripgrep\n", 0}
      _, _ -> {"", 1}
    end)

    %{helper: helper}
  end

  test "an installed helper that's the shipped one, not writable by others, is ready", %{
    helper: helper
  } do
    assert Root.status() == :ready
    File.write!(helper, File.read!(helper) <> "\n# changed\n")
    assert {:missing, why} = Root.status()
    assert why =~ "differs"
  end

  test "a missing helper says how to set it up" do
    Application.put_env(:tiny_axe, :root_helper, "/nonexistent/tiny-axe-root")
    assert {:missing, why} = Root.status()
    assert why =~ "mix tiny_axe.os_setup"
  end

  test "arguments are checked here as well as in the helper" do
    assert Root.check("install", ["ripgrep", "fd"]) == :ok
    assert {:error, _} = Root.check("install", ["rg;rm"])
    assert {:error, _} = Root.check("service", ["mask", "sshd"])
    assert {:error, _} = Root.check("frob", [])
  end

  test "the helper runs through sudo -n and takes a snapshot before installing" do
    assert {:ok, out} = Root.run("install", ["ripgrep"])
    assert out =~ "would run: pacman -S --needed --noconfirm -- ripgrep"
    assert out =~ "snapper"
  end

  test "package names must be in the official repositories" do
    assert Value.parse(:packages, "ripgrep", nil) == {:ok, "ripgrep"}
    assert {:error, why} = Value.parse(:packages, "spotify", nil)
    assert why =~ "official repositories"
    assert Value.parse(:service, "enable --now sshd", nil) == {:ok, "enable sshd"}
  end

  test "os_run sends sudo to the helper, and runs the helper's own form after asking" do
    assert {:refused, why} = OsRun.check(%{"command" => "sudo pacman -S ripgrep"})
    assert why =~ "tiny-axe-root install <packages>"

    assert {:outward, _, %{root: {"install", ["ripgrep"]}} = plan} =
             OsRun.check(%{"command" => "tiny-axe-root install ripgrep", "why" => "rg"})

    assert {:refused, _} = OsRun.check(%{"command" => "tiny-axe-root install rg; rm -rf /"})
    assert %{"isError" => false} = result = OsRun.run(%{}, plan)
    assert hd(result["content"])["text"] =~ "would run: pacman -S"
  end

  test "installing from the desktop route always asks, then runs through the helper" do
    Decider.Script.script(fn _, _, _ -> 0.9 end)

    Model.Script.script(fn _, _ ->
      JSON.encode!(%{changes: [%{setting: "install_package", value: "ripgrep"}], reply: ""})
    end)

    me = self()
    Desktop.run([], "install ripgrep", &send(me, {:event, &1}), [])
    assert_received {:event, {:desktop_plan, %{why: :risk} = plan}}

    Desktop.execute(plan, &send(me, {:event, &1}))
    assert_received {:event, {:desktop_done, text}}
    assert text =~ "install package: ripgrep, done"
  end
end
