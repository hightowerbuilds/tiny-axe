defmodule TinyAxe.Tools.Journal do
  @moduledoc """
  A record of every tool call a task made, one JSON line each, in
  `<state>/tasks/<task>/calls.jsonl`: the tool, its arguments and a summary of
  its result (both redacted), what the gate decided, and how long it took.

  Browser decisions go beside it, in `decisions.jsonl`: one record each
  (`browser-decision/3`), with the redacted evidence it was shown, the
  policy, question and evidence versions, what answered, the answers, the
  disposition and its reason codes, and the call's result. Its `kind` says
  what it decided: `assess` (`TinyAxe.Tools.BrowserPolicy`), `verify` (an
  outcome, with the action and verification it belongs to) or `completion`
  (whether an answer claims what wasn't confirmed;
  `TinyAxe.Browser.Outcomes`). A call's entry lists its decisions' ids, the
  record of the action it took (`action`: its id, status and reason codes),
  and for `browser_verify`, the verification; the completion check is an
  entry of its own (`tiny-axe/completion`).

  The newest 50 tasks are kept, but a folder that belongs to an open task,
  or was written in the last hour, is never pruned: two tiny-axe instances
  share the state folder, and one mustn't delete the other's live task.
  Writing never raises: a folder removed underneath is made again, and any
  other failure is logged, so a journal problem can't stop a tool call.
  """

  require Logger

  @keep 50
  @recent_s 3600

  def dir(id), do: Path.join([TinyAxe.Ops.Journal.state_dir(), "tasks", id])

  @doc """
  Starts a task's record, pruning the oldest beyond the newest #{@keep},
  except open tasks' (`live`, ids) and any written in the last hour.
  """
  @spec start(String.t(), [String.t()]) :: :ok
  def start(id, live \\ []) do
    File.mkdir_p!(dir(id))
    prune([id | live])
  end

  @spec append(String.t(), map()) :: :ok
  def append(id, entry) do
    line = entry |> Map.put(:at, DateTime.utc_now() |> DateTime.to_iso8601()) |> JSON.encode!()
    write(id, "calls.jsonl", line <> "\n")
  end

  @spec append_decision(String.t(), map()) :: :ok
  def append_decision(id, record) do
    line = record |> Map.put(:at, DateTime.utc_now() |> DateTime.to_iso8601()) |> JSON.encode!()
    write(id, "decisions.jsonl", line <> "\n")
  end

  defp write(id, file, line) do
    path = Path.join(dir(id), file)

    with {:error, :enoent} <- File.write(path, line, [:append]),
         :ok <- File.mkdir_p(dir(id)) do
      File.write(path, line, [:append])
    end
    |> case do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("tiny-axe couldn't write the journal of task #{id}: #{inspect(reason)}")
        :ok
    end
  end

  @spec read(String.t()) :: [map()]
  def read(id), do: read_lines(id, "calls.jsonl")

  @spec decisions(String.t()) :: [map()]
  def decisions(id), do: read_lines(id, "decisions.jsonl")

  defp read_lines(id, file) do
    case File.read(Path.join(dir(id), file)) do
      {:ok, raw} -> raw |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
      {:error, _} -> []
    end
  end

  defp prune(live) do
    root = Path.join(TinyAxe.Ops.Journal.state_dir(), "tasks")

    case File.ls(root) do
      {:ok, ids} ->
        ids
        |> Enum.sort(:desc)
        |> Enum.drop(@keep)
        |> Enum.reject(&(&1 in live or recent?(Path.join(root, &1))))
        |> Enum.each(&File.rm_rf(Path.join(root, &1)))

      {:error, _} ->
        :ok
    end

    :ok
  end

  # Written in the last hour: the folder, or any file in it.
  defp recent?(path) do
    since = System.os_time(:second) - @recent_s
    files = [path | Path.wildcard(Path.join(path, "*"))]

    Enum.any?(files, fn f ->
      match?({:ok, %File.Stat{mtime: m}} when m > since, File.stat(f, time: :posix))
    end)
  end
end
