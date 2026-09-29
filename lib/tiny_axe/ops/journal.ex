defmodule TinyAxe.Ops.Journal do
  @moduledoc """
  The write-ahead journal for file plans. Every plan gets a directory under
  `state_dir/0` holding:

    * `journal.jsonl` — one JSON event per line, synced to disk as written:

          {"t":"plan", "id":…, "at":…, "request":…, "steps":[…]}
          {"t":"begin", "step":0}
          {"t":"done", "step":0, "undo":[…]}
          {"t":"stopped", "step":3, "error":…}      a step failed; earlier ones stand
          {"t":"finished"}
          {"t":"rolled_back" | "kept" | "undone", "notes":[…]}

    * `write-<n>` — the contents each `write` step will put in place, staged
      before the plan runs so a resumed plan has them
    * `backup-<n>` — the file a `write` step replaced
    * `trash/` — whatever undo or roll-back took away

  A plan whose journal has no closing event was interrupted: tiny-axe stopped
  partway through it. Plans are pruned to the newest 20 within 30 days, except
  interrupted ones, which are kept until the user deals with them. Pruning
  deletes a plan's journal and backups, but moves anything in its `trash/` to
  the system Trash.

  One process owns the files, so journal writes never interleave.
  """

  use GenServer

  @keep_plans 20
  @keep_days 30

  @type status :: :interrupted | :finished | :stopped | :kept | :rolled_back | :undone

  ## API

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Where plans are kept: `config :tiny_axe, :state_dir`, or `$XDG_STATE_HOME/tiny-axe`."
  @spec state_dir() :: String.t()
  def state_dir do
    Application.get_env(:tiny_axe, :state_dir) ||
      Path.join(System.get_env("XDG_STATE_HOME") || Path.expand("~/.local/state"), "tiny-axe")
  end

  @doc """
  Records a new plan and stages the contents of its `write` steps. Returns its id.
  """
  @spec create(String.t(), [map()]) :: {:ok, String.t()}
  def create(request, ops), do: GenServer.call(__MODULE__, {:create, request, ops})

  @doc "Appends an event to a plan's journal and syncs it to disk."
  @spec event(String.t(), map()) :: :ok
  def event(id, event), do: GenServer.call(__MODULE__, {:event, id, event})

  @doc "Reads a plan back: its steps, what's done, and its status."
  @spec load(String.t()) :: {:ok, map()} | {:error, term()}
  def load(id), do: read_plan(plan_dir(id))

  @doc "All plans, newest first."
  @spec list() :: [map()]
  def list do
    case File.ls(plans_dir()) do
      {:ok, ids} ->
        ids
        |> Enum.sort(:desc)
        |> Enum.flat_map(fn id ->
          case load(id) do
            {:ok, plan} -> [plan]
            {:error, _} -> []
          end
        end)

      {:error, _} ->
        []
    end
  end

  @spec interrupted() :: [map()]
  def interrupted, do: Enum.filter(list(), &(&1.status == :interrupted))

  @doc "The newest plan that changed something and hasn't been undone."
  @spec last_undoable() :: map() | nil
  def last_undoable do
    list()
    |> Enum.filter(&(&1.status in [:finished, :stopped, :kept]))
    |> Enum.find(&(map_size(&1.done) > 0))
  end

  def backup_path(id, step), do: Path.join(plan_dir(id), "backup-#{step}")
  def trash_dir(id), do: Path.join(plan_dir(id), "trash")

  ## Server

  @impl true
  def init(_opts) do
    File.mkdir_p!(plans_dir())
    prune()
    {:ok, %{}}
  end

  @impl true
  def handle_call({:create, request, ops}, _from, state) do
    id = new_id()
    dir = plan_dir(id)
    File.mkdir_p!(dir)

    steps =
      ops
      |> Enum.with_index()
      |> Enum.map(fn
        {%{op: :write} = op, i} ->
          # Staged and synced before the plan exists, so a resumed plan has it.
          file = Path.join(dir, "write-#{i}")
          sync_write(file, op.content)

          %{
            op: "write",
            path: op.path,
            old_hash: op[:old_hash],
            hash: TinyAxe.Ops.hash(op.content)
          }

        {op, _i} ->
          Map.update!(op, :op, &Atom.to_string/1)
      end)

    at = DateTime.utc_now() |> DateTime.to_iso8601()
    append(id, %{t: "plan", id: id, at: at, request: request, steps: steps})
    {:reply, {:ok, id}, state}
  end

  def handle_call({:event, id, event}, _from, state) do
    append(id, event)
    {:reply, :ok, state}
  end

  ## Files

  defp plans_dir, do: Path.join(state_dir(), "plans")
  defp plan_dir(id), do: Path.join(plans_dir(), id)

  # Sortable by time, unique within a millisecond.
  defp new_id do
    stamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d-%H%M%S")
    "#{stamp}-#{System.unique_integer([:positive, :monotonic])}"
  end

  defp append(id, event) do
    sync_write(Path.join(plan_dir(id), "journal.jsonl"), JSON.encode!(event) <> "\n", [:append])
  end

  defp sync_write(path, data, modes \\ []) do
    {:ok, io} = :file.open(path, [:write, :binary, :raw | modes])

    try do
      :ok = :file.write(io, data)
      :ok = :file.sync(io)
    after
      :file.close(io)
    end
  end

  defp read_plan(dir) do
    with {:ok, raw} <- File.read(Path.join(dir, "journal.jsonl")),
         [%{"t" => "plan"} = plan | events] <- decode_lines(raw) do
      id = plan["id"]

      steps =
        plan["steps"]
        |> Enum.with_index()
        |> Enum.map(fn {step, i} -> decode_step(step, Path.join(dir, "write-#{i}")) end)

      done = for %{"t" => "done", "step" => i, "undo" => undo} <- events, into: %{}, do: {i, undo}
      begun = for %{"t" => "begin", "step" => i} <- events, do: i

      closing =
        events
        |> Enum.map(& &1["t"])
        |> Enum.filter(&(&1 in ~w(finished stopped kept rolled_back undone)))
        |> List.last()

      {:ok,
       %{
         id: id,
         at: plan["at"],
         request: plan["request"],
         steps: steps,
         done: done,
         # The step that started but never finished, if tiny-axe stopped mid-step.
         in_progress: Enum.find(Enum.reverse(begun), &(not Map.has_key?(done, &1))),
         status: if(closing, do: String.to_existing_atom(closing), else: :interrupted),
         dir: dir
       }}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :unreadable}
    end
  end

  # A torn last line (the process died mid-write) is dropped: its event never happened.
  defp decode_lines(raw) do
    raw
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case JSON.decode(line) do
        {:ok, event} -> [event]
        {:error, _} -> []
      end
    end)
  end

  defp decode_step(%{"op" => "write"} = s, file) do
    %{
      op: :write,
      path: s["path"],
      old_hash: s["old_hash"],
      hash: s["hash"],
      content: File.read!(file)
    }
  end

  defp decode_step(%{"op" => "mkdir", "path" => path}, _), do: %{op: :mkdir, path: path}

  defp decode_step(%{"op" => "trash", "path" => path} = s, _),
    do: %{op: :trash, path: path, folder: s["folder"] == true, items: s["items"]}

  defp decode_step(%{"op" => op, "from" => from, "to" => to}, _) when op in ["move", "copy"],
    do: %{op: String.to_existing_atom(op), from: from, to: to}

  defp prune do
    cutoff = DateTime.add(DateTime.utc_now(), -@keep_days, :day) |> DateTime.to_iso8601()

    list()
    |> Enum.reject(&(&1.status == :interrupted))
    |> Enum.with_index()
    |> Enum.filter(fn {plan, i} -> i >= @keep_plans or plan.at < cutoff end)
    |> Enum.each(fn {plan, _} -> forget(plan) end)
  end

  # An old plan's journal and backups go. What undo set aside in its trash/
  # (versions tiny-axe wrote, copies it made) goes to the system Trash, so
  # nothing tiny-axe took away is ever deleted outright.
  defp forget(plan) do
    trash = Path.join(plan.dir, "trash")

    case File.ls(trash) do
      {:ok, entries} -> Enum.each(entries, &TinyAxe.Ops.discard(Path.join(trash, &1)))
      {:error, _} -> :ok
    end

    File.rm_rf(plan.dir)
  end
end
