defmodule TinyAxe.Ops do
  @moduledoc """
  Public API for approved file plans: move, copy, mkdir, write, and system Trash.

  Responsibilities are separated by lifecycle:
    * `Plan` expands proposals and validates their simulated effects.
    * `Executor` mutates the filesystem and returns journal-compatible undo records.
    * `Recovery` settles interrupted steps and reverses completed ones.
    * `Paths` owns path resolution and mutation boundaries.
    * `Fingerprint` owns the hashes used by stale-write and undo checks.

  `Runner` and `Journal` own sequencing and durability. Callers keep using this
  module, so planners, the TUI, and saved plans share the same public contract.
  """

  alias TinyAxe.Ops.{Executor, Fingerprint, Paths, Plan, Recovery}

  @type op ::
          %{op: :move | :copy, from: String.t(), to: String.t()}
          | %{op: :mkdir, path: String.t()}
          | %{op: :trash, path: String.t(), folder: boolean(), items: non_neg_integer()}
          | %{op: :write, path: String.t(), about: String.t(), sources: [String.t()]}
          | %{op: :write, path: String.t(), content: String.t(), old_hash: String.t() | nil}

  @doc "The configured system Trash directory."
  @spec trash_dir() :: String.t()
  defdelegate trash_dir(), to: Executor

  @doc "The home-directory boundary for file operations, besides the current project."
  @spec root() :: String.t()
  defdelegate root(), to: Paths

  @doc "Resolves a path relative to the current location; ~ means the configured home."
  @spec resolve(String.t()) :: String.t()
  defdelegate resolve(path), to: Paths

  @doc "Whether a path is inside the home or project boundary and is not hidden."
  @spec changeable?(String.t()) :: boolean()
  defdelegate changeable?(path), to: Paths

  @doc "Whether a path is hidden relative to home, or the project when outside home."
  @spec hidden?(String.t()) :: boolean()
  defdelegate hidden?(path), to: Paths

  @doc "Expands and validates a model's raw plan without changing the filesystem."
  @spec expand([map()]) :: {:ok, [op()]} | {:error, [String.t()]}
  defdelegate expand(raw), to: Plan

  @doc "Re-checks concrete operations against the current filesystem."
  @spec recheck([op()]) :: :ok | {:error, [String.t()]}
  defdelegate recheck(ops), to: Plan

  @doc "One line describing an operation, for the plan and the transcript."
  @spec describe(op() | map()) :: String.t()
  def describe(%{op: :move, from: from, to: to}) do
    if Path.dirname(from) == Path.dirname(to),
      do: "rename #{show(from)} → #{Path.basename(to)}",
      else: "move #{show(from)} → #{show(to)}"
  end

  def describe(%{op: :copy, from: from, to: to}), do: "copy #{show(from)} → #{show(to)}"

  def describe(%{op: :trash, path: path, folder: true, items: n}),
    do: "trash folder #{show(path)} (#{n} #{if n == 1, do: "file", else: "files"})"

  def describe(%{op: :trash, path: path}), do: "trash #{show(path)}"

  def describe(%{op: :mkdir, path: path}), do: "make folder #{show(path)}"

  def describe(%{op: :write, path: path} = op) do
    verb = if Map.get(op, :old_hash) != nil, do: "rewrite", else: "write"
    "#{verb} #{show(path)}"
  end

  @doc "A path as the user would write it, with ~/ for paths under the configured home."
  @spec show(String.t()) :: String.t()
  defdelegate show(path), to: Paths

  @doc "Executes one approved operation and returns records for undo."
  @spec step(map(), String.t()) :: {:ok, [map()]} | {:error, String.t()}
  defdelegate step(op, backup), to: Executor

  @doc "Settles an interrupted operation, returning its state, undo records, and notes."
  @spec settle(map(), String.t(), String.t()) :: {:done | :not_done, [map()], [String.t()]}
  defdelegate settle(op, backup, trash), to: Recovery

  @doc "Reverses an undo record, preserving user changes and reporting failures as notes."
  @spec undo_record(map(), String.t()) :: [String.t()]
  defdelegate undo_record(record, trash), to: Recovery

  @doc "Hex SHA-256 of file contents."
  @spec hash(String.t()) :: String.t()
  defdelegate hash(content), to: Fingerprint

  @doc "Moves an internal artifact, such as old plan trash, into the system Trash."
  @spec discard(String.t()) :: :ok | {:error, term()}
  defdelegate discard(path), to: Executor
end
