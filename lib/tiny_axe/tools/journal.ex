defmodule TinyAxe.Tools.Journal do
  @moduledoc """
  A record of every tool call a task made, one JSON line each, in
  `<state>/tasks/<task>/calls.jsonl`: the tool, its arguments and a summary of
  its result (both redacted), what the gate decided, and how long it took.
  The newest 50 tasks are kept.
  """

  @keep 50

  def dir(id), do: Path.join([TinyAxe.Ops.Journal.state_dir(), "tasks", id])

  @doc "Starts a task's record, pruning the oldest beyond the newest #{@keep}."
  @spec start(String.t()) :: :ok
  def start(id) do
    File.mkdir_p!(dir(id))
    prune()
  end

  @spec append(String.t(), map()) :: :ok
  def append(id, entry) do
    line = entry |> Map.put(:at, DateTime.utc_now() |> DateTime.to_iso8601()) |> JSON.encode!()
    File.write!(Path.join(dir(id), "calls.jsonl"), line <> "\n", [:append])
  end

  @spec read(String.t()) :: [map()]
  def read(id) do
    case File.read(Path.join(dir(id), "calls.jsonl")) do
      {:ok, raw} -> raw |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
      {:error, _} -> []
    end
  end

  defp prune do
    root = Path.join(TinyAxe.Ops.Journal.state_dir(), "tasks")

    case File.ls(root) do
      {:ok, ids} ->
        ids |> Enum.sort(:desc) |> Enum.drop(@keep) |> Enum.each(&File.rm_rf(Path.join(root, &1)))

      {:error, _} ->
        :ok
    end

    :ok
  end
end
