defmodule TinyAxe.Escalation do
  @moduledoc """
  When a request goes up to a bigger model, and whether it may.

  The ladder (`config :tiny_axe, :models, escalate: [...]`, e.g. Claude haiku,
  then Claude sonnet) is climbed only on evidence that the local model fell
  short: code that still fails its check, no attempt the verifier accepts, a
  plan that couldn't be made to work. Each rung starts the request afresh.

  A rung that runs off this machine (Claude, Codex) needs, first:

    * escalation on (`config :tiny_axe, :escalate`)
    * the user's say-so for this session: `:ask` makes the caller ask once
      (`{:ask_remote, ...}`, answered with `{:remote_answer, ref, boolean}`);
      `:allowed` and `:denied` are the answer already given
    * room in the subscription: Claude isn't used once either of its usage
      windows is at `:quota_stop` (90%) or more, so tiny-axe never uses up the
      user's own quota

  This process also keeps, from telemetry, how many model calls left the
  machine and Claude's latest usage windows, for the status bar.
  """

  use GenServer

  alias TinyAxe.Model

  @type mode :: :ask | :allowed | :denied
  @type notify :: (term() -> any())

  @handler "tiny-axe-escalation"

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "The models to try, in order, when the local model falls short."
  @spec ladder() :: [Model.choice()]
  def ladder do
    if Application.get_env(:tiny_axe, :escalate, true),
      do: List.wrap(Model.role(:escalate)),
      else: []
  end

  @doc """
  Climbs the ladder: for each rung that's allowed, `fun.(choice, acc)` tries
  the request with that model and returns `{:ok, result}`, `{:fell_short, acc}`
  or `{:error, reason, acc}`. Returns `{:ok, result, choice}` from the first
  rung that succeeds, or `{:none, acc}`.

  Events: `{:escalate, %{to: label, reason: why}}` before a rung,
  `{:escalate_skipped, %{to: label, reason: why}}` for one that isn't allowed,
  `{:escalate_failed, %{to: label, reason: term}}` for one that errored.
  """
  @spec climb(String.t(), mode(), notify(), acc, (Model.choice(), acc ->
                                                    {:ok, term()}
                                                    | {:fell_short, acc}
                                                    | {:error, term(), acc})) ::
          {:ok, term(), Model.choice()} | {:none, acc}
        when acc: term()
  def climb(why, mode, notify, acc, fun), do: climb(ladder(), why, mode, notify, acc, fun)

  defp climb([], _why, _mode, _notify, acc, _fun), do: {:none, acc}

  defp climb([choice | rest], why, mode, notify, acc, fun) do
    label = Model.label(choice)

    case permit(choice, why, mode, notify) do
      {:ok, mode} ->
        notify.({:escalate, %{to: label, reason: why}})

        case fun.(choice, acc) do
          {:ok, result} ->
            {:ok, result, choice}

          {:fell_short, acc} ->
            climb(rest, "#{label} fell short too", mode, notify, acc, fun)

          {:error, reason, acc} ->
            notify.({:escalate_failed, %{to: label, reason: reason}})
            climb(rest, why, mode, notify, acc, fun)
        end

      {:skip, reason} ->
        notify.({:escalate_skipped, %{to: label, reason: reason}})
        climb(rest, why, mode, notify, acc, fun)

      {:stop, reason} ->
        notify.({:escalate_skipped, %{to: label, reason: reason}})
        {:none, acc}
    end
  end

  @doc """
  Whether `choice` may be used now: `{:ok, mode}` (with the user's answer, if
  they were asked), `{:skip, why}` for this rung only, or `{:stop, why}` for
  the whole ladder.
  """
  @spec permit(Model.choice(), String.t(), mode(), notify()) ::
          {:ok, mode()} | {:skip, String.t()} | {:stop, String.t()}
  def permit(choice, why, mode, notify) do
    cond do
      not Model.remote?(choice) -> {:ok, mode}
      full = over_quota(choice) -> {:skip, full}
      mode == :allowed -> {:ok, :allowed}
      mode == :ask -> ask(choice, why, notify)
      true -> {:stop, "sending requests off this machine is off for this session"}
    end
  end

  defp ask(choice, why, notify) do
    ref = make_ref()
    notify.({:ask_remote, %{to: Model.label(choice), reason: why, reply_to: self(), ref: ref}})

    receive do
      {:remote_answer, ^ref, true} -> {:ok, :allowed}
      {:remote_answer, ^ref, false} -> {:stop, "you said no to sending requests off this machine"}
    end
  end

  defp over_quota({backend, _model}) do
    stop = Application.get_env(:tiny_axe, :quota_stop, 0.9)
    quota = stats().quota[backend] || %{}

    Enum.find_value([five_hour: "5-hour", seven_day: "7-day"], fn {window, name} ->
      used = quota[window]

      if is_number(used) and used >= stop,
        do:
          "the #{backend} subscription is at #{round(used * 100)}% of its #{name} window " <>
            "(tiny-axe stops at #{round(stop * 100)}%, leaving the rest for you)"
    end)
  end

  @doc "Model calls that left the machine this run of tiny-axe, and the latest usage windows."
  @spec stats() :: %{remote_calls: non_neg_integer(), quota: map()}
  def stats do
    if Process.whereis(__MODULE__),
      do: GenServer.call(__MODULE__, :stats),
      else: %{remote_calls: 0, quota: %{}}
  end

  @doc "A reason a model call failed, in plain words."
  @spec explain(term()) :: String.t()
  def explain({:not_logged_in, :claude}), do: "not logged in: run `claude` once and log in"
  def explain({:not_logged_in, :codex}), do: "not logged in: run `codex login`"
  def explain({:not_installed, cli}), do: "`#{cli}` isn't installed"

  def explain({:not_subscription, cli, source}),
    do: "#{cli} would use #{source}, not the subscription, so tiny-axe won't use it"

  def explain({:usage_limit, cli, _}), do: "the #{cli} subscription's usage limit is reached"
  def explain(:timeout), do: "it took too long, so it was stopped"
  def explain(other), do: inspect(other)

  ## Server

  @impl true
  def init(:ok) do
    :telemetry.detach(@handler)

    :telemetry.attach_many(
      @handler,
      [[:tiny_axe, :model, :call], [:tiny_axe, :model, :quota]],
      &__MODULE__.handle_telemetry/4,
      nil
    )

    {:ok, %{remote_calls: 0, quota: %{}}}
  end

  @doc false
  def handle_telemetry([:tiny_axe, :model, :call], _measure, %{remote: true}, _),
    do: GenServer.cast(__MODULE__, :remote_call)

  def handle_telemetry([:tiny_axe, :model, :quota], _measure, %{backend: b, quota: q}, _),
    do: GenServer.cast(__MODULE__, {:quota, b, q})

  def handle_telemetry(_event, _measure, _meta, _config), do: :ok

  @impl true
  def handle_call(:stats, _from, state), do: {:reply, state, state}

  @impl true
  def handle_cast(:remote_call, state),
    do: {:noreply, %{state | remote_calls: state.remote_calls + 1}}

  def handle_cast({:quota, backend, quota}, state),
    do: {:noreply, put_in(state, [:quota, backend], quota)}
end
