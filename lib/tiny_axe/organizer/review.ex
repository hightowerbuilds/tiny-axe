defmodule TinyAxe.Organizer.Review do
  @moduledoc """
  Reviews a validated file plan against the user's request and source folders.
  Produces per-step scores and retry feedback without mutating the plan's files.
  An unavailable score stays unknown; it never becomes permission to execute.
  """

  alias TinyAxe.{Decider, Ops}
  alias TinyAxe.Organizer.Discovery

  # One Decider call asks, for each step, whether the user asked for it, and
  # whether the plan does everything asked. The plan's score is its weakest
  # link. Two phrasings proved badly calibrated: "does the plan do what was
  # asked, and nothing else?" (33% for a plan whose steps scored 75-96%), and
  # "does it leave out anything?" (35-58% for the same plan as wording varied,
  # where "does it do everything asked?" held at 76-77%).
  @max_step_questions 30

  @doc "Reviews requested steps and completeness, preserving unknown scores."
  @spec assess(map(), [map()]) :: {number() | nil, String.t(), [map()]}
  def assess(context, ops) do
    plan = Enum.map_join(ops, "\n", &("- " <> describe_step(&1)))
    reviewed = Enum.take(ops, @max_step_questions)

    questions =
      reviewed
      |> Enum.with_index()
      |> Map.new(fn {op, i} ->
        {:"step_#{i}",
         %{
           type: :noul,
           instructions:
             "Did the user ask for this step, with this exact action (a copy keeps the " <>
               "original, a move doesn't; trash removes): #{describe_step(op)}?"
         }}
      end)
      |> Map.put(:complete, %{
        type: :noul,
        instructions: "Does the plan do everything the user asked for?"
      })

    # What's in the folders files are taken from (moved, copied or trashed), so
    # the reviewer can tell whether "all the PDFs" really are all of them, and
    # that a .txt isn't one.
    source_folders =
      ops
      |> Enum.flat_map(fn
        %{op: op, from: from} when op in [:move, :copy] -> [Path.dirname(from)]
        %{op: :trash, path: path} -> [Path.dirname(path)]
        _ -> []
      end)
      |> Enum.uniq()
      |> Enum.map_join("\n\n", &Discovery.listing/1)

    state = %{
      request: context.request,
      recent_conversation: Map.get(context, :recent_conversation, ""),
      plan: plan,
      source_folders: source_folders,
      # Without this the reviewer marks "delete X" → "trash X" as missing the delete.
      how_tiny_axe_works:
        "tiny-axe never deletes permanently: moving to the Trash is how it deletes, " <>
          "removes or cleans out files. It never overwrites: replacing a file means " <>
          "trashing the old one and moving the new one into place. Making a folder " <>
          "that a move or write needs is part of that move or write."
    }

    case Decider.decide(state, questions) do
      {:ok, answers} ->
        scores =
          Enum.map(Enum.with_index(reviewed), fn {_, i} -> Decider.p(answers, :"step_#{i}") end)

        complete = Decider.p(answers, :complete)
        # Any unknown makes the whole review unknown: a weakest link can't be missing.
        score = if nil in [complete | scores], do: nil, else: Enum.min([complete | scores])

        doubtful =
          reviewed
          |> Enum.zip(scores)
          |> Enum.filter(fn {_op, p} -> is_number(p) and p < Decider.review_threshold() end)
          |> Enum.map(fn {op, p} ->
            "- probably not what the user asked for (#{pct(p)}): " <> describe_step(op)
          end)

        missing_line =
          if is_number(complete) and complete < Decider.review_threshold(),
            do: [
              "- something the user asked for seems to be missing (complete: #{pct(complete)})"
            ],
            else: []

        feedback =
          "A reviewer checked each step against the request:\n" <>
            Enum.join(doubtful ++ missing_line, "\n") <>
            "\n\nRe-read the request word by word (move is not copy) and reply with a corrected plan."

        # Steps past the reviewed ones get no score of their own.
        ops_scored =
          Enum.zip_with([ops, scores ++ List.duplicate(nil, length(ops))], fn [op, p] ->
            Map.put(op, :review, p)
          end)

        {score, feedback, ops_scored}

      {:error, _} ->
        {nil, "", ops}
    end
  end

  defp pct(p) when is_number(p), do: "#{round(p * 100)}%"
  defp pct(_), do: "?"

  defp describe_step(%{op: :write, about: about} = op), do: Ops.describe(op) <> ": " <> about
  defp describe_step(op), do: Ops.describe(op)
end
