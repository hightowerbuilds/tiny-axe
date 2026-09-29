defmodule TinyAxe.Ops.Runner do
  @moduledoc """
  Runs approved file plans one at a time, journalling each step before and
  after it happens (`TinyAxe.Ops.Journal`), and handles recovery: rolling
  back, continuing or keeping an interrupted plan, and undoing the last one.

  Each job runs in a task under `TinyAxe.Ops.TaskSupervisor`, linked to this
  process:

    * if the task crashes, this process (trapping exits) survives, and the
      journal shows the plan as interrupted
    * if this process crashes, the link takes the task down with it, so no plan
      keeps running unsupervised; the supervisor restarts the Runner, and the
      interrupted plan is found in the journal like after any other crash

  Results go to the `reply_to` pid as `{:ops, id, event}`:

      {:progress, step, total}
      {:finished, done_count}
      {:stopped, step, error}          a step failed; earlier steps stand
      {:interrupted, reason}           the job crashed
      {:rolled_back, notes} | {:kept, notes} | {:undone, notes}
      {:continue_refused, problems}    remaining steps no longer make sense
      {:note, text}                    something the user should know about recovery
  """

  use GenServer

  alias TinyAxe.Ops
  alias TinyAxe.Ops.Journal

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Records and runs an approved plan. Returns its id."
  @spec run(String.t(), [map()], pid()) :: {:ok, String.t()} | {:error, :busy}
  def run(request, ops, reply_to \\ self()),
    do: GenServer.call(__MODULE__, {:run, request, ops, reply_to})

  @spec roll_back(String.t(), pid()) :: :ok | {:error, term()}
  def roll_back(id, reply_to \\ self()),
    do: GenServer.call(__MODULE__, {:job, :roll_back, id, reply_to})

  @spec continue(String.t(), pid()) :: :ok | {:error, term()}
  def continue(id, reply_to \\ self()),
    do: GenServer.call(__MODULE__, {:job, :continue, id, reply_to})

  @spec keep(String.t(), pid()) :: :ok | {:error, term()}
  def keep(id, reply_to \\ self()), do: GenServer.call(__MODULE__, {:job, :keep, id, reply_to})

  @doc "Undoes the newest plan that hasn't been undone."
  @spec undo_last(pid()) :: {:ok, String.t()} | {:error, term()}
  def undo_last(reply_to \\ self()) do
    case Journal.last_undoable() do
      nil -> {:error, :nothing_to_undo}
      plan -> with :ok <- undo_plan(plan.id, reply_to), do: {:ok, plan.id}
    end
  end

  @doc "Undoes a finished plan's steps."
  @spec undo_plan(String.t(), pid()) :: :ok | {:error, term()}
  def undo_plan(id, reply_to \\ self()),
    do: GenServer.call(__MODULE__, {:job, :undo, id, reply_to})

  ## Server

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    {:ok, %{job: nil}}
  end

  @impl true
  def handle_call(_request, _from, %{job: job} = state) when job != nil,
    do: {:reply, {:error, :busy}, state}

  def handle_call({:run, request, ops, reply_to}, _from, state) do
    {:ok, id} = Journal.create(request, ops)
    {:reply, {:ok, id}, start(state, id, reply_to, fn -> run_steps(id, 0) end)}
  end

  def handle_call({:job, kind, id, reply_to}, _from, state) do
    case Journal.load(id) do
      {:ok, plan} -> {:reply, :ok, start(state, id, reply_to, fn -> job(kind, plan) end)}
      error -> {:reply, error, state}
    end
  end

  defp start(state, id, reply_to, fun) do
    task =
      Task.Supervisor.async(TinyAxe.Ops.TaskSupervisor, fn ->
        Process.put(:reply_to, reply_to)

        fun.()
        |> List.wrap()
        |> Enum.each(&send(reply_to, {:ops, id, &1}))
      end)

    %{state | job: %{task: task, id: id, reply_to: reply_to}}
  end

  @impl true
  def handle_info({ref, _result}, %{job: %{task: %{ref: ref}}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | job: nil}}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{job: %{task: %{ref: ref}} = job} = state
      ) do
    send(job.reply_to, {:ops, job.id, {:interrupted, reason}})
    {:noreply, %{state | job: nil}}
  end

  # Exits from linked tasks arrive here too; the :DOWN above handles them.
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

  ## Jobs (these run in the task)

  defp run_steps(id, from) do
    {:ok, plan} = Journal.load(id)
    total = length(plan.steps)

    plan.steps
    |> Enum.with_index()
    |> Enum.drop(from)
    |> Enum.reduce_while(:ok, fn {op, i}, :ok ->
      Journal.event(id, %{t: "begin", step: i})
      hook(id, i)

      case Ops.step(op, Journal.backup_path(id, i)) do
        {:ok, undo} ->
          Journal.event(id, %{t: "done", step: i, undo: undo})
          send_progress(id, i, total)
          {:cont, :ok}

        {:error, message} ->
          Journal.event(id, %{t: "stopped", step: i, error: message})
          {:halt, {:stopped, i, Ops.describe(op) <> ": " <> message}}
      end
    end)
    |> case do
      :ok ->
        Journal.event(id, %{t: "finished"})
        {:finished, total - from}

      stopped ->
        stopped
    end
  end

  # Progress goes straight to whoever asked, from inside the task.
  defp send_progress(id, i, total) do
    case Process.get(:reply_to) do
      nil -> :ok
      pid -> send(pid, {:ops, id, {:progress, i + 1, total}})
    end
  end

  # Tests use this to stop a plan at an exact step.
  defp hook(id, i) do
    if hook = Application.get_env(:tiny_axe, :ops_step_hook), do: hook.(id, i)
  end

  defp job(:roll_back, plan) do
    {records, notes} = settle(plan)
    notes = notes ++ undo(records, plan)
    Journal.event(plan.id, %{t: "rolled_back", notes: notes})
    {:rolled_back, notes}
  end

  defp job(:keep, plan) do
    {records, notes} = settle(plan)
    # Whatever the unfinished step did is now part of the plan, so undo covers it.
    if plan.in_progress != nil and records != [],
      do: Journal.event(plan.id, %{t: "done", step: plan.in_progress, undo: records})

    Journal.event(plan.id, %{t: "kept", notes: notes})
    {:kept, notes}
  end

  defp job(:undo, plan) do
    notes = undo([], plan)
    Journal.event(plan.id, %{t: "undone", notes: notes})
    {:undone, notes}
  end

  defp job(:continue, plan) do
    {records, notes} = settle(plan)
    next = if plan.in_progress, do: plan.in_progress, else: map_size(plan.done)

    next =
      if plan.in_progress != nil and records != [] do
        Journal.event(plan.id, %{t: "done", step: plan.in_progress, undo: records})
        next + 1
      else
        next
      end

    remaining = Enum.drop(plan.steps, next)

    # The disk may have changed while tiny-axe was down; re-check before going on.
    case Ops.recheck(remaining) do
      :ok -> List.wrap(run_steps(plan.id, next)) ++ Enum.map(notes, &{:note, &1})
      {:error, problems} -> {:continue_refused, notes ++ problems}
    end
  end

  # How far the step in progress got, as undo records.
  defp settle(%{in_progress: nil}), do: {[], []}

  defp settle(%{in_progress: i} = plan) do
    op = Enum.at(plan.steps, i)

    {_state, records, notes} =
      Ops.settle(op, Journal.backup_path(plan.id, i), Journal.trash_dir(plan.id))

    {records, notes}
  end

  # Undoes the plan's finished steps (and `extra`), newest first.
  defp undo(extra, plan) do
    records =
      plan.done
      |> Enum.sort_by(&elem(&1, 0), :desc)
      |> Enum.flat_map(&elem(&1, 1))

    Enum.flat_map(extra ++ records, &Ops.undo_record(&1, Journal.trash_dir(plan.id)))
  end
end
