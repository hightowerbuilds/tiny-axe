defmodule TinyAxe.GraphTest do
  @moduledoc """
  The know-how graph as an MCP server (`TinyAxe.Graph`) and `/graph` in the
  TUI, with a fake viewer (test/support/fake_mcp/graph.mjs) run by node.
  """

  # The server runs under the app-wide name "graph", and the settings and
  # XDG_DATA_HOME are app-wide too, so not async.
  use ExUnit.Case, async: false

  alias TinyAxe.{Graph, MCP, TUI}
  alias TinyAxe.Tools.Policy

  @moduletag :tmp_dir
  @fake Path.expand("../support/fake_mcp/graph.mjs", __DIR__)
  @repo_server Path.expand("../../graph/dist/server.js", __DIR__)

  setup %{tmp_dir: dir} do
    if System.find_executable("node") == nil, do: raise("these tests need node")

    previous = Application.get_env(:tiny_axe, :graph)
    data = System.get_env("XDG_DATA_HOME")
    vault = Path.join(dir, "vault")
    File.mkdir_p!(vault)
    Application.put_env(:tiny_axe, :graph, server_js: @fake, vault: vault, port: 5151)
    MCP.stop_server("graph")

    on_exit(fn ->
      MCP.stop_server("graph")
      Application.put_env(:tiny_axe, :graph, previous || [])
      if data, do: System.put_env("XDG_DATA_HOME", data), else: System.delete_env("XDG_DATA_HOME")
    end)

    %{vault: vault}
  end

  describe "the server" do
    test "server.js: the setting, else the installed copy, else the repo's build", %{
      tmp_dir: dir
    } do
      assert Graph.server_js() == @fake

      Application.put_env(:tiny_axe, :graph, [])
      System.put_env("XDG_DATA_HOME", dir)
      assert Graph.server_js() == if(File.regular?(@repo_server), do: @repo_server)

      installed = Path.join(dir, "tiny-axe/graph/server.js")
      File.mkdir_p!(Path.dirname(installed))
      File.write!(installed, "")
      assert Graph.server_js() == installed
    end

    test "config: node runs it in MCP mode, and both tools are local", %{vault: vault} do
      config = Graph.config()
      assert config["command"] == System.find_executable("node")
      assert config["args"] == [@fake, "--mcp", "--vault", vault, "--port", "5151"]

      for tool <- ["graph_open", "graph_close"],
          do: assert(Policy.classify(%{"name" => tool}, config["policy"]) == :local)

      Application.put_env(:tiny_axe, :graph, server_js: @fake)
      assert Graph.config()["args"] == [@fake, "--mcp"]
    end

    test "\"graph\" is tiny-axe's own: mcp.json can't use it", %{tmp_dir: dir} do
      previous = Application.get_env(:tiny_axe, :mcp_config)
      path = Path.join(dir, "mcp.json")
      Application.put_env(:tiny_axe, :mcp_config, path)
      on_exit(fn -> Application.put_env(:tiny_axe, :mcp_config, previous) end)

      assert MCP.put_config("graph", %{}) == {:error, :reserved}
      File.write!(path, JSON.encode!(%{"mcpServers" => %{"graph" => %{"command" => "x"}}}))
      ExUnit.CaptureLog.capture_log(fn -> assert MCP.configured() == %{} end)
    end

    test "open starts the server and gives the link; close stops the page" do
      refute Graph.running?()
      assert {:ok, "http://127.0.0.1:5151/?t=tok_3x-Q*9"} = Graph.open()
      assert Graph.running?()

      assert {:ok, url} = Graph.open("notes/a b.md")
      assert url =~ "focus=notes%2Fa%20b.md&"

      # The agent sees them as graph__graph_open and graph__graph_close, and runs them.
      tools = MCP.tools(["graph"])
      assert Enum.map(tools, & &1.name) == ["graph__graph_open", "graph__graph_close"]
      assert Enum.all?(tools, &(Policy.classify(&1.definition, &1.policy) == :local))

      assert Graph.close() == :ok
    end

    test "with no vault yet, open says so", %{tmp_dir: dir} do
      Application.put_env(:tiny_axe, :graph, server_js: @fake, vault: Path.join(dir, "none"))
      assert {:error, "there's no vault at " <> _} = Graph.open()
    end
  end

  describe "/graph" do
    defp type(state, text) do
      ExRatatui.textarea_set_value(state.input, text)

      {:noreply, state} =
        TUI.handle_event(%ExRatatui.Event.Key{code: "enter", kind: "press", modifiers: []}, state)

      state
    end

    # The built-in runs aside; its answer comes back as a message.
    defp settle(state) do
      receive do
        {:graph, _} = msg ->
          {:noreply, state} = TUI.handle_info(msg, state)
          state
      after
        15_000 -> flunk("/graph never answered")
      end
    end

    defp metas(state), do: for({:meta, m} <- state.transcript, do: m)

    defp draw(state) do
      terminal = ExRatatui.init_test_terminal(110, 30)
      ExRatatui.draw(terminal, TUI.render(state, %ExRatatui.Frame{width: 110, height: 30}))
      ExRatatui.get_buffer_content(terminal)
    end

    test "shows the link on its own line and copies it, without a model" do
      me = self()
      copy = fn url -> send(me, {:copied, url}) && :ok end
      {:ok, state} = TUI.mount(test_mode: {110, 30}, clipboard: copy)

      state = type(state, "/graph")
      assert state.run == nil
      assert state.status == "opening the graph…"

      state = settle(state)
      url = "http://127.0.0.1:5151/?t=tok_3x-Q*9"
      assert_received {:copied, ^url}

      assert [shown, link] = Enum.take(metas(state), -2)
      assert shown =~ "served on this computer only; the link is copied"
      assert link == "`#{url}`"
      assert state.status == "ready"

      # On screen, the URL is whole: Markdown doesn't eat its * or _.
      assert draw(state) =~ url
    end

    test "says nothing about copying when the clipboard fails" do
      {:ok, state} = TUI.mount(test_mode: {110, 30}, clipboard: fn _ -> {:error, :nope} end)
      state = state |> type("/graph") |> settle()
      [shown, _link] = Enum.take(metas(state), -2)
      refute shown =~ "copied"
    end

    test "shows the viewer's error, and close and anything else", %{tmp_dir: dir} do
      Application.put_env(:tiny_axe, :graph, server_js: @fake, vault: Path.join(dir, "none"))
      {:ok, state} = TUI.mount(test_mode: {110, 30}, clipboard: fn _ -> flunk("copied") end)

      state = state |> type("/graph") |> settle()
      assert "✗ graph: there's no vault at " <> _ = List.last(metas(state))

      state = state |> type("/graph close") |> settle()
      assert List.last(metas(state)) == "🧠 closed the graph page"

      state = type(state, "/graph please")
      assert List.last(metas(state)) == "/graph · /graph close"
      refute_received {:graph, _}
    end
  end
end
