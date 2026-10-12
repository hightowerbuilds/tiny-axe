defmodule TinyAxe.GraphTest do
  @moduledoc """
  tiny-axe's website as an MCP server (`TinyAxe.Graph`) and `/graph` in the
  TUI, against a fake site (test/support/fake_site.ex) reached over HTTP by
  the real MCP client.
  """

  # The connection runs under the app-wide name "graph", and the account and
  # its key are app-wide too, so not async.
  use ExUnit.Case, async: false

  alias TinyAxe.{Account, FakeSite, Graph, MCP, TUI}
  alias TinyAxe.Tools.Policy

  @keyring Path.join(System.get_env("TMPDIR", "/tmp"), "tiny_axe_fake_keyring")

  setup do
    site = FakeSite.start()
    previous = Application.get_env(:tiny_axe, :site)
    Application.put_env(:tiny_axe, :site, Keyword.put(previous, :url, site.url))
    MCP.stop_server("graph")
    sign_in(site)

    on_exit(fn ->
      MCP.stop_server("graph")
      Application.put_env(:tiny_axe, :site, previous)
      File.rm(Account.path())
      File.rm(Path.join(@keyring, "site"))
    end)

    %{site: site}
  end

  # An account on this computer, as the account step leaves it.
  def sign_in(site) do
    File.mkdir_p!(@keyring)
    File.write!(Path.join(@keyring, "site"), site.key)
    File.mkdir_p!(Path.dirname(Account.path()))
    File.write!(Account.path(), JSON.encode!(%{username: "sam", site: site.url}))
  end

  defp sign_out, do: File.rm(Path.join(@keyring, "site"))

  describe "the connection" do
    test "config: HTTP to the site with the account's key; reads run, pushes are hidden", %{
      site: site
    } do
      config = Graph.config()
      assert config["type"] == "http"
      assert config["url"] == site.url <> "/api/mcp"
      assert config["headers"] == %{"authorization" => "Bearer " <> site.key}

      for tool <- ~w(graph_overview graph_search graph_note graph_link),
          do: assert(Policy.classify(%{"name" => tool}, config["policy"]) == :read)

      assert config["policy"]["hidden"] == ["vault_push", "chat_push"]
    end

    test "no account, no connection" do
      sign_out()
      refute Graph.available?()
      assert Graph.config() == nil
      assert {:error, "there's no tiny-axe account" <> _} = Graph.open()
    end

    test "open connects and gives the link to the site: the graph, a note, the chats", %{
      site: site
    } do
      refute Graph.running?()
      assert Graph.open() == {:ok, site.url <> "/"}
      assert Graph.running?()
      assert_received {:site_call, "graph_link", %{}}

      assert Graph.open("shop.example") == {:ok, site.url <> "/note/shop.example"}
      assert Graph.open(nil, page: "chats") == {:ok, site.url <> "/chats"}

      names = MCP.tools(["graph"]) |> Enum.map(& &1.name)
      assert "graph__graph_search" in names

      # The key is in the connection's headers, but never in its status.
      [{pid, _}] = Registry.lookup(TinyAxe.MCP.Registry, "graph")
      refute inspect(:sys.get_status(pid)) =~ site.key
    end

    test "through the gate, agents get the read tools; the pushes are neither listed nor callable" do
      {:ok, _} = Graph.start()
      me = self()
      {:ok, task} = TinyAxe.Tools.Gate.open_task(&send(me, {:gate, &1}), servers: ["graph"])
      on_exit(fn -> TinyAxe.Tools.Gate.close_task(task.id) end)

      # As an agent reaches it: the task's own address and token.
      rpc = fn method, params ->
        Req.post!(task.url,
          json: %{jsonrpc: "2.0", id: 1, method: method, params: params},
          headers: %{"authorization" => "Bearer #{task.token}"},
          retry: false
        ).body["result"]
      end

      names = rpc.("tools/list", %{})["tools"] |> Enum.map(& &1["name"])
      assert "graph__graph_search" in names
      assert "graph__graph_link" in names
      refute "graph__vault_push" in names
      refute "graph__chat_push" in names

      result =
        rpc.("tools/call", %{name: "graph__vault_push", arguments: %{manifest: %{}, notes: []}})

      assert result["isError"] == true
      refute_received {:site_call, "vault_push", _}

      # A read runs without asking.
      result = rpc.("tools/call", %{name: "graph__graph_search", arguments: %{q: "cart"}})
      refute result["isError"]
      assert_received {:site_call, "graph_search", %{"q" => "cart"}}
      refute_received {:gate, {:tool_approval, _}}
    end

    test "a link anywhere but the site is refused" do
      odd = FakeSite.start(link: "https://elsewhere.example")
      Application.put_env(:tiny_axe, :site, url: odd.url)
      sign_in(odd)
      assert {:error, "the site didn't give a link to itself"} = Graph.open()
    end

    test "a site that's down says so" do
      broken = FakeSite.start(fail: true)
      Application.put_env(:tiny_axe, :site, url: broken.url)
      sign_in(broken)
      assert {:error, message} = Graph.open()
      assert message =~ "couldn't connect"
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

    test "shows the site's link on its own line and copies it, without a model", %{site: site} do
      me = self()
      copy = fn url -> send(me, {:copied, url}) && :ok end
      {:ok, state} = TUI.mount(test_mode: {110, 30}, clipboard: copy)

      state = type(state, "/graph")
      assert state.run == nil
      state = settle(state)

      url = site.url <> "/"
      assert_received {:copied, ^url}
      assert [shown, link] = Enum.take(metas(state), -2)
      assert shown =~ "on your page of its website (sign in to see it); the link is copied"
      assert link == "`#{url}`"
      assert state.status == "ready"
    end

    test "/graph chats, /graph close, and anything else", %{site: site} do
      {:ok, state} = TUI.mount(test_mode: {110, 30}, clipboard: fn _ -> :ok end)

      state = state |> type("/graph chats") |> settle()
      assert List.last(metas(state)) == "`#{site.url}/chats`"

      state = state |> type("/graph close") |> settle()
      assert List.last(metas(state)) =~ "nothing here to close"

      state = type(state, "/graph please")
      assert List.last(metas(state)) == "/graph · /graph chats"
    end

    test "without an account, says how to make one" do
      sign_out()
      {:ok, state} = TUI.mount(test_mode: {110, 30}, clipboard: fn _ -> flunk("copied") end)
      state = state |> type("/graph") |> settle()
      assert List.last(metas(state)) =~ "/account sets one up"
    end
  end
end
