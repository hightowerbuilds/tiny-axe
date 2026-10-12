defmodule TinyAxe.SyncTest do
  @moduledoc """
  Sending the chats to the site (`TinyAxe.Sync`), through the real MCP
  client to a fake site (test/support/fake_site.ex).
  """

  use ExUnit.Case, async: false

  alias TinyAxe.{FakeSite, MCP, SiteTest, Sync}

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    site = FakeSite.start()
    previous = Application.get_env(:tiny_axe, :site)
    Application.put_env(:tiny_axe, :site, Keyword.put(previous, :url, site.url))
    MCP.stop_server("site")
    SiteTest.sign_in(site)
    File.rm(Sync.path())

    history = Path.join(dir, "history")
    File.mkdir_p!(history)

    on_exit(fn ->
      MCP.stop_server("site")
      Application.put_env(:tiny_axe, :site, previous)
      File.rm(Sync.path())
      File.rm(TinyAxe.Account.path())
    end)

    %{site: site, history: history}
  end

  defp run(ctx), do: Sync.run(history: ctx.history)

  defp chat(ctx, id, title) do
    doc = %{
      version: 1,
      id: id,
      session: "20261011-152900-77ff",
      title: title,
      started: "2026-10-11T15:30:12Z",
      updated: "2026-10-11T15:31:00Z",
      folder: "~",
      entries: [%{kind: "user", text: title}],
      context: %{messages: ["what reopening gives the model"]}
    }

    File.write!(Path.join(ctx.history, id <> ".json"), JSON.encode!(doc))
  end

  defp pushes do
    receive do
      {:site_call, "chat_push", args} -> [args | pushes()]
      {:site_call, _tool, _args} -> pushes()
    after
      0 -> []
    end
  end

  test "sends every chat once, without its context", ctx do
    chat(ctx, "20261011-153012-a1b2", "what's using port 4000?")
    assert run(ctx) == {:ok, %{chats: 1}}

    [%{"chat" => sent}] = pushes()
    refute Map.has_key?(sent, "context")
    assert sent["title"] == "what's using port 4000?"

    # Nothing changed, nothing sent.
    assert run(ctx) == {:ok, %{chats: 0}}
    assert pushes() == []
  end

  test "only what changed goes again", ctx do
    chat(ctx, "20261011-153012-a1b2", "what's using port 4000?")
    {:ok, _} = run(ctx)
    pushes()

    chat(ctx, "20261011-153012-a1b2", "what's using port 4001?")
    chat(ctx, "20261011-160000-beef", "a new chat")

    assert run(ctx) == {:ok, %{chats: 2}}

    assert pushes() |> Enum.map(& &1["chat"]["title"]) |> Enum.sort() == [
             "a new chat",
             "what's using port 4001?"
           ]
  end

  test "a site that's down: nothing recorded, all of it goes once it's back", ctx do
    chat(ctx, "20261011-153012-a1b2", "what's using port 4000?")
    broken = FakeSite.start(fail: true)
    Application.put_env(:tiny_axe, :site, url: broken.url)
    SiteTest.sign_in(broken)
    assert {:error, _} = run(ctx)

    MCP.stop_server("site")
    Application.put_env(:tiny_axe, :site, url: ctx.site.url)
    SiteTest.sign_in(ctx.site)
    assert run(ctx) == {:ok, %{chats: 1}}
  end

  test "another account starts afresh", ctx do
    chat(ctx, "20261011-153012-a1b2", "what's using port 4000?")
    {:ok, _} = run(ctx)

    File.write!(
      TinyAxe.Account.path(),
      JSON.encode!(%{username: "someone-else", site: ctx.site.url})
    )

    assert run(ctx) == {:ok, %{chats: 1}}
  end

  test "no account, nothing sent", ctx do
    File.rm(TinyAxe.Account.path())
    assert run(ctx) == {:error, "no account yet"}
    assert pushes() == []
  end
end
