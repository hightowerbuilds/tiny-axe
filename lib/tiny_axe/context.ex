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
end
