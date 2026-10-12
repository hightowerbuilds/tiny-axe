defmodule TinyAxe.Memory.Notes do
  @moduledoc "Rebuildable navigation notes. Generated text is never source evidence."
  alias TinyAxe.Memory.{Model, Search, Store}
  @version "notes-v1"

  def version, do: @version

  def schema(db) do
    :ok =
      Exqlite.Sqlite3.execute(db, """
      CREATE TABLE IF NOT EXISTS memory_settings (key TEXT PRIMARY KEY,value TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS memory_notes (
        id INTEGER PRIMARY KEY,
        entry_id INTEGER NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
        start INTEGER NOT NULL, length INTEGER NOT NULL, hash TEXT NOT NULL,
        model TEXT NOT NULL DEFAULT '', version TEXT NOT NULL DEFAULT '',
        note TEXT NOT NULL DEFAULT '', quote TEXT NOT NULL DEFAULT '',
        attempts INTEGER NOT NULL DEFAULT 0, retry_at INTEGER NOT NULL DEFAULT 0,
        UNIQUE(entry_id,start)
      );
      CREATE VIRTUAL TABLE IF NOT EXISTS memory_notes_fts USING fts5(
        note,content='memory_notes',content_rowid='id',tokenize='unicode61 remove_diacritics 0'
      );
      CREATE TRIGGER IF NOT EXISTS memory_notes_insert AFTER INSERT ON memory_notes BEGIN
        INSERT INTO memory_notes_fts(rowid,note) VALUES(new.id,new.note);
      END;
      CREATE TRIGGER IF NOT EXISTS memory_notes_delete AFTER DELETE ON memory_notes BEGIN
        INSERT INTO memory_notes_fts(memory_notes_fts,rowid,note) VALUES('delete',old.id,old.note);
      END;
      CREATE TRIGGER IF NOT EXISTS memory_notes_update AFTER UPDATE OF note ON memory_notes BEGIN
        INSERT INTO memory_notes_fts(memory_notes_fts,rowid,note) VALUES('delete',old.id,old.note);
        INSERT INTO memory_notes_fts(rowid,note) VALUES(new.id,new.note);
      END;
      """)
  end

  def enabled?(db) do
    case Store.query(db, "SELECT value FROM memory_settings WHERE key='review'") do
      [[value]] -> value == "on"
      [] -> Keyword.get(Model.settings(), :review_enabled, false)
    end
  end

  def configure(db, enabled) when is_boolean(enabled) do
    Store.query(
      db,
      "INSERT INTO memory_settings VALUES('review',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
      [if(enabled, do: "on", else: "off")]
    )

    :ok
  end

  def retry(db) do
    Store.query(
      db,
      "UPDATE memory_notes SET attempts=0,retry_at=0 WHERE note='' OR model!=? OR version!=?",
      [Model.name(), @version]
    )

    :ok
  end

  def status(db) do
    [[total, ready, failed]] =
      Store.query(
        db,
        """
        SELECT count(*),coalesce(sum(note!='' AND model=? AND version=?),0),
          coalesce(sum(note='' AND attempts>0 AND model=? AND version=?),0) FROM memory_notes
        """,
        [Model.name(), @version, Model.name(), @version]
      )

    [[unprepared]] =
      Store.query(
        db,
        "SELECT count(*) FROM entries e WHERE text!='' AND NOT EXISTS(SELECT 1 FROM memory_notes n WHERE n.entry_id=e.id)"
      )

    %{
      enabled: enabled?(db),
      ready: ready,
      segments: total,
      failed: failed,
      pending: total - ready,
      unprepared_entries: unprepared,
      model: Model.name(),
      version: @version
    }
  end

  # Prepare one entry at a time: upgrading an existing database doesn't need
  # an eager copy of every transcript just to make exact search available.
  def next(db) do
    Store.transaction(db, fn ->
      prepare_entry(db)

      rows =
        Store.query(
          db,
          """
          SELECT n.id,n.start,n.length,n.hash,e.text,e.kind,c.id,e.position,c.revision
          FROM memory_notes n JOIN entries e ON e.id=n.entry_id JOIN chats c ON c.id=e.chat_id
          WHERE (n.model!=? OR n.version!=? OR (n.note='' AND n.attempts<3 AND n.retry_at<=?))
          ORDER BY n.attempts,n.id LIMIT 1
          """,
          [Model.name(), @version, System.system_time(:second)]
        )

      case rows do
        [[id, start, length, hash, text, kind, chat_id, position, revision]] ->
          %{
            id: id,
            start: start,
            length: length,
            hash: hash,
            text: String.slice(text, start, length),
            kind: kind,
            chat_id: chat_id,
            position: position,
            revision: revision,
            model: Model.name(),
            version: @version
          }

        [] ->
          nil
      end
    end)
  end

  defp prepare_entry(db) do
    case Store.query(db, """
         SELECT e.id,e.text FROM entries e JOIN chats c ON c.id=e.chat_id
         WHERE e.text!='' AND NOT EXISTS(SELECT 1 FROM memory_notes n WHERE n.entry_id=e.id)
         ORDER BY c.updated DESC,e.id LIMIT 1
         """) do
      [[id, text]] ->
        for {start, text} <- chunks(text) do
          Store.query(
            db,
            "INSERT INTO memory_notes(entry_id,start,length,hash) VALUES(?,?,?,?)",
            [id, start, String.length(text), Store.revision(text)]
          )
        end

      [] ->
        :ok
    end
  end

  # Grapheme offsets keep Unicode intact; every byte is covered, including
  # long middles and tool output. Small slices leave room for the schema.
  def chunks(text) do
    {chunks, chars, _bytes, start, count} =
      Enum.reduce(String.graphemes(text), {[], [], 0, 0, 0}, fn char,
                                                                {chunks, chars, bytes, start,
                                                                 count} ->
        if bytes + byte_size(char) > 1100 and count > 0 do
          {[{start, chars |> Enum.reverse() |> Enum.join()} | chunks], [char], byte_size(char),
           start + count, 1}
        else
          {chunks, [char | chars], bytes + byte_size(char), start, count + 1}
        end
      end)

    chunks =
      if count > 0, do: [{start, chars |> Enum.reverse() |> Enum.join()} | chunks], else: chunks

    Enum.reverse(chunks)
  end

  def save(db, job, result) do
    Store.transaction(db, fn ->
      case Store.query(
             db,
             """
             SELECT e.text,e.kind,n.start,n.length,n.hash FROM memory_notes n JOIN entries e ON e.id=n.entry_id
             WHERE n.id=? AND e.chat_id=? AND e.position=?
             """,
             [job.id, job.chat_id, job.position]
           ) do
        [[text, kind, start, length, hash]]
        when kind == job.kind and hash == job.hash and start == job.start and length == job.length ->
          if Store.revision(String.slice(text, start, length)) == job.hash and
               job.model == Model.name() and job.version == @version do
            case result do
              {:ok, %{note: note, quote: quote}} ->
                if valid?(String.slice(text, start, length), note, quote) do
                  Store.query(
                    db,
                    "UPDATE memory_notes SET note=?,quote=?,model=?,version=?,attempts=0,retry_at=0 WHERE id=?",
                    [note, quote, job.model, job.version, job.id]
                  )

                  :ok
                else
                  failed(db, job)
                end

              _ ->
                failed(db, job)
            end
          else
            {:error, :stale_source}
          end

        _ ->
          {:error, :stale_source}
      end
    end)
  end

  def valid?(text, note, quote),
    do:
      is_binary(note) and byte_size(note) in 1..900 and is_binary(quote) and
        byte_size(quote) in 1..200 and String.trim(quote) != "" and String.contains?(text, quote)

  defp failed(db, job) do
    Store.query(
      db,
      """
      UPDATE memory_notes SET note='',quote='',attempts=CASE WHEN model=? AND version=? THEN attempts+1 ELSE 1 END,
        model=?,version=?,retry_at=? WHERE id=?
      """,
      [job.model, job.version, job.model, job.version, System.system_time(:second) + 600, job.id]
    )

    {:error, :review_failed}
  end

  def search(db, query, opts) do
    with {:ok, expression} <- Search.expression(query) do
      rows =
        Store.query(
          db,
          """
          SELECT c.id,c.revision,c.title,c.updated,e.position,e.kind,n.note,n.quote,n.start,e.text
          FROM memory_notes_fts JOIN memory_notes n ON n.id=memory_notes_fts.rowid
          JOIN entries e ON e.id=n.entry_id JOIN chats c ON c.id=e.chat_id
          WHERE memory_notes_fts MATCH ? AND n.model=? AND n.version=? AND c.id!=?
          ORDER BY bm25(memory_notes_fts),c.updated DESC,n.id LIMIT ?
          """,
          [
            expression,
            Model.name(),
            @version,
            Keyword.get(opts, :exclude, ""),
            Keyword.get(opts, :limit, 8) |> max(1) |> min(100)
          ]
        )

      hits =
        for [id, revision, title, updated, position, kind, note, quote, start, text] <- rows do
          # Position the answer at the checked original quote, never at a
          # generated description that could itself be mistaken for evidence.
          tail = String.slice(text, start..-1//1)
          {at, _} = :binary.match(tail, quote)
          prefix = binary_part(tail, 0, at)
          # Reserve at most 120 bytes before the quote, so even a 200-byte
          # quote fits intact within Recall's 400-byte evidence budget.
          {leading, _bytes} =
            prefix
            |> String.graphemes()
            |> Enum.reverse()
            |> Enum.reduce_while({0, 0}, fn char, {count, bytes} ->
              if bytes + byte_size(char) <= 120,
                do: {:cont, {count + 1, bytes + byte_size(char)}},
                else: {:halt, {count, bytes}}
            end)

          source_start = start + String.length(prefix) - leading

          %{
            chat_id: id,
            revision: revision,
            title: title,
            updated: updated,
            position: position,
            kind: kind,
            excerpt: quote,
            generated_note: note,
            source_start: source_start
          }
        end

      {:ok, %{hits: hits}}
    end
  end
end
