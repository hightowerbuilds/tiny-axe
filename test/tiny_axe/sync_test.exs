defmodule TinyAxe.SyncTest do
  @moduledoc """
  Sending the vault and the chats to the site (`TinyAxe.Sync`), through the
  real MCP client to a fake site (test/support/fake_site.ex).
  """

  use ExUnit.Case, async: false

  alias TinyAxe.{FakeSite, GraphTest, MCP, Sync}

  @moduletag :tmp_dir
  @fixture Path.expand("../fixtures/vault/vault", __DIR__)

  setup %{tmp_dir: dir} do
    site = FakeSite.start()
    previous = Application.get_env(:tiny_axe, :site)
    Application.put_env(:tiny_axe, :site, Keyword.put(previous, :url, site.url))
    MCP.stop_server("graph")
    GraphTest.sign_in(site)
    File.rm(Sync.path())

    vault = Path.join(dir, "vault")
    File.cp_r!(@fixture, vault)
    history = Path.join(dir, "history")
    File.mkdir_p!(history)

    on_exit(fn ->
      MCP.stop_server("graph")
      Application.put_env(:tiny_axe, :site, previous)
      File.rm(Sync.path())
      File.rm(TinyAxe.Account.path())
    end)

    %{site: site, vault: vault, history: history}
  end

  defp run(ctx), do: Sync.run(vault: ctx.vault, history: ctx.history)

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
      {:site_call, tool, args} when tool in ["vault_push", "chat_push"] ->
        [{tool, args} | pushes()]

      {:site_call, _tool, _args} ->
        pushes()
    after
      0 -> []
    end
  end

  test "sends every note and chat once, without the chat's context", ctx do
    chat(ctx, "20261011-153012-a1b2", "what's using port 4000?")
    assert run(ctx) == {:ok, %{notes: 28, chats: 1}}

    [{"vault_push", notes}, {"chat_push", %{"chat" => sent_chat}}] = pushes()
    assert notes["manifest"]["schema"] == "tiny-axe-vault/1"
    assert length(notes["notes"]) == 28

    assert %{"folder" => "Sites", "id" => "shop.example", "text" => "---\n" <> _} =
             Enum.find(notes["notes"], &(&1["id"] == "shop.example"))

    refute Map.has_key?(sent_chat, "context")
    assert sent_chat["title"] == "what's using port 4000?"

    # Nothing changed, nothing sent.
    assert run(ctx) == {:ok, %{notes: 0, chats: 0}}
    assert pushes() == []
  end

  test "only what changed goes again", ctx do
    {:ok, _} = run(ctx)
    pushes()

    path = Path.join([ctx.vault, "Sites", "shop.example.md"])
    File.write!(path, File.read!(path) <> "\nMore.\n")
    chat(ctx, "20261011-160000-beef", "a new chat")

    assert run(ctx) == {:ok, %{notes: 1, chats: 1}}

    assert [{"vault_push", %{"notes" => [%{"id" => "shop.example"}]}}, {"chat_push", _}] =
             pushes()
  end

  test "a big vault goes in batches of 200", ctx do
    note = File.read!(Path.join([ctx.vault, "Sites", "shop.example.md"]))

    for i <- 1..250,
        do: File.write!(Path.join([ctx.vault, "Pages", "page-#{i}.md"]), note <> "#{i}\n")

    assert {:ok, %{notes: 278}} = run(ctx)
    assert [{"vault_push", a}, {"vault_push", b}] = pushes()
    assert {length(a["notes"]), length(b["notes"])} == {200, 78}
  end

  test "a note the site refuses isn't recorded, so it's tried again", ctx do
    File.write!(Path.join([ctx.vault, "Sites", "bad note.md"]), "---\nkind: \"site\"\n---\n")

    log = ExUnit.CaptureLog.capture_log(fn -> assert {:ok, %{notes: 28}} = run(ctx) end)
    assert log =~ "note bad note refused"
    pushes()

    ExUnit.CaptureLog.capture_log(fn -> assert {:ok, %{notes: 0}} = run(ctx) end)
    assert [{"vault_push", %{"notes" => [%{"id" => "bad note"}]}}] = pushes()
  end

  test "a site that's down: nothing recorded, all of it goes once it's back", ctx do
    broken = FakeSite.start(fail: true)
    Application.put_env(:tiny_axe, :site, url: broken.url)
    GraphTest.sign_in(broken)
    assert {:error, _} = run(ctx)

    MCP.stop_server("graph")
    Application.put_env(:tiny_axe, :site, url: ctx.site.url)
    GraphTest.sign_in(ctx.site)
    assert run(ctx) == {:ok, %{notes: 28, chats: 0}}
  end

  test "another account starts afresh", ctx do
    {:ok, _} = run(ctx)

    File.write!(
      TinyAxe.Account.path(),
      JSON.encode!(%{username: "someone-else", site: ctx.site.url})
    )

    assert run(ctx) == {:ok, %{notes: 28, chats: 0}}
  end

  test "no account, nothing sent", ctx do
    File.rm(TinyAxe.Account.path())
    assert run(ctx) == {:error, "no account yet"}
    assert pushes() == []
  end
end
