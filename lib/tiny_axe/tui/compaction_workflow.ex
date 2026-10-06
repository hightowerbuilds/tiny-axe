defmodule TinyAxe.TUI.CompactionWorkflow do
  @moduledoc false

  alias TinyAxe.{Compactor, Context}
  alias TinyAxe.TUI.Run
  import TinyAxe.TUI.Conversation, only: [context_tokens: 1]

  # After an answer, compact once the conversation has reached the threshold.
  def maybe_start(%{run: nil} = state) do
    if Context.compact?(context_tokens(state)), do: start(state), else: state
  end

  def maybe_start(state), do: state

  # Runs like a request (in the run slot, so esc cancels it and the prompt waits).
  def start(state) do
    case Compactor.split(state.history) do
      {[], _recent} ->
        %{
          state
          | status: "nothing to compact yet: the newest two turns are always kept as they are"
        }

      {old, _recent} ->
        previous = state.summary && state.summary.text
        state = Run.start(state, &Compactor.run(previous, old, &1))
        turns = div(length(old), 2)
        %{state | compacting: "", status: "compacting #{turns} turns…"}
    end
  end

  # The marker goes just before the first turn that was kept.
  defp insert_marker(transcript, marker, recent) do
    kept = Enum.count(recent, &(&1.role == "user"))

    users =
      transcript
      |> Enum.with_index()
      |> Enum.filter(&match?({{:user, _}, _}, &1))
      |> Enum.map(&elem(&1, 1))

    case Enum.at(users, length(users) - kept) do
      nil -> transcript ++ [marker]
      at -> List.insert_at(transcript, at, marker)
    end
  end

  def event({:compact_delta, :reset}, state), do: %{state | compacting: ""}

  def event({:compact_delta, text}, state),
    do: %{state | compacting: (state.compacting || "") <> text}

  def event({:compacted, result}, state) do
    {_old, recent} = Compactor.split(state.history)
    before = context_tokens(state)
    turns = ((state.summary && state.summary.turns) || 0) + result.turns
    summary = %{text: result.summary, turns: turns, check: result.check}
    compacted = %{state | history: recent, summary: summary, compacting: nil, run: nil}
    after_ = context_tokens(compacted)

    if after_ >= before,
      do: compaction_skipped(state),
      else: compacted(compacted, result, before, after_)
  end

  # Short turns can come out longer as a summary; then compacting isn't worth it.
  defp compaction_skipped(state) do
    meta = "compaction skipped: the summary wasn't smaller than the turns it would replace"

    %{
      state
      | compacting: nil,
        run: nil,
        status: "ready",
        transcript: state.transcript ++ [{:meta, meta}]
    }
  end

  defp compacted(state, result, before, after_) do
    recent = state.history
    summary = state.summary

    marker =
      {:meta,
       "▲ the #{result.turns} turns above are compacted into the summary in the sidebar " <>
         "(#{Context.short(before)} → #{Context.short(after_)} tokens · ctrl+t)"}

    %{
      state
      | summary: Map.merge(summary, %{before: before, after: after_}),
        transcript: insert_marker(state.transcript, marker, recent),
        status: "compacted #{result.turns} turns"
    }
  end
end
