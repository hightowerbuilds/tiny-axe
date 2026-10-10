defmodule TinyAxe.Vault.Format do
  @moduledoc """
  The rules of the know-how vault's format (`docs/vault-format.md`): note
  names, URL templates, answer buckets, escaping, links and frontmatter.
  The TypeScript viewer (`graph/src/format.ts`) follows the same rules, and
  both are checked against `test/fixtures/vault/`.
  """

  @schema "tiny-axe-vault/1"
  @templates 1

  @plain_kinds ~w(site tool task)

  def schema, do: @schema
  def templates, do: @templates

  @common ~w(kind key title trust)
  @fields %{
    "site" => @common ++ ~w(seen looked first_seen last_seen),
    "page" => @common ++ ~w(site seen looked first_seen last_seen),
    "control" => @common ++ ~w(site page role label seen first_seen last_seen),
    "path" =>
      @common ++
        ~w(site subject tool answers class gate outcome reason_codes seen errors drivers models versions first_seen last_seen tasks decisions),
    "tool" => @common ++ ~w(server name seen first_seen last_seen),
    "task" => @common ++ ~w(driver started calls ran approved denied refused sites pruned)
  }

  @doc "A kind's frontmatter names, in the order they're written."
  @spec fields(String.t()) :: [String.t()]
  def fields(kind), do: Map.fetch!(@fields, kind)

  @doc "The kinds of note version 1 writes."
  def kinds, do: Map.keys(@fields)

  @doc "The folder a kind's notes live in."
  @spec folder(String.t()) :: String.t()
  def folder("site"), do: "Sites"
  def folder("page"), do: "Pages"
  def folder("control"), do: "Controls"
  def folder("path"), do: "Paths"
  def folder("tool"), do: "Tools"
  def folder("task"), do: "Tasks"
  def folder("workflow"), do: "Workflows"

  @doc """
  A note's file name, without `.md`. A site, tool or task whose key is
  already a safe name uses it as is; anything else gets a slug of its title
  and a hash of its key, so two notes with the same title still get
  different names.
  """
  @spec basename(String.t(), String.t(), String.t()) :: String.t()
  def basename(kind, key, title) do
    if kind in @plain_kinds and slug(key) == key,
      do: key,
      else: slug(title) <> " " <> hash8(kind, key)
  end

  @doc "Letters, digits, `.`, `_` and `-` only, at most 60 characters."
  @spec slug(String.t()) :: String.t()
  def slug(text) do
    text
    |> :unicode.characters_to_nfkd_binary()
    |> String.replace(~r/[^\x00-\x7F]/u, "")
    |> String.replace(~r/[^A-Za-z0-9._-]+/, "-")
    |> trim()
    |> String.slice(0, 60)
    |> trim()
    |> case do
      "" -> "note"
      slug -> slug
    end
  end

  defp trim(s), do: s |> String.replace(~r/^[-.]+/, "") |> String.replace(~r/[-.]+$/, "")

  @doc "The first 8 hex characters of SHA-256 of `kind <> \"\\n\" <> key`."
  @spec hash8(String.t(), String.t()) :: String.t()
  def hash8(kind, key) do
    :crypto.hash(:sha256, kind <> "\n" <> key) |> Base.encode16(case: :lower) |> binary_part(0, 8)
  end

  @doc "A site's key: the host, lowercased, without a leading `www.`; a port is kept."
  @spec site_key(String.t()) :: String.t() | nil
  def site_key(url) do
    case URI.parse(url) do
      %URI{host: host} = uri when is_binary(host) and host != "" ->
        host =
          host
          |> String.downcase()
          |> String.trim_trailing(".")
          |> String.replace_prefix("www.", "")

        if uri.port && uri.port != URI.default_port(uri.scheme),
          do: "#{host}:#{uri.port}",
          else: host

      _ ->
        nil
    end
  end

  @doc """
  A page's key: the site and the URL's path, with segments that identify
  one item replaced by `:id` and long word slugs by `:slug`.
  """
  @spec page_key(String.t()) :: String.t() | nil
  def page_key(url) do
    with site when is_binary(site) <- site_key(url) do
      site <> template(URI.parse(url).path || "/")
    end
  end

  @doc "A URL path with its identifying segments templated."
  @spec template(String.t()) :: String.t()
  def template(path) do
    case path |> String.split("/", trim: true) |> Enum.map(&segment/1) do
      [] -> "/"
      segments -> "/" <> Enum.join(segments, "/")
    end
  end

  @uuid ~r/^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/

  defp segment(s) do
    plain = String.replace(s, "-", "")

    cond do
      s =~ ~r/^\d+$/ ->
        ":id"

      s =~ @uuid ->
        ":id"

      String.length(s) >= 8 and plain =~ ~r/^[A-Za-z0-9]+$/ and plain =~ ~r/\d/ and
          plain =~ ~r/[A-Za-z]/ ->
        ":id"

      String.length(s) >= 20 and length(String.split(s, "-")) >= 4 ->
        ":slug"

      true ->
        s
    end
  end

  @doc "A decision's probability as a word: no, unlikely, likely, yes or unknown."
  @spec bucket(term()) :: String.t()
  def bucket(p) when is_number(p) and p >= 0 and p <= 1 do
    cond do
      p < 0.2 -> "no"
      p < 0.5 -> "unlikely"
      p < 0.8 -> "likely"
      true -> "yes"
    end
  end

  def bucket(_), do: "unknown"

  @doc "Text from a page or the user, made safe to put in a note's body."
  @spec escape(String.t()) :: String.t()
  def escape(text) do
    text
    |> String.replace(~r/\s*[\r\n]+\s*/, " ")
    |> String.replace(~r/[\\`*_\[\]<>#|]/, "\\\\\\0")
  end

  @doc "A wikilink to a note: `[[basename]]`, or `[[basename|alias]]` when the title differs."
  @spec link(String.t(), String.t()) :: String.t()
  def link(basename, title) do
    alias =
      title |> String.replace(~r/[\r\n]+/, " ") |> String.replace(["[", "]", "|"], &alias_char/1)

    if alias == basename, do: "[[#{basename}]]", else: "[[#{basename}|#{alias}]]"
  end

  defp alias_char("["), do: "("
  defp alias_char("]"), do: ")"
  defp alias_char("|"), do: "/"

  @doc "Frontmatter from `[{name, value}]`, in the order given."
  @spec frontmatter([{String.t(), term()}]) :: String.t()
  def frontmatter(pairs) do
    lines = Enum.map_join(pairs, "", fn {name, value} -> "#{name}: #{JSON.encode!(value)}\n" end)
    "---\n" <> lines <> "---\n"
  end

  @doc "A note's frontmatter, as `[{name, value}]` in file order, and its body."
  @spec parse(String.t()) :: {:ok, [{String.t(), term()}], String.t()} | {:error, String.t()}
  def parse("---\n" <> rest) do
    case String.split(rest, "\n---\n", parts: 2) do
      [head, body] ->
        head
        |> String.split("\n")
        |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
          with [name, raw] <- String.split(line, ": ", parts: 2),
               {:ok, value} <- JSON.decode(raw) do
            {:cont, {:ok, [{name, value} | acc]}}
          else
            _ -> {:halt, {:error, "bad frontmatter line: #{line}"}}
          end
        end)
        |> case do
          {:ok, pairs} -> {:ok, Enum.reverse(pairs), body}
          error -> error
        end

      _ ->
        {:error, "frontmatter isn't closed"}
    end
  end

  def parse(_), do: {:error, "no frontmatter"}

  @doc "The basenames a body links to, in order, skipping code."
  @spec links(String.t()) :: [String.t()]
  def links(body) do
    body
    |> String.replace(~r/^```.*?^```/ms, "")
    |> String.replace(~r/`[^`\n]*`/, "")
    |> then(&Regex.scan(~r/(?<!\\)\[\[([^\[\]|\n#]+)(?:#[^\[\]|\n]*)?(?:\|[^\[\]\n]*)?\]\]/, &1))
    |> Enum.map(fn [_, target] -> String.trim(target) end)
  end
end
