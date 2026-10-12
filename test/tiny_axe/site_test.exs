defmodule TinyAxe.SiteTest do
  @moduledoc """
  tiny-axe's website as an MCP server (`TinyAxe.Site`) and `/site` in the
  TUI, against a fake site (test/support/fake_site.ex) reached over HTTP by
  the real MCP client.
  """

  # The connection runs under the app-wide name "site", and the account and
  # its key are app-wide too, so not async.
  use ExUnit.Case, async: false

  alias TinyAxe.{Account, FakeSite, MCP, Site, TUI}
  alias TinyAxe.Tools.Policy

  @keyring Path.join(System.get_env("TMPDIR", "/tmp"), "tiny_axe_fake_keyring")

  setup do
    site = FakeSite.start()
    previous = Application.get_env(:tiny_axe, :site)
    Application.put_env(:tiny_axe, :site, Keyword.put(previous, :url, site.url))
    MCP.stop_server("site")
    sign_in(site)

    on_exit(fn ->
      MCP.stop_server("site")
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

  # How the site's links are opened, for this test only.
  defp opener(fun),
    do: Application.put_env(:tiny_axe, :site, Keyword.put(site_env(), :opener, fun))

  defp site_env, do: Application.get_env(:tiny_axe, :site)

  defp point_at(site) do
    Application.put_env(:tiny_axe, :site, Keyword.put(site_env(), :url, site.url))
    sign_in(site)
  end

  describe "the connection" do
    test "config: HTTP to the site with the account's key; reads run, pushes are hidden", %{
      site: site
    } do
      config = Site.config()
      assert config["type"] == "http"
      assert config["url"] == site.url <> "/api/mcp"
      assert config["headers"] == %{"authorization" => "Bearer " <> site.key}

      for tool <- ~w(chat_search chat_read site_link),
          do: assert(Policy.classify(%{"name" => tool}, config["policy"]) == :read)

      assert config["policy"]["hidden"] == ["chat_push", "signin_link"]
    end

    test "no account, no connection" do
      sign_out()
      refute Site.available?()
      assert Site.config() == nil
      assert {:error, "there's no tiny-axe account" <> _} = Site.open()
    end

    test "open connects and gives the link to the chats, or to one chat", %{site: site} do
      refute Site.running?()
      assert Site.open() == {:ok, site.url <> "/chats"}
      assert Site.running?()
      assert_received {:site_call, "site_link", %{}}

      assert Site.open("20261012-100000-1") == {:ok, site.url <> "/chats/20261012-100000-1"}
      assert_received {:site_call, "site_link", %{"chat" => "20261012-100000-1"}}

      names = MCP.tools(["site"]) |> Enum.map(& &1.name)
      assert "site__chat_search" in names

      # The key is in the connection's headers, but never in its status.
      [{pid, _}] = Registry.lookup(TinyAxe.MCP.Registry, "site")
      refute inspect(:sys.get_status(pid)) =~ site.key
    end

    test "through the gate, agents get the read tools; the pushes are neither listed nor callable" do
      {:ok, _} = Site.start()
      me = self()
      {:ok, task} = TinyAxe.Tools.Gate.open_task(&send(me, {:gate, &1}), servers: ["site"])
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
      assert "site__chat_search" in names
      assert "site__chat_read" in names
      assert "site__site_link" in names
      refute "site__chat_push" in names
      refute "site__signin_link" in names

      result = rpc.("tools/call", %{name: "site__chat_push", arguments: %{chat: %{}}})
      assert result["isError"] == true
      refute_received {:site_call, "chat_push", _}

      # A search runs without asking.
      result = rpc.("tools/call", %{name: "site__chat_search", arguments: %{q: "printer"}})
      refute result["isError"]
      assert_received {:site_call, "chat_search", %{"q" => "printer"}}
      refute_received {:gate, {:tool_approval, _}}
    end

    test "open_in_browser: the browser gets the one-time sign-in link; tiny-axe keeps the plain one",
         %{site: site} do
      me = self()
      opener(&(send(me, {:opened, &1}) && :ok))

      assert Site.open_in_browser() == {:ok, site.url <> "/chats"}
      assert_received {:opened, link}
      assert link == site.url <> "/chats#signin=one-time-token"

      assert Site.open_in_browser("20261012-100000-1") ==
               {:ok, site.url <> "/chats/20261012-100000-1"}
    end

    test "open_in_browser: switched off (as in tests), or no desktop, says so" do
      assert Site.open_in_browser() == {:error, "opening the browser is switched off"}
      refute_received {:site_call, "signin_link", _}
    end

    test "open_in_browser: a sign-in link for another site is never opened" do
      point_at(FakeSite.start(link: "https://elsewhere.example"))
      opener(fn _ -> flunk("opened another site") end)
      assert {:error, "the site didn't give a link to itself"} = Site.open_in_browser()
    end

    test "site_open: agents get it, it runs without asking, and opens the browser signed in" do
      me = self()
      opener(&(send(me, {:opened, &1}) && :ok))
      {:ok, _} = Site.start()
      {:ok, task} = TinyAxe.Tools.Gate.open_task(&send(me, {:gate, &1}), servers: ["site"])
      on_exit(fn -> TinyAxe.Tools.Gate.close_task(task.id) end)

      rpc = fn method, params ->
        Req.post!(task.url,
          json: %{jsonrpc: "2.0", id: 1, method: method, params: params},
          headers: %{"authorization" => "Bearer #{task.token}"},
          retry: false
        ).body["result"]
      end

      names = rpc.("tools/list", %{})["tools"] |> Enum.map(& &1["name"])
      assert "site_open" in names

      result = rpc.("tools/call", %{name: "site_open", arguments: %{chat: "20261012-100000-1"}})
      refute result["isError"]
      [%{"text" => said}] = result["content"]
      assert said =~ "Opened"
      # The model never sees the sign-in token.
      refute said =~ "signin"
      assert_received {:opened, link}
      assert link =~ "/chats/20261012-100000-1#signin="
      refute_received {:gate, {:tool_approval, _}}

      # And it can't get a sign-in link itself.
      assert rpc.("tools/call", %{name: "site__signin_link", arguments: %{}})["isError"]
    end

    test "a link anywhere but the site is refused" do
      point_at(FakeSite.start(link: "https://elsewhere.example"))
      assert {:error, "the site didn't give a link to itself"} = Site.open()
    end

    test "a site that's down says so" do
      point_at(FakeSite.start(fail: true))
      assert {:error, message} = Site.open()
      assert message =~ "couldn't connect"
    end
  end

  describe "/site" do
    defp type(state, text) do
      ExRatatui.textarea_set_value(state.input, text)

      {:noreply, state} =
        TUI.handle_event(%ExRatatui.Event.Key{code: "enter", kind: "press", modifiers: []}, state)

      state
    end

    # The built-in runs aside; its answer comes back as a message.
    defp settle(state) do
      receive do
        {:site, _} = msg ->
          {:noreply, state} = TUI.handle_info(msg, state)
          state
      after
        15_000 -> flunk("/site never answered")
      end
    end

    defp metas(state), do: for({:meta, m} <- state.transcript, do: m)

    test "opens the chats in the browser, signed in, and shows the plain link", %{site: site} do
      me = self()
      opener(&(send(me, {:opened, &1}) && :ok))

      {:ok, state} =
        TUI.mount(test_mode: {110, 30}, clipboard: fn url -> send(me, {:copied, url}) && :ok end)

      state = state |> type("/site") |> settle()
      assert_received {:opened, link}
      assert link =~ "#signin="
      url = site.url <> "/chats"
      assert_received {:copied, ^url}
      assert [shown, shown_link] = Enum.take(metas(state), -2)
      assert shown =~ "opened your chats on tiny-axe's website in your browser, signed in as sam"
      assert shown_link == "`#{url}`"
      refute Enum.any?(metas(state), &(&1 =~ "signin"))
    end

    test "shows the site's link on its own line and copies it, without a model", %{site: site} do
      me = self()
      copy = fn url -> send(me, {:copied, url}) && :ok end
      {:ok, state} = TUI.mount(test_mode: {110, 30}, clipboard: copy)

      state = type(state, "/site")
      assert state.run == nil
      state = settle(state)

      url = site.url <> "/chats"
      assert_received {:copied, ^url}
      assert [shown, link] = Enum.take(metas(state), -2)

      assert shown =~
               "on your page of tiny-axe's website (sign in to see them; couldn't open your browser"

      assert shown =~ "the link is copied"
      assert link == "`#{url}`"
      assert state.status == "ready"
    end

    test "without an account, says how to make one" do
      sign_out()
      {:ok, state} = TUI.mount(test_mode: {110, 30}, clipboard: fn _ -> flunk("copied") end)
      state = state |> type("/site") |> settle()
      assert List.last(metas(state)) =~ "/account sets one up"
    end
  end
end
