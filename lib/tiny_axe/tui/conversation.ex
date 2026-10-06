defmodule TinyAxe.TUI.Conversation do
  @moduledoc """
  Builds model history and estimates context use from the current UI state.
  """

  alias TinyAxe.Context

  # What the next request carries: the summary, the kept turns, and whatever is
  # in flight (the prompt being answered and the answer so far).
  def context_tokens(state) do
    live =
      [state.pending_prompt, state.streaming]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&%{content: &1})

    Context.conversation_tokens(request_history(state) ++ live, state.ratio)
  end

  def request_history(%{summary: nil} = state), do: state.history

  def request_history(state) do
    [
      %{
        role: "system",
        content:
          "Summary of the earlier conversation (older turns were compacted):\n" <>
            state.summary.text
      }
      | state.history
    ]
  end

  def add_meta(state, text), do: %{state | transcript: state.transcript ++ [{:meta, text}]}
end
