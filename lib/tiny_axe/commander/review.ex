defmodule TinyAxe.Commander.Review do
  @moduledoc false

  alias TinyAxe.{Decider, Location, Ops}
  alias TinyAxe.Commander.Prompt

  def assess(dir, commands, context, notify) do
    listing =
      commands |> Enum.with_index(1) |> Enum.map_join("\n", fn {c, i} -> "#{i}. $ #{c}" end)

    questions =
      commands
      |> Enum.with_index()
      |> Map.new(fn {c, i} ->
        {:"cmd_#{i}",
         %{type: :noul, instructions: "Is this command needed for what the user asked: $ #{c}"}}
      end)
      |> Map.put(:complete, %{
        type: :noul,
        instructions: "Would running these commands, in this order, do everything the user asked?"
      })
      |> Map.put(:right_folder, %{
        type: :noul,
        instructions:
          "Is the working folder the right place to run these, given the request and " <>
            "the current folder?"
      })

    state = %{
      request: context.request,
      recent_conversation: Map.get(context, :recent_conversation, ""),
      working_folder: Ops.show(dir),
      current_folder: Ops.show(Location.current()),
      commands: listing,
      folder_contents: Prompt.folder_listing(dir),
      how_commands_run:
        "Each command runs with sh -c in the working folder; `cd x && ...` works within " <>
          "one command. Nothing answers prompts, so commands use flags that skip questions."
    }

    case Decider.decide(state, questions) do
      {:ok, answers} ->
        scores =
          Enum.map(Enum.with_index(commands), fn {_, i} -> Decider.p(answers, :"cmd_#{i}") end)

        complete = Decider.p(answers, :complete)
        right_folder = Decider.p(answers, :right_folder)
        all = [complete, right_folder | scores]
        # Any unknown makes the whole review unknown: a weakest link can't be missing.
        score = if nil in all, do: nil, else: Enum.min(all)
        notify.({:review, score})
        if score == nil, do: notify.({:decider_unavailable, "reviewing the commands"})

        plan = %{
          request: context.request,
          dir: dir,
          commands: Enum.zip_with(commands, scores, &%{command: &1, review: &2}),
          review: score
        }

        if is_number(score) and score < Decider.review_threshold() do
          doubtful =
            for {c, p} <- Enum.zip(commands, scores),
                p < Decider.review_threshold(),
                do: "- probably not needed (#{pct(p)}): $ #{c}"

          missing =
            if complete < Decider.review_threshold(),
              do: ["- together they may not do everything asked (#{pct(complete)})"],
              else: []

          missing =
            if right_folder < Decider.review_threshold(),
              do:
                missing ++ ["- #{Ops.show(dir)} may be the wrong folder (#{pct(right_folder)})"],
              else: missing

          feedback =
            "A reviewer checked the commands against the request:\n" <>
              Enum.join(doubtful ++ missing, "\n") <> "\n\nReply with corrected JSON."

          {plan, feedback}
        else
          {plan, nil}
        end

      {:error, _} ->
        notify.({:decider_unavailable, "reviewing the commands"})

        {%{
           request: context.request,
           dir: dir,
           commands: Enum.map(commands, &%{command: &1, review: nil}),
           review: nil
         }, nil}
    end
  end

  defp pct(p) when is_number(p), do: "#{round(p * 100)}%"
  defp pct(_), do: "?"
end
