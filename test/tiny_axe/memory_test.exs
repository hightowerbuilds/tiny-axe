defmodule TinyAxe.MemoryTest do
  use ExUnit.Case, async: false
  alias TinyAxe.{History, Memory}
  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    history = Path.join(dir, "history")
    File.mkdir_p!(history)
    path = Path.join(dir, "memory.sqlite3")
    server = start_supervised!({Memory, name: :memory_test, history: history, path: path})
    %{history: history, path: path, opts: [server: server, history: history, sync: false]}
  end

  defp save(ctx, texts, id \\ History.new_id()) do
    entries =
      Enum.map(texts, fn
        {kind, text} -> %{kind: kind, text: text}
        text -> %{kind: "user", text: text}
      end)

    doc = %{
      version: 1,
      id: id,
      title: "A saved chat",
      updated: "2026-01-01T00:00:00Z",
      entries: entries
    }

    File.write!(Path.join(ctx.history, id <> ".json"), JSON.encode!(doc))
    id
  end

  defp search(ctx, q, opts \\ []), do: Memory.search(q, Keyword.merge(ctx.opts, opts))

  test "full messages, word boundaries, ordered phrases and punctuation", ctx do
    id =
      save(ctx, [
        "The GRAPHICS card arrived.",
        "graphics fast card",
        "graphics",
        "card",
        "discard",
        "graphics, card",
        "café cafe C++ --flag /tmp/a_b"
      ])

    assert {:ok, %{total: 3}} = search(ctx, "graphics card")
    assert {:ok, %{total: 2, hits: hits}} = search(ctx, "\"graphics card\"")
    assert Enum.all?(hits, &(&1.chat_id == id))
    assert {:ok, %{total: 4}} = search(ctx, "card")
    assert {:ok, %{total: 0}} = search(ctx, "\"card graphics\"")
    assert {:ok, %{total: 1}} = search(ctx, "café")
    assert {:ok, %{total: 1}} = search(ctx, "C++", mode: :literal)
    assert {:ok, %{total: 0}} = search(ctx, "c++", mode: :literal)
    assert {:ok, %{total: 1}} = search(ctx, "--flag", mode: :literal)
    assert {:ok, %{total: 1}} = search(ctx, "_b", mode: :literal)
  end

  test "literal search preserves symbols and short strings; queries cannot become SQL or FTS operators",
       ctx do
    save(ctx, ["x % _ ' OR", "innocent"])
    for q <- ["x", "%", "_", "'"], do: assert({:ok, %{total: 1}} = search(ctx, q, mode: :literal))
    assert {:ok, %{total: 1}} = search(ctx, "OR")
    assert {:ok, %{total: 0}} = search(ctx, "x OR innocent")
    assert {:error, _} = search(ctx, "\"unclosed")
    assert {:error, _} = search(ctx, "***")
    assert {:ok, %{total: 0}} = search(ctx, "' OR 1=1; DROP TABLE chats", mode: :literal)
    assert {:ok, %{chats: 1}} = Memory.status(ctx.opts)
  end

  test "finds the middle of a long entry and never assembles a phrase across entries", ctx do
    save(ctx, [
      String.duplicate("before ", 1600) <>
        "violet submarine decision" <> String.duplicate(" after", 1600),
      "violet",
      "submarine decision"
    ])

    assert {:ok, %{total: 1, hits: [hit]}} = search(ctx, "\"violet submarine decision\"")
    assert hit.excerpt =~ "violet"
    assert {:ok, %{entry: entry}} = Memory.read(hit, ctx.opts)
    assert String.length(entry["text"]) > 10_000
  end

  test "changes and deletions replace old rows, invalidate citations and rebuild safely", ctx do
    id = save(ctx, ["violet submarine"])
    assert {:ok, %{hits: [old]}} = search(ctx, "violet")
    save(ctx, ["orange submarine", "new turn"], id)
    assert {:ok, %{total: 0}} = search(ctx, "violet")
    assert {:error, :stale_source} = Memory.read(old, ctx.opts)
    assert {:ok, %{chats: 1, entries: 2}} = Memory.rebuild(ctx.opts)
    assert {:ok, %{total: 1}} = search(ctx, "orange")
    File.rm!(Path.join(ctx.history, id <> ".json"))
    assert {:ok, %{total: 0, coverage: %{chats: 0}}} = search(ctx, "orange")
  end

  test "malformed entries remove stale hits and report incomplete coverage", ctx do
    id = save(ctx, ["needle"])
    assert {:ok, %{total: 1}} = search(ctx, "needle")
    File.write!(Path.join(ctx.history, id <> ".json"), JSON.encode!(%{id: id, entries: [nil]}))
    assert {:ok, %{total: 0, coverage: %{total: 1, failures: [^id]}}} = search(ctx, "needle")
    File.write!(Path.join(ctx.history, "notes.tmp"), "ignored")
    assert {:ok, %{total: 1, failures: [^id]}} = Memory.status(ctx.opts)
  end

  test "pagination covers all results and the cache survives restart with private permissions",
       ctx do
    for n <- 1..25, do: save(ctx, ["needle #{n}"])

    pages =
      for offset <- [0, 10, 20] do
        assert {:ok, %{total: 25, hits: hits}} = search(ctx, "needle", offset: offset)
        hits
      end

    assert length(Enum.uniq_by(List.flatten(pages), & &1.chat_id)) == 25
    assert Bitwise.band(File.stat!(ctx.path).mode, 0o777) == 0o600
    stop_supervised!(Memory)
    server = start_supervised!({Memory, name: :memory_test, history: ctx.history, path: ctx.path})
    assert {:ok, %{total: 25}} = Memory.search("needle", server: server, sync: false)
  end

  test "results agree with an independent full scan for ordinary terms", ctx do
    entries =
      for n <- 1..120, do: if(rem(n, 7) == 0, do: "red balloon #{n}", else: "blue boat #{n}")

    save(ctx, entries)
    expected = Enum.count(entries, &Enum.member?(String.split(&1), "balloon"))
    assert {:ok, %{total: ^expected}} = search(ctx, "balloon")
  end

  test "default index follows History when the configured archive changes", ctx do
    previous = Application.get_env(:tiny_axe, :state_dir)
    on_exit(fn -> Application.put_env(:tiny_axe, :state_dir, previous) end)
    first = Path.join(ctx.tmp_dir, "first")
    second = Path.join(ctx.tmp_dir, "second")
    for root <- [first, second], do: File.mkdir_p!(Path.join(root, "history"))
    Application.put_env(:tiny_axe, :state_dir, first)
    save(%{history: History.dir()}, ["first archive"])

    server =
      start_supervised!(Supervisor.child_spec({Memory, name: :moving_memory}, id: :moving_memory))

    opts = [server: server, sync: false]
    assert {:ok, %{total: 1}} = Memory.search("first", opts)
    Memory.review(true, opts)
    {:ok, old_job} = Memory.next_review(opts)
    Application.put_env(:tiny_axe, :state_dir, second)
    save(%{history: History.dir()}, ["second archive"])
    assert {:ok, %{total: 0}} = Memory.search("first", opts)
    assert {:ok, %{total: 1}} = Memory.search("second", opts)
    assert {:ok, %{review: %{enabled: false}}} = Memory.status(opts)

    assert {:error, :stale_source} =
             Memory.save_review(old_job, {:ok, %{note: "old note", quote: "first archive"}}, opts)

    Application.put_env(:tiny_axe, :state_dir, first)
    assert {:ok, %{total: 1}} = Memory.search("first", opts)
    assert {:ok, %{review: %{enabled: true}}} = Memory.status(opts)
    blocked = Path.join(ctx.tmp_dir, "not-a-directory")
    File.write!(blocked, "occupied")
    Application.put_env(:tiny_axe, :state_dir, blocked)
    assert {:error, _} = Memory.search("first", opts)
    Application.put_env(:tiny_axe, :state_dir, first)
    assert {:ok, %{total: 1}} = Memory.search("first", opts)
  end
end
