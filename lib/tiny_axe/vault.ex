defmodule TinyAxe.Vault do
  @moduledoc """
  The know-how vault's writer (`docs/vault-format.md`): task journals into
  linked Markdown notes, for Obsidian to read and `TinyAxe.Sync` to send to
  the user's page of tiny-axe's website.

  One process, so writes are serial within tiny-axe; a lock file
  (`.tiny-axe/lock`) keeps two tiny-axe instances from interleaving. At
  start it backfills from the journals still on disk, and each task that
  acts is folded in as it goes (`task_progress/1`, after each journaled
  call, a few times a second at most) and once more as it closes
  (`task_closed/1`, from the gate). Both run in this
  process, never in the caller's: a vault that can't be written is logged
  and nothing else notices.

  What the notes add up to is kept in `.tiny-axe/ingested.json`
  (`TinyAxe.Vault.Ingest`): the journal lines already in, and every note's
  counts, dates and provenance. Notes are rendered from it, so a task whose
  journal was pruned keeps its share, and running again adds nothing. Every
  file is written to a temporary name beside it and renamed into place, and
  the state is written last: a run cut short is redone in full next time.

  `config :tiny_axe, :vault, dir: ..., enabled: ...`: the folder
  (`$XDG_DATA_HOME/tiny-axe/vault` by default), and whether the backfill
  and `task_closed/1` run (by default only when the TUI runs, so tests and
  `mix run` leave the real vault alone).
  """

  use GenServer

  require Logger

  alias TinyAxe.Vault.{Format, Ingest, Notes}

  @state ".tiny-axe/ingested.json"
  @manifest ".tiny-axe/vault.json"
  @lock ".tiny-axe/lock"
  # A running task's new calls are folded in at most this often.
  @progress_ms 300
  # A lock older than this was left by a writer that died.
  @stale_lock_s 120
  @folders ~w(Sites Pages Controls Paths Tools Tasks Workflows .tiny-axe)

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "The vault folder."
  @spec dir() :: String.t()
  def dir do
    config()[:dir] ||
      Path.join(
        System.get_env("XDG_DATA_HOME") || Path.expand("~/.local/share"),
        "tiny-axe/vault"
      )
  end

  @doc "Whether the backfill at start and `task_closed/1` write the vault."
  @spec enabled?() :: boolean()
  def enabled?,
    do: Keyword.get(config(), :enabled, Application.get_env(:tiny_axe, :start_tui, false))

  defp config, do: Application.get_env(:tiny_axe, :vault, [])

  defp journals, do: TinyAxe.Ops.Journal.state_dir()

  @doc "Folds every journal on disk into `dir/0`. Waits for it."
  @spec backfill() :: {:ok, map()} | {:error, term()}
  def backfill, do: GenServer.call(__MODULE__, :backfill, :infinity)

  @doc "Folds a finished task into the vault, in the background."
  @spec task_closed(String.t()) :: :ok
  def task_closed(id) do
    if enabled?(), do: GenServer.cast(__MODULE__, {:task_closed, id}), else: :ok
  end

  @doc "Folds a running task's new calls into the vault soon, in the background."
  @spec task_progress(String.t()) :: :ok
  def task_progress(id) do
    if enabled?(), do: GenServer.cast(__MODULE__, {:task_progress, id}), else: :ok
  end

  @doc """
  Folds the journals in `journals_dir` (a state folder holding `tasks/`, or
  the tasks folder itself) into the vault at `vault_dir`. Options: `:only`,
  task ids to read (the rest are only checked for pruning);
  `:lock_timeout` (ms, default 10 s); `:on_write`, called with each path
  once it's in place (for tests).
  """
  @spec ingest(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def ingest(journals_dir, vault_dir, opts \\ []) do
    File.mkdir_p!(Path.join(vault_dir, ".tiny-axe"))

    locked(vault_dir, Keyword.get(opts, :lock_timeout, 10_000), fn ->
      with :ok <- check_manifest(vault_dir),
           {:ok, old} <- read_state(vault_dir) do
        clean(vault_dir)
        state = Ingest.run(old, Ingest.tasks_dir(journals_dir), opts[:only])
        on_write = Keyword.get(opts, :on_write, fn _ -> :ok end)
        notes = Notes.render(state)

        written =
          for {rel, text} <- notes, File.read(Path.join(vault_dir, rel)) != {:ok, text} do
            write(vault_dir, rel, text, on_write)
          end

        state_text = encode(state) <> "\n"
        changed? = written != [] or File.read(Path.join(vault_dir, @state)) != {:ok, state_text}

        if changed? or not File.exists?(Path.join(vault_dir, @manifest)) do
          write(vault_dir, @manifest, manifest(), on_write)
        end

        if changed?, do: write(vault_dir, @state, state_text, on_write)

        {:ok, %{notes: length(notes), written: length(written)}}
      end
    end)
  rescue
    e -> {:error, Exception.message(e)}
  end

  ## Server

  @impl true
  # The state: the running tasks with a fold already on its way.
  def init(:ok) do
    if enabled?(), do: {:ok, MapSet.new(), {:continue, :backfill}}, else: {:ok, MapSet.new()}
  end

  @impl true
  def handle_continue(:backfill, s) do
    run(fn -> ingest(journals(), dir()) end, "backfill")
    {:noreply, s}
  end

  @impl true
  def handle_call(:backfill, _from, s),
    do: {:reply, run(fn -> ingest(journals(), dir()) end, "backfill"), s}

  @impl true
  def handle_cast({:task_progress, id}, pending) do
    if id in pending do
      {:noreply, pending}
    else
      Process.send_after(self(), {:progress, id}, @progress_ms)
      {:noreply, MapSet.put(pending, id)}
    end
  end

  def handle_cast({:task_closed, id}, pending) do
    run(fn -> ingest(journals(), dir(), only: [id]) end, "task #{id}")
    {:noreply, MapSet.delete(pending, id)}
  end

  @impl true
  def handle_info({:progress, id}, pending) do
    # Closed in the meantime: that fold took everything.
    if id in pending, do: run(fn -> ingest(journals(), dir(), only: [id]) end, "task #{id}")
    {:noreply, MapSet.delete(pending, id)}
  end

  defp run(fun, what) do
    case fun.() do
      {:ok, result} = ok ->
        # New notes go on to the user's page of the site (TinyAxe.Sync).
        if is_map(result) and Map.get(result, :written, 0) > 0, do: TinyAxe.Sync.soon()
        ok

      {:error, reason} = error ->
        Logger.warning("tiny-axe vault: #{what} not written: #{inspect(reason)}")
        error
    end
  catch
    kind, reason ->
      Logger.warning("tiny-axe vault: #{what} failed: #{Exception.format(kind, reason)}")
      {:error, reason}
  end

  ## Files

  defp read_state(vault_dir) do
    case File.read(Path.join(vault_dir, @state)) do
      {:ok, raw} ->
        case JSON.decode(raw) do
          {:ok, %{"schema" => schema} = state} ->
            if schema == Ingest.schema(),
              do: {:ok, Map.merge(Ingest.empty(), state)},
              else: {:error, {:state_schema, schema}}

          _ ->
            {:error, :state_unreadable}
        end

      {:error, :enoent} ->
        {:ok, Ingest.empty()}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A vault some other version wrote is left alone.
  defp check_manifest(vault_dir) do
    with {:ok, raw} <- File.read(Path.join(vault_dir, @manifest)),
         {:ok, %{"schema" => schema}} <- JSON.decode(raw),
         false <- schema == Format.schema() do
      {:error, {:vault_schema, schema}}
    else
      _ -> :ok
    end
  end

  defp manifest do
    vsn = Application.spec(:tiny_axe, :vsn) || ~c"unknown"
    at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    """
    {
      "schema": #{JSON.encode!(Format.schema())},
      "templates": #{Format.templates()},
      "writer": #{JSON.encode!("tiny-axe #{vsn}")},
      "generated_at": #{JSON.encode!(at)}
    }
    """
  end

  # Written beside the file, then renamed over it: a reader sees the old
  # file or the new one, never part of one.
  defp write(vault_dir, rel, text, on_write) do
    path = Path.join(vault_dir, rel)
    dir = Path.dirname(path)
    File.mkdir_p!(dir)
    tmp = Path.join(dir, ".#{Path.basename(path)}.#{System.unique_integer([:positive])}.tmp")

    try do
      File.write!(tmp, text)
      File.rename!(tmp, path)
    after
      File.rm(tmp)
    end

    on_write.(rel)
    rel
  end

  # Temporary files a writer that died left behind.
  defp clean(vault_dir) do
    @folders
    |> Enum.flat_map(&Path.wildcard(Path.join([vault_dir, &1, ".*.tmp"]), match_dot: true))
    |> Enum.each(&File.rm/1)
  end

  defp locked(vault_dir, timeout, fun) do
    lock = Path.join(vault_dir, @lock)

    case acquire(lock, System.monotonic_time(:millisecond) + timeout) do
      :ok ->
        try do
          fun.()
        after
          File.rm(lock)
        end

      error ->
        error
    end
  end

  defp acquire(lock, deadline) do
    case File.open(lock, [:write, :exclusive]) do
      {:ok, io} ->
        IO.write(io, System.pid() <> "\n")
        File.close(io)

      {:error, :eexist} ->
        cond do
          stale?(lock) ->
            File.rm(lock)
            acquire(lock, deadline)

          System.monotonic_time(:millisecond) > deadline ->
            {:error, :locked}

          true ->
            Process.sleep(25)
            acquire(lock, deadline)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp stale?(lock) do
    case File.stat(lock, time: :posix) do
      {:ok, %{mtime: mtime}} -> System.os_time(:second) - mtime > @stale_lock_s
      _ -> false
    end
  end

  # JSON with keys sorted, so the same state is always the same bytes.
  defp encode(map) when is_map(map) do
    inner =
      map
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join(",", fn {k, v} -> JSON.encode!(k) <> ":" <> encode(v) end)

    "{" <> inner <> "}"
  end

  defp encode(list) when is_list(list), do: "[" <> Enum.map_join(list, ",", &encode/1) <> "]"
  defp encode(value), do: JSON.encode!(value)
end
