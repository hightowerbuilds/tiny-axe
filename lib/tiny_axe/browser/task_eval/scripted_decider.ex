defmodule TinyAxe.Browser.TaskEval.ScriptedDecider do
  @moduledoc """
  A fixed, rule-based stand-in for Jev, for offline runs of the browser task
  evaluation and its tests (`--decider scripted`). It calls no model. Its
  answers are plain rules over the evidence, so an offline run measures the
  harness and the fixture tasks, never decision quality:

    * `spends` — a button whose own label commits payment
    * `sends`, `saves_on_change` — a field or option whose page says it
      saves or applies at once
    * `buy` (purchase intent) — the request says buy, order or purchase
    * `matches` (purchase items) — yes; the scripted user still checks them
    * `claims_done` (the evaluator) and `claim_1`… (the completion check's
      per-action questions) — no if the reply says something couldn't be
      done, was refused or needs the user; otherwise yes
    * `took_effect` (verifying an outcome) — a page says it was sent, saved,
      added, placed and so on, or shows what the request quotes, and no page
      reports an error; `shows_error` — a page reports one;
      `contradicts_claim` — no

  Anything else is "no".
  """

  @behaviour TinyAxe.Decider

  @commit ~r/\b(place (your )?order|buy( it)? now|pay( now)?|complete (your )?purchase|subscribe)\b/i
  @autosave ~r/\b(save[sd]? automatically|saved automatically|applied immediately|saved immediately|take effect immediately)\b/i
  @hedge ~r/\b(couldn'?t|could not|didn'?t|did not|wasn'?t|not able|unable|refused|stopped|blocked|which one|over your|exceeds?|declined|need you|please confirm|haven'?t|not sure|may not|uncertain)\b|\?\s*$/i

  @done ~r/\b(sent|saved|published|is live|added|removed|placed|thank you|thanks for your order|order number|updated|deleted|your cart|your basket)\b/i
  @failure ~r/\b(error|failed|could not|couldn'?t|may not have|bad gateway|rejected)\b/i

  @claims [:claim_1, :claim_2, :claim_3, :claim_4, :claim_5, :claim_6]

  @impl true
  def max_options, do: 255

  @impl true
  def decide(state, questions) do
    {:ok,
     Map.new(questions, fn
       {key, %{type: :choice, options: options}} ->
         first = options |> Map.keys() |> Enum.sort_by(&to_string/1) |> hd()
         {key, %{choice: first, probabilities: %{first => 1.0}, confidence: 1.0}}

       {key, _question} ->
         {key, %{noul: p(key, state)}}
     end)}
  end

  defp p(:spends, %{target: target}) do
    field? =
      target["type"] in ["radio", "checkbox"] or target["tag"] in ["input", "select", "textarea"]

    if not field? and (target["text"] || "") =~ @commit, do: 0.9, else: 0.0
  end

  defp p(key, %{target: target}) when key in [:sends, :saves_on_change] do
    field? = target["tag"] in ["input", "select", "textarea"]
    if field? and (target["context"] || "") =~ @autosave, do: 0.9, else: 0.0
  end

  defp p(:buy, state),
    do: if(text(state) =~ ~r/\b(buy|order|purchase)\b/i, do: 0.9, else: 0.0)

  defp p(:matches, _state), do: 0.9

  defp p(:claims_done, %{agent_reply: reply}),
    do: if((reply || "") =~ @hedge, do: 0.05, else: 0.95)

  defp p(key, %{agent_reply: %{text: reply}}) when key in @claims,
    do: if((reply || "") =~ @hedge, do: 0.05, else: 0.95)

  defp p(:contradicts_claim, _state), do: 0.0

  defp p(:took_effect, state) do
    text = pages(state)
    shown = text =~ @done or Enum.any?(quoted(state), &String.contains?(text, &1))
    if shown and not (text =~ @failure), do: 0.9, else: 0.1
  end

  defp p(:shows_error, state), do: if(pages(state) =~ @failure, do: 0.9, else: 0.0)

  defp p(_key, _state), do: 0.0

  # The pages a verification was shown: as it is now, and right after the action.
  defp pages(state) do
    [state[:after_action], state[:now]]
    |> Enum.filter(&is_map/1)
    |> Enum.map_join("\n", &"#{&1[:title]}\n#{&1[:text]}\n#{&1[:dialog]}")
  end

  # What the user's request quotes ("Count me in"), to look for on the page.
  defp quoted(state) do
    objective = get_in(state, [:task, :objective]) || ""
    for [_, q] <- Regex.scan(~r/"([^"]{3,})"/, objective), do: q
  end

  defp text(state) when is_map(state), do: state |> Map.values() |> Enum.join(" ")
  defp text(state), do: to_string(state)
end
