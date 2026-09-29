defmodule TinyAxe.Context do
  @moduledoc """
  How full the model's context window is, and when the conversation should be
  compacted.

  Ollama reports the real token count of each request (the whole prompt, even
  the cached part). Between requests, sizes are estimated from characters,
  using the tokens-per-character ratio measured on the last request, so the
  estimate follows whichever model and language are in use.
  """

  # Tokens per character before any request has been measured.
  @default_ratio 0.28
  # The system prompt, chat template and per-message framing.
  @overhead 400

  def default_ratio, do: @default_ratio

  @doc "The model's context window in tokens (`config :tiny_axe, :num_ctx`)."
  @spec window() :: pos_integer()
  def window, do: Application.get_env(:tiny_axe, :num_ctx, 8192)

  @spec estimate(String.t(), float()) :: non_neg_integer()
  def estimate(text, ratio), do: ceil(String.length(text) * ratio)

  @doc "Estimated tokens the conversation takes in the next request."
  @spec conversation_tokens([map()], float()) :: non_neg_integer()
  def conversation_tokens(messages, ratio) do
    @overhead + Enum.sum(Enum.map(messages, &(estimate(&1.content, ratio) + 4)))
  end

  @doc "Updates the ratio from a measured request, smoothing out one-off prompts."
  @spec calibrate(float(), map()) :: float()
  def calibrate(ratio, %{prompt_tokens: tokens, prompt_chars: chars}) when chars > 200,
    do: 0.5 * ratio + 0.5 * (tokens / chars)

  def calibrate(ratio, _usage), do: ratio

  @doc """
  Whether the conversation should be compacted: it has reached `:compact_at` of
  the window (half, by default), leaving room for web results, files and the answer.
  """
  @spec compact?(non_neg_integer()) :: boolean()
  def compact?(tokens), do: tokens >= Application.get_env(:tiny_axe, :compact_at, 0.5) * window()

  @spec fraction(non_neg_integer()) :: float()
  def fraction(tokens), do: min(tokens / window(), 1.0)

  @doc "A token count for display: 830, 4.7k, 12k."
  @spec short(non_neg_integer()) :: String.t()
  def short(n) when n < 1000, do: "#{n}"
  def short(n) when n < 10_000, do: "#{Float.round(n / 1000, 1)}k"
  def short(n), do: "#{round(n / 1000)}k"

  ## Fitting a request into the window

  # For budgeting, estimate on the high side: code packs more tokens per
  # character than prose.
  @budget_ratio 0.33
  @material_floor 1_500

  @doc """
  Fits a request's messages into the window, leaving `:answer_reserve` tokens
  (1,500 by default) for the answer. Cuts, in order, until it fits:

    1. the largest attached material (system messages after the first: web
       pages, files), a quarter at a time, down to #{@material_floor} characters each
    2. the oldest turns of history, keeping the newest two turns

  The system prompt and the final message are never cut. Returns the messages
  and `nil`, or a description of what was cut and the estimates before and after.
  """
  @spec fit([map()], keyword()) :: {[map()], nil | map()}
  def fit(messages, opts \\ []) do
    budget =
      Keyword.get(
        opts,
        :budget,
        window() - Application.get_env(:tiny_axe, :answer_reserve, 1_500)
      )

    before = conversation_tokens(messages, @budget_ratio)

    if before <= budget do
      {messages, nil}
    else
      {fitted, cuts} = messages |> shrink_material(budget, []) |> drop_old_turns(budget)

      {fitted,
       %{before: before, after: conversation_tokens(fitted, @budget_ratio), cut: Enum.uniq(cuts)}}
    end
  end

  defp over?(messages, budget), do: conversation_tokens(messages, @budget_ratio) > budget

  defp shrink_material(messages, budget, cuts) do
    candidates =
      messages
      |> Enum.with_index()
      |> Enum.filter(fn {m, i} ->
        # The margin covers the "cut to fit" note, so a cut message isn't cut forever.
        i > 0 and i < length(messages) - 1 and m.role == "system" and
          String.length(m.content) > @material_floor + 100
      end)

    case {over?(messages, budget),
          Enum.max_by(candidates, fn {m, _} -> String.length(m.content) end, fn -> nil end)} do
      {true, {m, i}} ->
        keep = max(div(String.length(m.content) * 3, 4), @material_floor)

        cut =
          String.slice(m.content, 0, keep) <>
            "\n(… the rest was cut to fit the model's context window)"

        shrink_material(List.replace_at(messages, i, %{m | content: cut}), budget, [
          "attached material" | cuts
        ])

      _ ->
        {messages, cuts}
    end
  end

  defp drop_old_turns({messages, cuts}, budget) do
    turns =
      Enum.filter(Enum.with_index(messages), fn {m, i} ->
        i > 0 and m.role in ["user", "assistant"]
      end)

    # Everything but the newest two turns (and the request itself) may go.
    droppable = Enum.drop(turns, -5)

    case {over?(messages, budget), droppable} do
      {true, [{_, i} | _]} ->
        drop_old_turns({List.delete_at(messages, i), ["older turns" | cuts]}, budget)

      _ ->
        {messages, cuts}
    end
  end
end
