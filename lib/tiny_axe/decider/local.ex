defmodule TinyAxe.Decider.Local do
  @moduledoc """
  Jev-style decisions from a local Ollama model, using token logprobs.

  Each question becomes a one-token completion: the options are given
  single-token labels (`Yes`/`No`, `A`/`B`/..., or `0`/`1`/...), the model is
  asked to reply with a label only, and the probability of each label is read
  from `top_logprobs` on the first generated token, then renormalised.

  This yields a real distribution rather than a number the model made up,
  but it is not calibrated the way Jev is. Two extra fields help you judge it:

    * `:confidence` — `1 - normalised entropy` of the distribution
    * `:coverage` — how much of the raw probability mass fell on valid labels;
      a low value means the model wanted to say something else entirely

  Below `@min_coverage` there's no real evidence, so the answer is unknown
  (`noul`, `choice` or `score` is `nil`, and `unknown: true`) rather than a
  distribution renormalised from almost nothing, or a uniform guess.

  Questions run concurrently, one Ollama request each.
  """

  @behaviour TinyAxe.Decider

  alias TinyAxe.Ollama

  @letters ~w(A B C D E F G H I J K L M N O P)

  # Less of the probability on valid labels than this, and the answer is unknown.
  @min_coverage 0.05

  @impl true
  def max_options, do: length(@letters)

  @impl true
  def decide(state, questions) do
    state_text = render_state(state)

    questions
    |> Task.async_stream(
      fn {key, question} -> {key, ask(state_text, question)} end,
      timeout: :timer.seconds(60),
      ordered: false
    )
    |> Enum.reduce_while({:ok, %{}}, fn
      {:ok, {key, {:ok, answer}}}, {:ok, acc} -> {:cont, {:ok, Map.put(acc, key, answer)}}
      {:ok, {key, {:error, reason}}}, _ -> {:halt, {:error, {key, reason}}}
      {:exit, reason}, _ -> {:halt, {:error, {:exit, reason}}}
    end)
  end

  defp ask(state_text, question) do
    {labels, prompt} = build_prompt(state_text, question)

    messages = [
      %{role: "system", content: system_prompt()},
      %{role: "user", content: prompt}
    ]

    opts = [
      model:
        Application.get_env(:tiny_axe, :decider_model) || Application.get_env(:tiny_axe, :model),
      think: false,
      logprobs: true,
      top_logprobs: 20,
      options: [temperature: 0, num_predict: 1]
    ]

    with {:ok, body} <- Ollama.chat(messages, opts),
         {:ok, top} <- first_token_logprobs(body) do
      {:ok, build_answer(question, labels, label_distribution(top, Map.keys(labels)))}
    end
  end

  defp system_prompt do
    "You are a precise classifier. Read the state and the question, then reply " <>
      "with exactly one label from the allowed set and nothing else."
  end

  # Returns {label => answer_value, prompt}
  defp build_prompt(state_text, %{type: :noul, instructions: instructions}) do
    labels = %{"Yes" => true, "No" => false}

    prompt = """
    <state>
    #{state_text}
    </state>

    Question: #{instructions}
    Reply with Yes or No.
    """

    {labels, prompt}
  end

  defp build_prompt(state_text, %{type: :choice, instructions: instructions, options: options}) do
    keyed = options |> Enum.sort_by(fn {k, _} -> to_string(k) end) |> Enum.zip(@letters)
    labels = Map.new(keyed, fn {{key, _desc}, letter} -> {letter, key} end)
    listing = Enum.map_join(keyed, "\n", fn {{_key, desc}, letter} -> "#{letter}. #{desc}" end)

    prompt = """
    <state>
    #{state_text}
    </state>

    Question: #{instructions}
    Options:
    #{listing}

    Reply with the letter of the single best option.
    """

    {labels, prompt}
  end

  defp build_prompt(state_text, %{type: :score, instructions: instructions, criteria: criteria}) do
    indexed = Enum.with_index(criteria)
    labels = Map.new(indexed, fn {_desc, i} -> {Integer.to_string(i), i} end)
    listing = Enum.map_join(indexed, "\n", fn {desc, i} -> "#{i}: #{desc}" end)

    prompt = """
    <state>
    #{state_text}
    </state>

    Question: #{instructions}
    Scale:
    #{listing}

    Reply with the single number that fits best.
    """

    {labels, prompt}
  end

  defp first_token_logprobs(%{"logprobs" => [%{"top_logprobs" => top} | _]}), do: {:ok, top}
  defp first_token_logprobs(_), do: {:error, :no_logprobs}

  # Sums probability mass per label (tolerating case and whitespace variants
  # like " yes"), then renormalises. Returns {normalised, coverage}.
  @doc false
  def label_distribution(top_logprobs, labels) do
    by_norm = Map.new(labels, &{normalise(&1), &1})

    raw =
      Enum.reduce(top_logprobs, Map.new(labels, &{&1, 0.0}), fn %{
                                                                  "token" => token,
                                                                  "logprob" => lp
                                                                },
                                                                acc ->
        case Map.fetch(by_norm, normalise(token)) do
          {:ok, label} -> Map.update!(acc, label, &(&1 + :math.exp(lp)))
          :error -> acc
        end
      end)

    coverage = raw |> Map.values() |> Enum.sum()

    normalised =
      if coverage > 0 do
        Map.new(raw, fn {label, p} -> {label, p / coverage} end)
      else
        uniform = 1.0 / length(labels)
        Map.new(labels, &{&1, uniform})
      end

    {normalised, coverage}
  end

  defp normalise(token),
    do: token |> String.trim() |> String.trim_trailing(".") |> String.downcase()

  @doc false
  def build_answer(%{type: :noul}, _labels, {_dist, coverage}) when coverage < @min_coverage,
    do: %{noul: nil, coverage: round4(coverage), unknown: true}

  def build_answer(%{type: :choice}, _labels, {_dist, coverage}) when coverage < @min_coverage,
    do: %{
      choice: nil,
      probabilities: %{},
      confidence: 0.0,
      coverage: round4(coverage),
      unknown: true
    }

  def build_answer(%{type: :score}, _labels, {_dist, coverage}) when coverage < @min_coverage,
    do: %{
      score: nil,
      probabilities: %{},
      confidence: 0.0,
      coverage: round4(coverage),
      unknown: true
    }

  def build_answer(%{type: :noul}, _labels, {dist, coverage}) do
    %{noul: round4(dist["Yes"]), coverage: round4(coverage)}
  end

  def build_answer(%{type: :choice}, labels, {dist, coverage}) do
    probs = Map.new(dist, fn {label, p} -> {labels[label], round4(p)} end)
    {choice, _} = Enum.max_by(probs, &elem(&1, 1))

    %{
      choice: choice,
      probabilities: probs,
      confidence: confidence(probs),
      coverage: round4(coverage)
    }
  end

  def build_answer(%{type: :score}, labels, {dist, coverage}) do
    probs = Map.new(dist, fn {label, p} -> {labels[label], round4(p)} end)
    mean = Enum.reduce(probs, 0.0, fn {v, p}, acc -> acc + v * p end)

    %{
      score: round4(mean),
      probabilities: probs,
      confidence: confidence(probs),
      coverage: round4(coverage)
    }
  end

  defp confidence(probs) when map_size(probs) < 2, do: 1.0

  defp confidence(probs) do
    entropy =
      probs
      |> Map.values()
      |> Enum.reject(&(&1 <= 0))
      |> Enum.reduce(0.0, fn p, acc -> acc - p * :math.log(p) end)

    round4(1 - entropy / :math.log(map_size(probs)))
  end

  defp render_state(state) when is_binary(state), do: state

  defp render_state(state) when is_map(state) do
    Enum.map_join(state, "\n\n", fn {k, v} -> "## #{k}\n#{v}" end)
  end

  defp round4(x), do: Float.round(x * 1.0, 4)
end
