defmodule TinyAxe.Compactor do
  @moduledoc """
  Compacts the older part of a conversation into a summary, so it keeps
  fitting in the model's context window.

  The newest turns stay word for word; everything before them, including any
  earlier summary, is condensed by the model. The Decider checks that the
  summary keeps what's needed to carry on, and a weak one is regenerated once.

  Events, streamed to `notify`:

      {:compact_delta, text}
      {:compacted, %{summary: text, turns: n, check: probability}}
      {:error, reason}
  """

  alias TinyAxe.{Decider, Ollama}

  @keep_turns 2

  @doc """
  Splits history into the turns to compact and the newest turns to keep.
  A turn is a user message and the answer to it.
  """
  @spec split([map()]) :: {[map()], [map()]}
  def split(history) do
    turns = Enum.chunk_every(history, 2)
    {old, recent} = Enum.split(turns, max(length(turns) - @keep_turns, 0))
    {List.flatten(old), List.flatten(recent)}
  end

  @spec run(String.t() | nil, [map()], (term() -> any())) :: :ok
  def run(previous, old, notify) do
    conversation = transcript(previous, old)

    first = summarise(conversation, notify, 0.3)
    first_check = check(conversation, first)

    {summary, check} =
      if first_check < 0.5 do
        second = summarise(conversation, notify, 0.7)
        second_check = check(conversation, second)
        if second_check > first_check, do: {second, second_check}, else: {first, first_check}
      else
        {first, first_check}
      end

    if summary == "",
      do: notify.({:error, :empty_summary}),
      else: notify.({:compacted, %{summary: summary, turns: div(length(old), 2), check: check}})

    :ok
  end

  defp transcript(previous, old) do
    earlier = if previous, do: "Summary of what came before:\n#{previous}\n\n", else: ""
    earlier <> Enum.map_join(old, "\n\n", &"#{&1.role}: #{&1.content}")
  end

  defp summarise(conversation, notify, temperature) do
    messages = [
      %{
        role: "system",
        content:
          "You compress conversations so they can continue without the original. " <>
            "Write concise Markdown."
      },
      %{
        role: "user",
        content: """
        #{conversation}

        ---

        Summarise the conversation above so it can continue without the original. \
        Fold in any earlier summary. Keep: what the user wants and prefers, decisions \
        made, facts established (names, versions, paths, numbers, commands), files and \
        code involved and their current state, and open questions. Use short bullet \
        points under a few headings. Keep code only when it's essential. At most 250 words.
        """
      }
    ]

    notify.({:compact_delta, :reset})

    case Ollama.stream_chat(messages, &notify.({:compact_delta, &1}),
           options: [temperature: temperature]
         ) do
      {:ok, text} -> String.trim(text)
      {:error, _} -> ""
    end
  end

  defp check(_conversation, ""), do: 0.0

  defp check(conversation, summary) do
    question = %{
      keeps: %{
        type: :noul,
        instructions:
          "Does this summary keep everything from the conversation that's needed to continue it?"
      }
    }

    case Decider.decide(%{conversation: conversation, summary: summary}, question) do
      {:ok, %{keeps: %{noul: p}}} -> p
      _ -> 0.5
    end
  end
end
