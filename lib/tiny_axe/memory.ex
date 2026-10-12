defmodule TinyAxe.Memory do
  @moduledoc """
  Local, rebuildable full-text chat index. Model calls never run in this server.
  Searches reconcile saved files, including changes from other app processes.
  """
  use GenServer
  alias TinyAxe.{History, Memory, Memory.Search, Memory.Store}

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  def path, do: Path.join(TinyAxe.Ops.Journal.state_dir(), "memory.sqlite3")

  def changed,
    do: if(Process.whereis(__MODULE__), do: GenServer.cast(__MODULE__, :changed), else: :ok)

  def search(query, opts \\ []), do: call({:search, query, opts}, opts)
  def status(opts \\ []), do: call(:status, opts)
  def rebuild(opts \\ []), do: call(:rebuild, opts)
  def related(query, opts \\ []), do: call({:related, query, opts}, opts)
  def review(enabled, opts \\ []) when is_boolean(enabled), do: call({:review, enabled}, opts)
  def retry_reviews(opts \\ []), do: call(:retry_reviews, opts)
  def next_review(opts \\ []), do: call(:next_review, opts)
  def save_review(job, result, opts \\ []), do: call({:save_review, job, result}, opts)

  defp call(request, opts) do
    if Keyword.get(opts, :sync, true), do: History.sync()
    GenServer.call(Keyword.get(opts, :server, __MODULE__), request, :infinity)
  end

  def read(hit, opts \\ []) do
    dir = Keyword.get(opts, :history, History.dir())

    with {:ok, doc, raw} <- History.source(hit.chat_id, dir),
         true <- Store.revision(raw) == hit.revision || {:error, :stale_source},
         %{} = entry <- Enum.at(doc["entries"], hit.position) do
      radius = Keyword.get(opts, :radius, 0) |> max(0) |> min(2)
      first = max(hit.position - radius, 0)

      entries =
        doc["entries"]
        |> Enum.with_index()
        |> Enum.slice(first, hit.position - first + radius + 1)

      {:ok, %{entry: entry, entries: entries, title: doc["title"], updated: doc["updated"]}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :missing_entry}
    end
  end

  @impl true
  def init(opts) do
    state = %{
      db: nil,
      path: Keyword.get(opts, :path, path()),
      history: Keyword.get(opts, :history, History.dir()),
      default_path: not Keyword.has_key?(opts, :path),
      default_history: not Keyword.has_key?(opts, :history),
      timer: nil
    }

    send(self(), :refresh)
    {:ok, state}
  end

  @impl true
  def handle_cast(:changed, s) do
    if s.timer, do: Process.cancel_timer(s.timer)
    {:noreply, %{s | timer: Process.send_after(self(), :refresh, 250)}}
  end

  @impl true
  def handle_info(:refresh, s) do
    if s.timer, do: Process.cancel_timer(s.timer)
    {_result, s} = perform(s, :status)
    {:noreply, %{s | timer: Process.send_after(self(), :refresh, 60_000)}}
  end

  @impl true
  def handle_call(request, _from, s) do
    {result, s} = perform(s, request)
    {:reply, result, s}
  end

  defp perform(s, request), do: perform_at(location(s), request)

  defp perform_at(s, request) do
    db = s.db || Store.open(s.path)
    s = %{s | db: db}

    try do
      coverage = Store.reconcile(db, s.history, request == :rebuild)

      result =
        case request do
          {:search, query, opts} ->
            with {:ok, result} <- Store.transaction(db, fn -> Search.run(db, query, opts) end),
                 do: {:ok, Map.put(result, :coverage, coverage)}

          {:related, query, opts} ->
            with {:ok, result} <- Memory.Notes.search(db, query, opts),
                 do: {:ok, Map.put(result, :coverage, coverage)}

          {:review, enabled} ->
            Memory.Notes.configure(db, enabled)
            {:ok, Map.put(coverage, :review, Memory.Notes.status(db))}

          :retry_reviews ->
            Memory.Notes.retry(db)
            {:ok, Map.put(coverage, :review, Memory.Notes.status(db))}

          :next_review ->
            job = if(Memory.Notes.enabled?(db), do: Memory.Notes.next(db))
            {:ok, if(job, do: Map.put(job, :archive, s.history))}

          {:save_review, job, result} ->
            if job.archive == s.history,
              do: Memory.Notes.save(db, job, result),
              else: {:error, :stale_source}

          _ ->
            {:ok, Map.put(coverage, :review, Memory.Notes.status(db))}
        end

      {result, s}
    rescue
      _ ->
        {{:error, "the local index could not be read or updated; check disk access and retry"}, s}
    end
  rescue
    _ -> {{:error, "the local index could not be opened; check disk access and FTS5 support"}, s}
  end

  # History resolves the configured state directory on every write. Follow
  # that same location after a runtime reconfiguration/application restart,
  # while keeping explicitly supplied fixture/archive paths fixed.
  defp location(s) do
    path = if s.default_path, do: path(), else: s.path
    history = if s.default_history, do: History.dir(), else: s.history

    if path == s.path and history == s.history do
      s
    else
      if s.db, do: Store.close(s.db)
      %{s | db: nil, path: path, history: history}
    end
  end

  @impl true
  def terminate(_, %{db: db}) when db != nil, do: Store.close(db)
  def terminate(_, _), do: :ok
end
