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

  @spec decide(String.t() | map(), %{atom() => question()}) ::
          {:ok, %{atom() => answer()}} | {:error, term()}
  def decide(state, questions) do
    impl().decide(state, questions)
  end

  def impl, do: Application.get_env(:tiny_axe, :decider, TinyAxe.Decider.Local)
end
