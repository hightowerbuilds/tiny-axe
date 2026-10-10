defmodule TinyAxe.Browser.Examples.Store do
  @moduledoc """
  Where `TinyAxe.Browser.Examples` keeps its files, apart from routine logs
  (the task journals): `<state>/browser_examples/`, readable only by the
  user (folders 0700, files 0600).

    * `sets/<n>.json` — every version of the example set, never rewritten:
      each change (a promotion, a deletion, a restore, an expiry, a
      rollback) writes the next version, so any version can be rolled back
      to
    * `active.json` — which version retrieval uses
    * `candidates/<id>.json` — lessons captured but not yet validated;
      never retrieved
    * `evidence/<id>.json` — the redacted evidence behind a candidate, kept
      for the retention period (`:browser_examples_retention_days`, 30)
    * `trash/` — deleted examples and consumed candidates, restorable for
      the same retention period

  Nothing here is ever deleted outright: what expires (evidence,
  candidates, `trash/`, and set versions beyond the newest
  `:browser_examples_versions_kept`, 20) goes to the system Trash
  (`TinyAxe.Ops.discard/1`), and deleting an example moves it to `trash/`.

  Every file is written to a temporary name and renamed into place; a set
  version is created only if no file has that number yet (another writer
  got there first: the next number is tried), and changes within this
  node are serialised (`transaction/1`).

  With no `active.json` yet, the shipped curated set
  (`priv/browser/examples.json`) is version 1 and active. If `active.json`
  exists but can't be read, or names a version that's gone, retrieval has
  no examples at all rather than guessing.
  """

  require Logger

  @set_schema "browser-example-set/1"

  def dir, do: Path.join(TinyAxe.Ops.Journal.state_dir(), "browser_examples")
  def path(part), do: Path.join(dir(), part)

  @doc "The curated set shipped with tiny-axe."
  def curated_file, do: Application.app_dir(:tiny_axe, "priv/browser/examples.json")

  @doc "The curated set, as stored (`version`, `examples`), or an empty set."
  def curated do
    with {:ok, raw} <- File.read(curated_file()),
         {:ok, %{"examples" => examples} = set} <- JSON.decode(raw) do
      %{
        "schema" => set["schema"] || @set_schema,
        "version" => set["version"] || 1,
        "change" => "curated set shipped with tiny-axe",
        "examples" => examples
      }
    else
      _ -> %{"schema" => @set_schema, "version" => 1, "change" => "none", "examples" => []}
    end
  end

  @doc "Every stored version number, oldest first (the curated one included once written)."
  def versions do
    case File.ls(path("sets")) do
      {:ok, files} ->
        files
        |> Enum.flat_map(fn f ->
          case Integer.parse(Path.basename(f, ".json")) do
            {n, ""} -> [n]
            _ -> []
          end
        end)
        |> Enum.sort()

      {:error, _} ->
        []
    end
  end

  @doc "One stored version, or the curated set as version 1 before anything is written."
  def set(version) do
    case read(path("sets/#{version}.json")) do
      {:ok, set} -> {:ok, set}
      :error -> if version == curated()["version"], do: {:ok, curated()}, else: :error
    end
  end

  @doc "The set retrieval uses: none at all if `active.json` exists but can't be read."
  def active do
    file = path("active.json")

    if File.exists?(file) do
      with {:ok, %{"version" => v}} when is_integer(v) <- read(file),
           {:ok, %{} = set} <- set(v) do
        set
      else
        _ ->
          Logger.warning("tiny-axe couldn't read #{file}: using no browser examples")
          %{"version" => nil, "change" => "active.json unreadable", "examples" => []}
      end
    else
      curated()
    end
  end

  @doc "Runs `fun` while holding this node's lock on the store (re-entrant)."
  def transaction(fun),
    do: :global.trans({{__MODULE__, :write}, self()}, fun, [node()], :infinity)

  @doc """
  Writes the next version with these examples and makes it active. The
  first write keeps the curated set as its own version first, so it can be
  rolled back to. A number already taken (by another writer) is never
  overwritten: the next one is tried.
  """
  def write_set(examples, change) do
    transaction(fn ->
      if versions() == [] do
        c = curated()
        create(c["version"], c)
      end

      parent = active()["version"]

      with {:ok, next} <-
             create_next(Enum.max(versions(), fn -> 0 end) + 1, examples, change, parent, 50),
           :ok <- write(path("active.json"), %{"version" => next}) do
        prune_versions(next)
        {:ok, next}
      end
    end)
  end

  defp create_next(_n, _examples, _change, _parent, 0), do: {:error, :no_free_version}

  defp create_next(n, examples, change, parent, tries) do
    set = %{
      "schema" => @set_schema,
      "version" => n,
      "parent" => parent,
      "change" => change,
      "at" => now(),
      "examples" => examples
    }

    case create(n, set) do
      :ok -> {:ok, n}
      {:error, :eexist} -> create_next(n + 1, examples, change, parent, tries - 1)
      error -> error
    end
  end

  @doc false
  # A set version only if nothing has that number yet: written to a
  # temporary file, then hard-linked into place (which fails if it exists:
  # `{:error, :eexist}`, and the next number is tried).
  def create(n, set) do
    target = path("sets/#{n}.json")
    tmp = temp(target)

    with :ok <- write_file(tmp, set) do
      result = File.ln(tmp, target)
      File.rm(tmp)
      result
    end
  end

  # Older versions beyond the newest N go to the system Trash (never the
  # active one); the curated version can always be rolled back to from the
  # shipped file.
  defp prune_versions(active) do
    keep = Application.get_env(:tiny_axe, :browser_examples_versions_kept, 20)
    all = versions()

    for v <- Enum.take(all, max(length(all) - keep, 0)), v != active do
      case TinyAxe.Ops.discard(path("sets/#{v}.json")) do
        :ok ->
          :ok

        {:error, why} ->
          Logger.warning("tiny-axe couldn't move set #{v} to the Trash: #{inspect(why)}")
      end
    end
  end

  @doc "Every version's number, change and size, oldest first."
  def history do
    versions = if versions() == [], do: [curated()["version"]], else: versions()
    active = active()["version"]

    for v <- versions, {:ok, set} <- [set(v)] do
      %{
        version: v,
        change: set["change"],
        at: set["at"],
        examples: length(set["examples"] || []),
        active: v == active
      }
    end
  end

  ## Candidates, evidence, trash

  def put_candidate(candidate), do: write(path("candidates/#{candidate["id"]}.json"), candidate)

  def candidate(id) do
    if safe_id?(id), do: read(path("candidates/#{id}.json")), else: :error
  end

  def candidates do
    case File.ls(path("candidates")) do
      {:ok, files} ->
        for f <- Enum.sort(files), {:ok, c} <- [read(path("candidates/#{f}"))], do: c

      _ ->
        []
    end
  end

  def put_evidence(id, evidence), do: write(path("evidence/#{id}.json"), evidence)

  def evidence(id) do
    if safe_id?(id), do: read(path("evidence/#{id}.json")), else: :error
  end

  @doc "Moves a candidate (consumed by a promotion) to trash/."
  def retire_candidate(id) do
    from = path("candidates/#{id}.json")

    if File.exists?(from) do
      :ok = ensure(path("trash"))
      File.rename(from, path("trash/candidate-#{id}-#{stamp()}.json"))
    else
      :ok
    end
  end

  @doc "Keeps a deleted example in trash/, restorable."
  def trash_example(example) do
    write(path("trash/example-#{example["id"]}-#{stamp()}.json"), example)
  end

  @doc "The newest deleted copy of an example, and where it is."
  def trashed(id) do
    if safe_id?(id) do
      case File.ls(path("trash")) do
        {:ok, files} ->
          files
          |> Enum.filter(&String.starts_with?(&1, "example-#{id}-"))
          |> Enum.sort(:desc)
          |> Enum.find_value(:error, fn f ->
            case read(path("trash/#{f}")) do
              {:ok, ex} -> {:ok, ex, path("trash/#{f}")}
              :error -> nil
            end
          end)

        _ ->
          :error
      end
    else
      :error
    end
  end

  @doc """
  Moves evidence and candidates older than `days` to the system Trash
  (never deleted outright). Returns how many went.
  """
  def expire_files(days, now_s \\ System.os_time(:second)) do
    cutoff = now_s - days * 86_400

    for sub <- ["evidence", "candidates", "trash"],
        {:ok, files} <- [File.ls(path(sub))],
        f <- files,
        file = path("#{sub}/#{f}"),
        match?({:ok, %File.Stat{mtime: m}} when m < cutoff, File.stat(file, time: :posix)),
        reduce: 0 do
      n ->
        case TinyAxe.Ops.discard(file) do
          :ok ->
            n + 1

          {:error, reason} ->
            Logger.warning("tiny-axe couldn't move #{file} to the Trash: #{inspect(reason)}")
            n
        end
    end
  end

  ## Files

  defp read(file) do
    with {:ok, raw} <- File.read(file),
         {:ok, %{} = data} <- JSON.decode(raw) do
      {:ok, data}
    else
      _ -> :error
    end
  end

  # Only this user can read what's written here; a file is written whole
  # under a temporary name, then renamed into place.
  defp write(file, data) do
    tmp = temp(file)

    with :ok <- write_file(tmp, data) do
      case File.rename(tmp, file) do
        :ok ->
          :ok

        error ->
          File.rm(tmp)
          error
      end
    end
  end

  defp write_file(file, data) do
    with :ok <- ensure(Path.dirname(file)),
         :ok <- File.write(file, ""),
         :ok <- File.chmod(file, 0o600) do
      File.write(file, JSON.encode!(data))
    end
  end

  defp temp(file), do: "#{file}.tmp-#{System.unique_integer([:positive])}"

  defp ensure(folder) do
    with :ok <- File.mkdir_p(folder) do
      Enum.each(Path.split(Path.relative_to(folder, Path.dirname(dir()))) |> prefixes(), fn p ->
        File.chmod(Path.join(Path.dirname(dir()), p), 0o700)
      end)

      :ok
    end
  end

  defp prefixes(parts) do
    parts
    |> Enum.scan(fn part, acc -> Path.join(acc, part) end)
  end

  defp safe_id?(id), do: is_binary(id) and id =~ ~r/\A[a-z0-9][a-z0-9_-]{0,80}\z/

  defp stamp, do: System.os_time(:millisecond) |> Integer.to_string()
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
