defmodule TinyAxe.ReviewTest do
  @moduledoc """
  Reading chats for the site's session graph (`TinyAxe.Review`): Gemma's
  proposal (stubbed), Jev's judgement (stubbed), the record, and the push
  through `TinyAxe.Sync` to a fake site.
  """

  use ExUnit.Case, async: false

  alias TinyAxe.{Account, FakeSite, MCP, Review, Sync}

  @moduletag :tmp_dir
  @keyring Path.join(System.get_env("TMPDIR", "/tmp"), "tiny_axe_fake_keyring")

  # Signed in to the fake site, as graph_test does.
  defp sign_in(site) do
    File.mkdir_p!(@keyring)
    File.write!(Path.join(@keyring, "site"), site.key)
    File.mkdir_p!(Path.dirname(Account.path()))
    File.write!(Account.path(), JSON.encode!(%{username: "sam", site: site.url}))
  end

  setup %{tmp_dir: dir} do
    history = Path.join(dir, "history")
    File.mkdir_p!(history)
    %{history: history, path: Path.join(dir, "reviews.jsonl")}
  end

  defp chat(ctx, id, title, entries) do
    doc = %{
      version: 1,
      id: id,
      session: "20261012-090000-77ff",
      title: title,
      started: "2026-10-12T09:01:00Z",
      updated: "2026-10-12T09:05:00Z",
      folder: "~",
      entries: entries,
      context: %{messages: ["never read"]}
    }

    File.write!(Path.join(ctx.history, id <> ".json"), JSON.encode!(doc))
    {:ok, doc} = TinyAxe.History.doc(id, ctx.history)
    doc
  end

  # Gemma, as the test wants it to answer.
  defp gemma(proposal) do
    fn messages, opts ->
      send(self(), {:gemma, messages, opts})
      {:ok, %{"model" => "gemma-test", "message" => %{"content" => JSON.encode!(proposal)}}}
    end
  end

  # Jev: yes to what's in `yes`, no to the rest.
  defp jev(yes) do
    fn text, questions ->
      send(self(), {:jev, text, questions})

      answers =
        Map.new(questions, fn {k, _} -> {k, %{noul: if(k in yes, do: 0.9, else: 0.2)}} end)

      {:ok, answers, %{backend: "jev", model: "jev-test"}}
    end
  end

  test "Gemma proposes, Jev judges: weak concepts go, a rejected category becomes other", ctx do
    doc =
      chat(ctx, "20261012-090100-a1b2", "find a used Jazz bass", [
        %{kind: "user", text: "find me a used Fender Jazz bass under $900"},
        %{kind: "meta", text: "route → web"},
        %{kind: "assistant", text: "Reverb has three; the cheapest is $850 in Austin."}
      ])

    proposal = %{
      summary: "Looked for a used Jazz bass.",
      category: "shopping",
      concepts: ["Fender Jazz bass", "reverb", "Austin", "under $900"]
    }

    assert {:ok, review} =
             Review.review(doc,
               chat: gemma(proposal),
               decide: jev([:category_fits, :concept_0, :concept_1])
             )

    assert review.category == "shopping"
    assert review.concepts == ["fender jazz bass", "reverb"]
    assert review.summary == "Looked for a used Jazz bass."
    assert {review.model, review.decider} == {"gemma-test", "jev-test"}

    # What each model saw: the turns, never the meta lines or the context.
    assert_received {:gemma, [%{role: "system"}, %{role: "user", content: text}],
                     format: _, options: _}

    assert text =~ "Title: find a used Jazz bass"
    assert text =~ "User: find me a used Fender Jazz bass"
    refute text =~ "route →"
    refute text =~ "never read"
    # Jev reads the turns too (the title is Gemma's).
    assert_received {:jev, "User: find me" <> _, questions}
    assert map_size(questions) == 5

    # Jev says the category doesn't fit: other.
    assert {:ok, %{category: "other"}} =
             Review.review(doc, chat: gemma(proposal), decide: jev([:concept_0]))

    # No decider: Gemma's proposal stands.
    down = fn _, _ -> {:error, :unavailable, %{}} end

    assert {:ok, %{category: "shopping", concepts: [_, _, _, _], decider: nil}} =
             Review.review(doc, chat: gemma(proposal), decide: down)
  end

  test "a run reads what's new or grown, records it, and skips the rest", ctx do
    chat(ctx, "20261012-090100-a1b2", "a", [
      %{kind: "user", text: "hello"},
      %{kind: "assistant", text: "hi"}
    ])

    chat(ctx, "20261012-090200-b2c3", "b", [%{kind: "meta", text: "nothing said"}])
    proposal = %{summary: "Said hello.", category: "other", concepts: ["greetings"]}

    opts = [
      history: ctx.history,
      path: ctx.path,
      chat: gemma(proposal),
      decide: jev([:category_fits, :concept_0])
    ]

    assert Review.run(opts) == {:ok, %{reviewed: 1, skipped: 0, failed: 1}}

    assert %{
             "20261012-090100-a1b2" => %{
               "category" => "other",
               "concepts" => ["greetings"],
               "hash" => hash
             }
           } = Review.latest(ctx.path)

    # Unchanged: not read again. Grown: read again, and the newest wins.
    assert Review.run(opts) == {:ok, %{reviewed: 0, skipped: 1, failed: 1}}

    chat(ctx, "20261012-090100-a1b2", "a", [
      %{kind: "user", text: "hello"},
      %{kind: "assistant", text: "hi"},
      %{kind: "user", text: "bye"}
    ])

    assert {:ok, %{reviewed: 1}} = Review.run(opts)
    assert Review.latest(ctx.path)["20261012-090100-a1b2"]["hash"] != hash
    assert ctx.path |> File.read!() |> String.split("\n", trim: true) |> length() == 2
  end

  test "reviews go to the site once, through Sync", ctx do
    site = FakeSite.start()
    previous = Application.get_env(:tiny_axe, :site)
    Application.put_env(:tiny_axe, :site, Keyword.put(previous, :url, site.url))
    MCP.stop_server("graph")
    sign_in(site)
    File.rm(Sync.path())

    on_exit(fn ->
      MCP.stop_server("graph")
      Application.put_env(:tiny_axe, :site, previous)
      File.rm(Sync.path())
      File.rm(Account.path())
      File.rm(Path.join(@keyring, "site"))
    end)

    chat(ctx, "20261012-090100-a1b2", "a", [
      %{kind: "user", text: "hello"},
      %{kind: "assistant", text: "hi"}
    ])

    proposal = %{summary: "Said hello.", category: "other", concepts: ["greetings"]}

    {:ok, _} =
      Review.run(
        history: ctx.history,
        path: ctx.path,
        chat: gemma(proposal),
        decide: jev([:category_fits, :concept_0])
      )

    vault = Path.join(ctx.tmp_dir, "vault")
    File.mkdir_p!(vault)

    assert Sync.run(vault: vault, history: ctx.history, reviews: ctx.path) ==
             {:ok, %{notes: 0, chats: 1, reviews: 1}}

    assert_received {:site_call, "review_push", %{"review" => sent}}
    assert sent["chat_id"] == "20261012-090100-a1b2"
    assert sent["concepts"] == ["greetings"]
    refute Map.has_key?(sent, "hash")

    assert Sync.run(vault: vault, history: ctx.history, reviews: ctx.path) ==
             {:ok, %{notes: 0, chats: 0, reviews: 0}}
  end
end
