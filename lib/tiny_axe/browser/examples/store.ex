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
    * `trash/` — deleted examples and consumed candidates, restorable

  Nothing here is ever deleted outright: what expires goes to the system
  Trash (`TinyAxe.Ops.discard/1`), and deleting an example moves it to
  `trash/`.

  With no set written yet, the shipped curated set
  (`priv/browser/examples.json`) is version 1 and active.
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

  @doc "The set retrieval uses."
  def active do
    with {:ok, %{"version" => v}} <- read(path("active.json")),
         {:ok, set} <- set(v) do
      set
    else
      _ -> curated()
    end
  end

  @doc """
  Writes the next version with these examples and makes it active. The
  first write keeps the curated set as its own version first, so it can be
  rolled back to.
  """
  def write_set(examples, change) do
    if versions() == [] do
      c = curated()
      :ok = write(path("sets/#{c["version"]}.json"), c)
    end

    next = Enum.max(versions(), fn -> 0 end) + 1
    parent = active()["version"]

    set = %{
      "schema" => @set_schema,
      "version" => next,
      "parent" => parent,
      "change" => change,
      "at" => now(),
      "examples" => examples
    }

    with :ok <- write(path("sets/#{next}.json"), set),
         :ok <- write(path("active.json"), %{"version" => next}) do
      {:ok, next}
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

    for sub <- ["evidence", "candidates"],
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

  # Only this user can read what's written here.
  defp write(file, data) do
    with :ok <- ensure(Path.dirname(file)),
         :ok <- File.write(file, ""),
         :ok <- File.chmod(file, 0o600) do
      File.write(file, JSON.encode!(data))
    end
  end

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
