defmodule TinyAxe.MCPConfigTest do
  @moduledoc """
  Connecting third-party MCP servers: mcp.json, policy templates, secrets
  from the keyring (a fake secret-tool) and the environment, server status,
  `mix tiny_axe.mcp`, and the TUI's `tools`.
  """

  # Points the app-wide mcp.json at a temp file, so not async.
  use ExUnit.Case, async: false

  alias TinyAxe.{MCP, TUI}
  alias TinyAxe.MCP.Policies

  @moduletag :tmp_dir
  @server Path.expand("../support/fake_mcp/server", __DIR__)

  setup %{tmp_dir: dir} do
    previous = Application.get_env(:tiny_axe, :mcp_config)
    path = Path.join(dir, "mcp.json")
    Application.put_env(:tiny_axe, :mcp_config, path)
    on_exit(fn -> Application.put_env(:tiny_axe, :mcp_config, previous) end)
    %{path: path}
  end

  defp write(path, servers), do: File.write!(path, JSON.encode!(%{"mcpServers" => servers}))

  describe "policy templates" do
    test "a template by name, adjusted, or unknown" do
      assert {:ok, %{"deny" => ["delete_*"]}} = Policies.resolve("github")

      {:ok, adjusted} = Policies.resolve(%{"template" => "github", "deny" => ["merge_*"]})
      assert adjusted["deny"] == ["delete_*", "merge_*"]
      assert "get_*" in adjusted["read"]

      assert Policies.resolve("nope") == {:error, "nope"}
      assert Policies.resolve(nil) == {:ok, %{}}
    end

    test "classify a real server's tools the way the template means" do
      {:ok, github} = Policies.resolve("github")
      classify = &TinyAxe.Tools.Policy.classify(%{"name" => &1}, github)

      assert classify.("get_issue") == :read
      assert classify.("create_pull_request") == :outward
      assert classify.("delete_repository") == :refused
      # A tool the template doesn't know asks.
      assert classify.("brand_new_tool") == :outward
    end
  end

  describe "mcp.json" do
    test "templates and secrets are filled in; an unknown template asks for everything", %{
      path: path
    } do
      System.put_env("TINY_AXE_TEST_VAR", "from-the-env")
      on_exit(fn -> System.delete_env("TINY_AXE_TEST_VAR") end)

      write(path, %{
        "gh" => %{
          "command" => "github-mcp-server",
          "env" => %{
            "TOKEN" => "${keyring:github}",
            "OTHER" => "${TINY_AXE_TEST_VAR}",
            "MISSING" => "${keyring:nope}"
          },
          "policy" => "github"
        },
        "odd" => %{"command" => "x", "policy" => "nope"},
        "browser" => %{"command" => "x"}
      })

      configured = MCP.configured()

      assert configured["gh"]["env"] == %{
               "TOKEN" => "ghp_from_the_keyring",
               "OTHER" => "from-the-env",
               "MISSING" => ""
             }

      assert configured["gh"]["policy"]["deny"] == ["delete_*"]
      assert configured["odd"]["policy"] == %{}
      assert configured["odd"]["policy_error"] =~ "no policy template called nope"
      # tiny-axe's own browser can't be replaced from mcp.json.
      refute Map.has_key?(configured, "browser")
    end

    test "adding and removing keeps the rest of the file, readable only by the user", %{
      path: path
    } do
      write(path, %{"keep" => %{"command" => "a"}})

      :ok = MCP.put_config("new", %{"command" => "b", "policy" => "memory"})

      assert %{"mcpServers" => %{"keep" => _, "new" => %{"policy" => "memory"}}} =
               JSON.decode!(File.read!(path))

      assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600

      :ok = MCP.delete_config("new")
      assert JSON.decode!(File.read!(path))["mcpServers"] |> Map.keys() == ["keep"]

      assert MCP.put_config("browser", %{}) == {:error, :reserved}
      assert MCP.put_config("bad name!", %{}) == {:error, :bad_name}
    end
  end

  describe "status" do
    test "running servers list their tools by class; failed ones say why", %{path: path} do
      name = "st#{System.unique_integer([:positive])}"

      write(path, %{
        name => %{
          "command" => @server,
          "policy" => %{"read" => ["echo"], "deny" => ["delete_all"]}
        },
        "gone" => %{"command" => "no-such-mcp-server"}
      })

      assert [{"gone", _}] = MCP.start_configured()
      on_exit(fn -> MCP.stop_server(name) end)

      by_name = Map.new(MCP.status(), &{&1.name, &1})
      assert by_name[name].running
      assert by_name[name].tools[:read] == ["echo"]
      assert "send_note" in by_name[name].tools[:outward]
      assert by_name[name].tools[:refused] == ["delete_all"]

      refute by_name["gone"].running
      assert by_name["gone"].error == "no-such-mcp-server isn't installed"
    end
  end

  describe "mix tiny_axe.mcp" do
    setup do
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    end

    defp output do
      receive do
        {:mix_shell, _, [line]} -> [line | output()]
      after
        0 -> []
      end
    end

    test "add with a template, check it, and remove it", %{path: path} do
      Mix.Tasks.TinyAxe.Mcp.run([
        "add",
        "fake",
        "--template",
        "memory",
        "--env",
        "TOKEN=${keyring:github}",
        "--",
        @server
      ])

      assert %{
               "command" => @server,
               "policy" => "memory",
               "env" => %{"TOKEN" => "${keyring:github}"}
             } =
               JSON.decode!(File.read!(path))["mcpServers"]["fake"]

      Mix.Tasks.TinyAxe.Mcp.run(["check", "fake"])
      out = Enum.join(output(), "\n")
      assert out =~ "✓ fake: 8 tools"
      # The memory template names none of the fake's tools: they all ask.
      assert out =~ "asks you each time:"

      Mix.Tasks.TinyAxe.Mcp.run(["remove", "fake"])
      assert JSON.decode!(File.read!(path))["mcpServers"] == %{}
    end

    test "secrets: says how to use the keyring, without asking for the secret" do
      Mix.Tasks.TinyAxe.Mcp.run(["secret", "github"])

      assert Enum.join(output(), "\n") =~
               "secret-tool store --label=\"tiny-axe github\" service tiny-axe key github"
    end
  end

  test "the TUI's tools command shows what the agent can use", %{path: path} do
    name = "tu#{System.unique_integer([:positive])}"
    write(path, %{name => %{"command" => @server, "policy" => %{"read" => ["echo", "calls"]}}})
    MCP.start_configured()
    on_exit(fn -> MCP.stop_server(name) end)

    {:ok, state} = TUI.mount(test_mode: {100, 30})
    ExRatatui.textarea_set_value(state.input, "tools")

    {:noreply, state} =
      TUI.handle_event(%ExRatatui.Event.Key{code: "enter", kind: "press", modifiers: []}, state)

    metas = for {:meta, m} <- state.transcript, do: m
    assert Enum.any?(metas, &(&1 =~ "🔧 #{name}: 2 run, 6 ask you first"))
    assert state.run == nil
  end
end
