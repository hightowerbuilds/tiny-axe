defmodule TinyAxe.Decider do
  @moduledoc """
  A Jev-style "System One" decision layer: given some state and a map of
  typed questions, return a typed, probability-weighted answer per question.

  Question shapes (mirroring Jev's API):

      %{type: :noul, instructions: "Is this command destructive?"}

      %{type: :choice, instructions: "What kind of task is this?",
        options: %{code: "Writing or changing code", text: "Prose or notes"}}

      %{type: :score, instructions: "How hard is this task?",
        criteria: ["Trivial", "Moderate", "Hard"]}

  Answer shapes:

      %{noul: 0.93}
      %{choice: :code, probabilities: %{code: 0.9, text: 0.1}, confidence: 0.8}
      %{score: 1.7, probabilities: %{0 => 0.05, 1 => 0.2, 2 => 0.75}, confidence: 0.6}

  The configured implementation (`config :tiny_axe, :decider`) is used by
  `decide/2`; swap `TinyAxe.Decider.Local` for `TinyAxe.Decider.Jev` once
  you have API access.
  """

  require Logger

  @type question ::
          %{type: :noul, instructions: String.t()}
          | %{
              type: :choice,
              instructions: String.t(),
              options: %{(atom() | String.t()) => String.t()}
            }
          | %{type: :score, instructions: String.t(), criteria: [String.t()]}

  @type answer :: %{optional(atom()) => term()}

  @callback decide(state :: String.t() | map(), questions :: %{atom() => question()}) ::
              {:ok, %{atom() => answer()}} | {:error, term()}

  @doc "The most options a `:choice` question can have with this implementation."
  @callback max_options() :: pos_integer()
  @optional_callbacks max_options: 0

  @spec max_options() :: pos_integer()
  def max_options do
    impl = impl()
    Code.ensure_loaded(impl)
    if function_exported?(impl, :max_options, 0), do: impl.max_options(), else: 16
  end

  @doc """
  The probability from a yes/no answer, or `nil` when there's no usable
  evidence: the call failed, the key is missing, or the answer is unknown (a
  local answer whose probability mostly fell outside the labels).

  Read scores through this (or `yes?/3`), never `answers.key.noul >= x`
  directly: in Elixir `nil >= 0.5` is `true`, so a missing score would pass.
  """
  @spec p({:ok, map()} | {:error, term()} | map(), atom()) :: float() | nil
  def p({:ok, answers}, key), do: p(answers, key)

  def p(answers, key) when is_map(answers) do
    case Map.get(answers, key) do
      %{noul: p} when is_number(p) -> p
      _ -> nil
    end
  end

  def p(_answers, _key), do: nil

  @doc """
  Below this, a review (of a plan, commands, a document or a summary) counts
  as doubtful: it's shown in yellow and sent back once. `config :tiny_axe,
  :review_threshold`.
  """
  @spec review_threshold() :: float()
  def review_threshold, do: Application.get_env(:tiny_axe, :review_threshold, 0.5)

  @doc "Whether a yes/no answer reaches `threshold`; unknown is never yes."
  @spec yes?({:ok, map()} | {:error, term()} | map(), atom(), float()) :: boolean()
  def yes?(answers, key, threshold) do
    case p(answers, key) do
      p when is_number(p) -> p >= threshold
      nil -> false
    end
  end

  @spec decide(String.t() | map(), %{atom() => question()}) ::
          {:ok, %{atom() => answer()}} | {:error, term()}
  def decide(state, questions) do
    t0 = System.monotonic_time()
    result = impl().decide(state, questions)
    ms = System.convert_time_unit(System.monotonic_time() - t0, :native, :millisecond)

    # Timed and counted for `mix tiny_axe.eval`.
    :telemetry.execute([:tiny_axe, :decider, :call], %{ms: ms, questions: map_size(questions)}, %{
      ok: match?({:ok, _}, result)
    })

    case result do
      {:ok, answers} = ok ->
        # Unknown (no usable evidence) and failed are both "unavailable" to the
        # user, but the log keeps them apart.
        unknown = for {key, %{unknown: true}} <- answers, do: key

        if unknown != [],
          do: Logger.info("decider had no usable evidence for #{inspect(unknown)}")

        ok

      {:error, reason} = error ->
        Logger.warning("decider failed for #{inspect(Map.keys(questions))}: #{inspect(reason)}")
        error
    end
  end

  def impl, do: Application.get_env(:tiny_axe, :decider, TinyAxe.Decider.Local)
end
