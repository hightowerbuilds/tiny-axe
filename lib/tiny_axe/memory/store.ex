defmodule TinyAxe.Memory.Store do
  @moduledoc false
  alias Exqlite.Sqlite3, as: SQL
  alias TinyAxe.History

  def open(path) do
    File.mkdir_p!(Path.dirname(path))
    File.chmod!(Path.dirname(path), 0o700)

    case File.open(path, [:write, :exclusive]) do
      {:ok, file} ->
        File.close(file)

      {:error, :eexist} ->
        :ok

      {:error, reason} ->
        raise File.Error, reason: reason, action: "create memory index", path: path
    end

    File.chmod!(path, 0o600)
    {:ok, db} = SQL.open(path)

    try do
      :ok =
        SQL.execute(db, """
        PRAGMA busy_timeout=5000;
        PRAGMA journal_mode=WAL;
        PRAGMA foreign_keys=ON;
        CREATE TABLE IF NOT EXISTS chats (
          id TEXT PRIMARY KEY, revision TEXT NOT NULL, title TEXT NOT NULL,
          updated TEXT NOT NULL, local_only INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS entries (
          id INTEGER PRIMARY KEY, chat_id TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
          position INTEGER NOT NULL, kind TEXT NOT NULL, text TEXT NOT NULL,
          UNIQUE(chat_id, position)
        );
        CREATE VIRTUAL TABLE IF NOT EXISTS entries_fts USING fts5(
          text, content='entries', content_rowid='id', tokenize='unicode61 remove_diacritics 0'
        );
        CREATE TRIGGER IF NOT EXISTS entries_insert AFTER INSERT ON entries BEGIN
          INSERT INTO entries_fts(rowid,text) VALUES(new.id,new.text);
        END;
        CREATE TRIGGER IF NOT EXISTS entries_delete AFTER DELETE ON entries BEGIN
          INSERT INTO entries_fts(entries_fts,rowid,text) VALUES('delete',old.id,old.text);
        END;
        """)

      TinyAxe.Memory.Notes.schema(db)

      for suffix <- ["", "-wal", "-shm"],
          File.exists?(path <> suffix),
          do: File.chmod!(path <> suffix, 0o600)

      db
    rescue
      error ->
        SQL.close(db)
        reraise error, __STACKTRACE__
    end
  end

  def close(db), do: SQL.close(db)

  def query(db, sql, args \\ []) do
    {:ok, stmt} = SQL.prepare(db, sql)

    try do
      :ok = SQL.bind(stmt, args)
      {:ok, rows} = SQL.fetch_all(db, stmt)
      rows
    after
      SQL.release(db, stmt)
    end
  end

  def transaction(db, fun) do
    :ok = SQL.execute(db, "BEGIN IMMEDIATE")

    try do
      result = fun.()
      :ok = SQL.execute(db, "COMMIT")
      result
    catch
      kind, reason ->
        SQL.execute(db, "ROLLBACK")
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  def reconcile(db, dir, rebuild? \\ false) do
    names =
      case File.ls(dir) do
        {:ok, names} ->
          names

        {:error, :enoent} ->
          []

        {:error, reason} ->
          raise File.Error, reason: reason, action: "list chat history", path: dir
      end

    ids =
      for name <- names,
          Path.extname(name) == ".json",
          History.id?(Path.rootname(name)),
          do: Path.rootname(name)

    transaction(db, fn ->
      if rebuild?, do: query(db, "DELETE FROM chats")
      known = Map.new(query(db, "SELECT id,revision FROM chats"), fn [id, rev] -> {id, rev} end)

      for id <- Map.keys(known) -- ids, do: query(db, "DELETE FROM chats WHERE id=?", [id])

      failures =
        Enum.reduce(ids, [], fn id, errors ->
          result =
            with {:ok, raw} <- File.read(Path.join(dir, id <> ".json")) do
              revision = revision(raw)

              if known[id] == revision do
                :ok
              else
                with {:ok, doc} <- History.decode_document(id, raw) do
                  query(
                    db,
                    """
                    INSERT INTO chats VALUES(?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET
                    revision=excluded.revision,title=excluded.title,updated=excluded.updated,
                    local_only=excluded.local_only
                    """,
                    [
                      id,
                      revision,
                      doc["title"] || "Untitled",
                      doc["updated"] || "",
                      if(doc["local_only"] == true, do: 1, else: 0)
                    ]
                  )

                  # Keep unchanged entry IDs (and their generated notes) when a
                  # conversation grows. Changed/deleted entries cascade to notes.
                  previous =
                    Map.new(
                      query(db, "SELECT position,kind,text FROM entries WHERE chat_id=?", [id]),
                      fn [p, k, t] -> {p, {k, t}} end
                    )

                  query(db, "DELETE FROM entries WHERE chat_id=? AND position>=?", [
                    id,
                    length(doc["entries"])
                  ])

                  for {entry, position} <- Enum.with_index(doc["entries"]),
                      previous[position] != {entry["kind"], entry["text"]} do
                    query(db, "DELETE FROM entries WHERE chat_id=? AND position=?", [id, position])

                    query(db, "INSERT INTO entries(chat_id,position,kind,text) VALUES(?,?,?,?)", [
                      id,
                      position,
                      entry["kind"],
                      entry["text"]
                    ])
                  end

                  :ok
                end
              end
            end

          case result do
            :ok ->
              errors

            {:error, _} ->
              query(db, "DELETE FROM chats WHERE id=?", [id])
              [id | errors]
          end
        end)

      [[chats]] = query(db, "SELECT count(*) FROM chats")
      [[entries]] = query(db, "SELECT count(*) FROM entries")
      %{chats: chats, entries: entries, total: length(ids), failures: Enum.sort(failures)}
    end)
  end

  def revision(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
end
