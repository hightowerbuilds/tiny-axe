defmodule TinyAxe.Memory.Search do
  @moduledoc false
  alias TinyAxe.Memory.Store

  # Build FTS expressions from quoted data, never accept its operator language.
  def expression(query) do
    parts = Regex.scan(~r/"([^"]*)"|([^\s"]+)/u, query)

    cond do
      rem(length(String.split(query, "\"")) - 1, 2) != 0 ->
        {:error, "close the quoted phrase"}

      parts == [] ->
        {:error, "enter a word, phrase, or --literal text"}

      true ->
        terms = Enum.map(parts, fn p -> p |> Enum.drop(1) |> Enum.find(&(&1 != "")) end)

        if Enum.any?(terms, &(&1 == nil or not Regex.match?(~r/[\p{L}\p{N}]/u, &1))) do
          {:error, "use --literal for punctuation or symbols"}
        else
          {:ok,
           Enum.map_join(terms, " AND ", &("\"" <> String.replace(&1, "\"", "\"\"") <> "\""))}
        end
    end
  end

  def run(db, query, opts) do
    mode = Keyword.get(opts, :mode, :words)
    offset = max(Keyword.get(opts, :offset, 0), 0)
    limit = Keyword.get(opts, :limit, 10) |> max(1) |> min(100)
    exclude = Keyword.get(opts, :exclude, "")

    with :ok <- nonempty(query),
         {:ok, predicate, args, snippet, snippet_args} <- clause(mode, query) do
      from =
        " FROM entries e JOIN chats c ON c.id=e.chat_id " <>
          if(mode == :words, do: "JOIN entries_fts ON entries_fts.rowid=e.id ", else: "")

      where = " WHERE " <> predicate <> " AND c.id != ?"
      [[total]] = Store.query(db, "SELECT count(*)" <> from <> where, args ++ [exclude])

      order =
        if mode == :words,
          do: "bm25(entries_fts), c.updated DESC,e.id",
          else: "c.updated DESC,e.id"

      rows =
        Store.query(
          db,
          "SELECT c.id,c.revision,c.title,c.updated,e.position,e.kind," <>
            snippet <> from <> where <> " ORDER BY " <> order <> " LIMIT ? OFFSET ?",
          snippet_args ++ args ++ [exclude, limit, offset]
        )

      hits =
        for [id, revision, title, updated, position, kind, excerpt] <- rows,
            do: %{
              chat_id: id,
              revision: revision,
              title: title,
              updated: updated,
              position: position,
              kind: kind,
              excerpt: excerpt
            }

      {:ok, %{hits: hits, total: total, offset: offset, limit: limit, query: query, mode: mode}}
    end
  end

  defp clause(:words, query) do
    with {:ok, expression} <- expression(query),
         do:
           {:ok, "entries_fts MATCH ?", [expression], "snippet(entries_fts,0,'⟦','⟧',' … ',32)",
            []}
  end

  # instr is literal (including %, _, quotes and single-character queries).
  defp clause(:literal, query),
    do:
      {:ok, "instr(e.text,?) > 0", [query], "substr(e.text,max(1,instr(e.text,?)-80),240)",
       [query]}

  defp clause(_, _), do: {:error, "unknown search mode"}

  defp nonempty(query),
    do: if(String.trim(query) == "", do: {:error, "enter search text"}, else: :ok)
end
