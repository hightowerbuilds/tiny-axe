defmodule TinyAxe.Browser.TaskEval.Budget do
  @moduledoc """
  The decider during a browser task evaluation: it passes each call to the
  real one (Jev, the local model or the scripted decider) and counts it.
  Once the run's cap is reached, every further call fails with
  `:evaluation_budget_exhausted`, which tiny-axe treats like an outage (the
  stricter path), and the run reports the exhaustion.

  Each call is timed and kept (`log/0`), so the run can report decision
  latency, usage and the resolved model. Calls are counted across every
  process (the gate's, the agent's, the evaluator's).
  """

  @behaviour TinyAxe.Decider

  @key {__MODULE__, :run}

  @doc "Starts counting: `inner` answers, at most `max` calls."
  def setup(inner, max) when is_atom(inner) and is_integer(max) and max >= 0 do
    table = :ets.new(__MODULE__, [:public, :ordered_set])

    :persistent_term.put(@key, %{
      inner: inner,
      max: max,
      count: :atomics.new(1, []),
      exhausted: :atomics.new(1, []),
      table: table
    })

    :ok
  end

  def teardown do
    with %{table: table} <- :persistent_term.get(@key, nil) do
      :ets.delete(table)
      :persistent_term.erase(@key)
    end

    :ok
  end

  defp run, do: :persistent_term.get(@key)

  def inner, do: run().inner
  def max, do: run().max

  @doc "Calls passed to the inner decider so far."
  def used, do: :atomics.get(run().count, 1)

  @doc "Whether any call was refused for the cap."
  def exhausted?, do: :atomics.get(run().exhausted, 1) == 1

  @doc "Every call made, oldest first: `%{seq:, ms:, ok:, model:, usage:, questions:, at:}`."
  def log, do: run().table |> :ets.tab2list() |> Enum.map(&elem(&1, 1))

  @impl true
  def max_options do
    inner = inner()
    Code.ensure_loaded(inner)
    if function_exported?(inner, :max_options, 0), do: inner.max_options(), else: 16
  end

  @impl true
  def decide(state, questions) do
    case decide_meta(state, questions) do
      {:ok, answers, _meta} -> {:ok, answers}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def decide_meta(state, questions) do
    %{inner: inner, max: max, count: count, exhausted: exhausted, table: table} = run()
    seq = :atomics.add_get(count, 1, 1)

    if seq > max do
      :atomics.sub(count, 1, 1)
      :atomics.put(exhausted, 1, 1)
      {:error, :evaluation_budget_exhausted}
    else
      Code.ensure_loaded(inner)
      t0 = System.monotonic_time(:millisecond)

      result =
        if function_exported?(inner, :decide_meta, 2) do
          inner.decide_meta(state, questions)
        else
          case inner.decide(state, questions) do
            {:ok, answers} -> {:ok, answers, %{}}
            error -> error
          end
        end

      ms = System.monotonic_time(:millisecond) - t0
      meta = if match?({:ok, _, _}, result), do: elem(result, 2), else: %{}

      :ets.insert(
        table,
        {seq,
         %{
           seq: seq,
           ms: ms,
           ok: match?({:ok, _, _}, result),
           model: meta[:model],
           usage: meta[:usage],
           questions: questions |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort(),
           at: t0
         }}
      )

      case result do
        {:ok, answers, meta} -> {:ok, answers, Map.put_new(meta, :backend, backend(inner))}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # What decision records call the backend: "jev", not "budget".
  defp backend(inner), do: inner |> Module.split() |> List.last() |> Macro.underscore()
end
