defmodule TinyAxe.VaultFormatTest do
  # The vault format's rules, and the fixture vault both the Elixir writer
  # and the TypeScript viewer are held to (docs/vault-format.md).
  use ExUnit.Case, async: true

  alias TinyAxe.Vault.Format

  @fixture Path.expand("../fixtures/vault", __DIR__)
  @vault Path.join(@fixture, "vault")

  defp json(name), do: @fixture |> Path.join(name) |> File.read!() |> JSON.decode!()

  defp notes do
    for kind <- Format.kinds(),
        file <- Path.wildcard(Path.join([@vault, Format.folder(kind), "*.md"])) do
      text = File.read!(file)
      {:ok, props, body} = Format.parse(text)
      %{file: file, text: text, props: props, map: Map.new(props), body: body}
    end
  end

  describe "rules shared with the viewer" do
    test "URL templates" do
      for %{"url" => url, "site" => site, "page" => page} <- json("templates.json") do
        assert Format.site_key(url) == site, url
        assert Format.page_key(url) == page, url
      end
    end

    test "note names" do
      for %{"kind" => kind, "key" => key, "title" => title, "basename" => name} <-
            json("names.json") do
        assert Format.basename(kind, key, title) == name, "#{kind} #{key}"
      end
    end
  end

  test "answer buckets" do
    assert Enum.map([0, 0.19, 0.2, 0.49, 0.5, 0.79, 0.8, 1], &Format.bucket/1) ==
             ~w(no no unlikely unlikely likely likely yes yes)

    assert Enum.map([nil, -0.1, 1.5, "0.9"], &Format.bucket/1) == List.duplicate("unknown", 4)
  end

  test "page and user text can't make a link or markup" do
    escaped = Format.escape("see [[Tasks]] <b>now</b>\n# not a heading | a_b `x`")

    assert escaped ==
             "see \\[\\[Tasks\\]\\] \\<b\\>now\\</b\\> \\# not a heading \\| a\\_b \\`x\\`"

    assert Format.links(escaped) == []

    assert Format.link("x 1234abcd", "a [[b]] | c") == "[[x 1234abcd|a ((b)) / c]]"
    assert Format.link("shop.example", "shop.example") == "[[shop.example]]"
  end

  test "links skip code and keep order" do
    body = "[[a|A]] `[[b]]` [[c#part]]\n```\n[[d]]\n```\n[[e]] \\[[f]]"
    assert Format.links(body) == ["a", "c", "e"]
  end

  test "frontmatter round-trips" do
    pairs = [
      {"kind", "path"},
      {"title", ~s(click "Add" → ran)},
      {"seen", 2},
      {"site", nil},
      {"tasks", ["a", "b"]}
    ]

    assert {:ok, ^pairs, "\n# x\n"} = Format.parse(Format.frontmatter(pairs) <> "\n# x\n")
    assert {:error, _} = Format.parse("# no frontmatter\n")
  end

  describe "the fixture vault" do
    test "has the manifest" do
      manifest = @vault |> Path.join(".tiny-axe/vault.json") |> File.read!() |> JSON.decode!()
      assert manifest["schema"] == Format.schema()
      assert manifest["templates"] == Format.templates()
    end

    test "every note is named, placed and laid out by the rules" do
      for n <- notes() do
        %{"kind" => kind, "key" => key, "title" => title} = n.map
        assert Path.basename(n.file, ".md") == Format.basename(kind, key, title), n.file
        assert n.file |> Path.dirname() |> Path.basename() == Format.folder(kind)
        assert Enum.map(n.props, &elem(&1, 0)) == Format.fields(kind), n.file
        assert n.map["trust"] == "observed"
        assert String.starts_with?(n.body, "\n# " <> Format.escape(title) <> "\n\n"), n.file
        assert String.ends_with?(n.text, "\n") and not String.ends_with?(n.text, "\n\n"), n.file
      end
    end

    test "reads to graph.json" do
      notes = notes()
      ids = MapSet.new(notes, &Path.basename(&1.file, ".md"))

      nodes =
        notes
        |> Enum.map(fn n ->
          %{
            "id" => Path.basename(n.file, ".md"),
            "kind" => n.map["kind"],
            "title" => n.map["title"],
            "folder" => n.file |> Path.dirname() |> Path.basename(),
            "trust" => n.map["trust"],
            "seen" => if(is_integer(n.map["seen"]), do: n.map["seen"])
          }
        end)
        |> Enum.sort_by(& &1["id"])

      links =
        for n <- notes,
            source = Path.basename(n.file, ".md"),
            target <- Format.links(n.body),
            target != source,
            uniq: true do
          %{"source" => source, "target" => target}
        end
        |> Enum.sort_by(&{&1["source"], &1["target"]})

      assert Enum.all?(links, &(&1["target"] in ids))

      assert %{
               "schema" => Format.schema(),
               "nodes" => nodes,
               "links" => links,
               "unresolved" => []
             } ==
               json("graph.json")
    end

    test "holds nothing it must never copy from the journals" do
      text = Enum.map_join(notes(), "\n", & &1.text)

      # Typed text, a search the agent made, query strings, fragments, page
      # context and the agent's own description of an element.
      for secret <- [
            "Great reporting",
            "elixir books",
            "ref=home",
            "tag=x",
            "#comments",
            "In stock",
            "posted publicly",
            "book link",
            "B0C1234567"
          ] do
        refute text =~ secret, "the vault contains #{inspect(secret)}"
      end
    end
  end
end
